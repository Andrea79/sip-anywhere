// Bridge between the app and the OpenVPN 3 client core (see ovpnbridge.h).
//
// OpenVPN 3 is built as a single translation unit from client/ovpncli.cpp, with
// the "tun builder" abstraction its iOS/Android clients use: the app provides
// the tunnel device, here one end of a local datagram socket pair.

#include <openvpn/common/platform.hpp>
#include "client/ovpncli.cpp"

#include "ovpnbridge.h"

#include <atomic>
#include <cstring>
#include <cstdlib>
#include <mutex>
#include <thread>
#include <fcntl.h>
#include <psa/crypto.h>
#include <sys/socket.h>
#include <unistd.h>

namespace {

using namespace openvpn;

void copy_str(char *dst, size_t len, const std::string &src)
{
    if (len == 0)
        return;
    std::strncpy(dst, src.c_str(), len - 1);
    dst[len - 1] = '\0';
}

// A profile without a client certificate authenticates with username/password
// only (some VPN servers are set up this way): tell OpenVPN not to expect a certificate.
bool profile_has_client_cert(const std::string &profile)
{
    if (profile.find("<cert>") != std::string::npos || profile.find("<pkcs12>") != std::string::npos)
        return true;
    std::istringstream lines(profile);
    std::string line;
    while (std::getline(lines, line))
    {
        size_t start = line.find_first_not_of(" \t");
        if (start == std::string::npos)
            continue;
        if (line.compare(start, 5, "cert ") == 0 || line.compare(start, 7, "pkcs12 ") == 0)
            return true;
    }
    return false;
}

// "tls-cipher" lists TLS 1.2 suites only; OpenVPN 2 and OpenSSL-based clients add the
// TLS 1.3 suites by themselves (tls-ciphersuites), but OpenVPN 3 with mbed TLS passes
// exactly this list to mbed TLS, which then offers TLS 1.3 without any TLS 1.3 suite
// and a TLS 1.3 server rejects the handshake ("no shared cipher"). Add them; if the
// line would exceed OpenVPN 3's 256-character limit, drop the client-side preference
// and use mbed TLS's (modern) default list instead: the server enforces its own list.
std::string normalize_profile(const std::string &profile)
{
    static const std::string tls13 = ":TLS1-3-AES-256-GCM-SHA384:TLS1-3-CHACHA20-POLY1305-SHA256:TLS1-3-AES-128-GCM-SHA256";
    std::istringstream lines(profile);
    std::string line, out;
    while (std::getline(lines, line))
    {
        size_t start = line.find_first_not_of(" \t");
        if (start != std::string::npos && line.compare(start, 11, "tls-cipher ") == 0
            && line.find("TLS1-3") == std::string::npos)
        {
            size_t end = line.find_last_not_of(" \t\r");
            std::string list = line.substr(start + 11, end + 1 - (start + 11));
            list.erase(0, list.find_first_not_of(" \t"));
            if (list.size() + tls13.size() <= 256)
                line = "tls-cipher " + list + tls13;
            else
                line = "# tls-cipher (too long with TLS 1.3 suites; using the defaults) " + list;
        }
        out += line + "\n";
    }
    return out;
}

class Client : public ClientAPI::OpenVPNClient
{
  public:
    ovpn_callbacks cb{};
    void *ctx = nullptr;

    // --- tun builder: collect what the server pushes, then hand out a socket pair.
    bool tun_builder_new() override
    {
        tun_ip.clear();
        mtu = 1500;
        return true;
    }
    bool tun_builder_add_address(const std::string &address, int, const std::string &, bool ipv6, bool) override
    {
        if (!ipv6)
            tun_ip = address;
        return true;
    }
    // Routes, DNS and gateway settings only concern a system-wide tunnel: the
    // app decides itself what goes through the VPN (its own SIP and audio).
    bool tun_builder_set_layer(int) override { return true; }
    bool tun_builder_set_remote_address(const std::string &, bool) override { return true; }
    bool tun_builder_set_route_metric_default(int) override { return true; }
    bool tun_builder_reroute_gw(bool, bool, unsigned int) override { return true; }
    bool tun_builder_add_route(const std::string &, int, int, bool) override { return true; }
    bool tun_builder_exclude_route(const std::string &, int, int, bool) override { return true; }
    bool tun_builder_set_dns_options(const DnsOptions &) override { return true; }
    bool tun_builder_set_mtu(int value) override
    {
        mtu = value;
        return true;
    }
    bool tun_builder_set_session_name(const std::string &) override { return true; }
    bool tun_builder_add_proxy_bypass(const std::string &) override { return true; }
    bool tun_builder_set_proxy_auto_config_url(const std::string &) override { return true; }
    bool tun_builder_set_proxy_http(const std::string &, int) override { return true; }
    bool tun_builder_set_proxy_https(const std::string &, int) override { return true; }
    bool tun_builder_add_wins_server(const std::string &) override { return true; }
    bool tun_builder_set_allow_family(int, bool) override { return true; }
    bool tun_builder_set_allow_local_dns(bool) override { return true; }

    int tun_builder_establish() override
    {
        int sv[2];
        if (tun_ip.empty() || socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) != 0)
            return -1;
        int size = 1 << 20;
        for (int fd : sv)
        {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
            int on = 1;   // writing after the other end closed must not kill the app
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
            fcntl(fd, F_SETFD, FD_CLOEXEC);
        }
        // sv[0] is OpenVPN's tunnel device; sv[1] belongs to the app.
        if (cb.on_tunnel_up)
            cb.on_tunnel_up(ctx, sv[1], tun_ip.c_str(), mtu);
        return sv[0];
    }
    void tun_builder_teardown(bool) override
    {
        if (cb.on_tunnel_down)
            cb.on_tunnel_down(ctx);
    }

    // --- events and logging
    bool pause_on_connection_timeout() override { return false; }
    void event(const ClientAPI::Event &e) override
    {
        if (cb.on_event)
            cb.on_event(ctx, e.name.c_str(), e.info.c_str(), e.error, e.fatal);
    }
    void acc_event(const ClientAPI::AppCustomControlMessageEvent &) override {}
    void log(const ClientAPI::LogInfo &l) override
    {
        if (cb.on_log)
            cb.on_log(ctx, l.text.c_str());
    }
    void external_pki_cert_request(ClientAPI::ExternalPKICertRequest &req) override
    {
        req.error = true;
        req.errorText = "External PKI is not supported";
    }
    void external_pki_sign_request(ClientAPI::ExternalPKISignRequest &req) override
    {
        req.error = true;
        req.errorText = "External PKI is not supported";
    }
    bool socket_protect(openvpn_io::detail::socket_type, std::string, bool) override { return true; }

  private:
    std::string tun_ip;
    int mtu = 1500;
};

std::mutex g_lock;
Client *g_client = nullptr;   // the running session, if any

// mbed TLS 3 needs its PSA crypto layer initialised for TLS 1.3 handshakes.
void init_crypto()
{
    static std::once_flag once;
    std::call_once(once, [] { psa_crypto_init(); });
}

ClientAPI::Config make_config(const std::string &profile)
{
    init_crypto();
    ClientAPI::Config config;
    config.content = normalize_profile(profile);
    config.guiVersion = "SIP Anywhere";
    config.compressionMode = "asym";    // accept compressed packets from servers using comp-lzo/lz4
    config.disableClientCert = !profile_has_client_cert(profile);
    config.connTimeout = 30;
    config.tunPersist = false;
    // Diagnostics for development: TLS library debug output in the log.
    if (const char *level = getenv("SIPANYWHERE_SSL_DEBUG"))
        config.sslDebugLevel = atoi(level);
    return config;
}

} // namespace

extern "C" void ovpn_profile_check(const char *profile, ovpn_profile_info *info)
{
    std::memset(info, 0, sizeof(*info));
    try
    {
        Client probe;
        ClientAPI::EvalConfig eval = probe.eval_config(make_config(profile ? profile : ""));
        if (eval.error)
        {
            copy_str(info->error, sizeof(info->error), eval.message);
            return;
        }
        info->valid = 1;
        info->needs_credentials = eval.autologin ? 0 : 1;
        std::string server = eval.remoteHost;
        if (server.empty() && !eval.serverList.empty())
            server = eval.serverList[0].server;
        if (!server.empty() && !eval.remotePort.empty())
            server += (server.find(':') != std::string::npos ? " port " : ":") + eval.remotePort;
        copy_str(info->server, sizeof(info->server), server);
    }
    catch (const std::exception &e)
    {
        copy_str(info->error, sizeof(info->error), e.what());
    }
}

extern "C" int ovpn_start(const char *profile, const char *username, const char *password,
                          const ovpn_callbacks *cb, void *ctx, char *err, int err_len)
{
    std::lock_guard<std::mutex> lock(g_lock);
    if (g_client)
    {
        copy_str(err, err_len, "A VPN session is already running");
        return -1;
    }
    auto *client = new Client();
    client->cb = *cb;
    client->ctx = ctx;
    try
    {
        ClientAPI::EvalConfig eval = client->eval_config(make_config(profile ? profile : ""));
        if (eval.error)
        {
            copy_str(err, err_len, eval.message);
            delete client;
            return -1;
        }
        if (!eval.autologin)
        {
            ClientAPI::ProvideCreds creds;
            creds.username = username ? username : "";
            creds.password = password ? password : "";
            ClientAPI::Status status = client->provide_creds(creds);
            if (status.error)
            {
                copy_str(err, err_len, status.message);
                delete client;
                return -1;
            }
        }
    }
    catch (const std::exception &e)
    {
        copy_str(err, err_len, e.what());
        delete client;
        return -1;
    }

    g_client = client;
    // Detached: the thread deletes the client and reports on_finished when connect() returns.
    std::thread([client]() {
        ClientAPI::Status status;
        try
        {
            status = client->connect();   // runs until stopped or a fatal error
        }
        catch (const std::exception &e)
        {
            status.error = true;
            status.message = e.what();
        }
        ovpn_callbacks done = client->cb;
        void *done_ctx = client->ctx;
        {
            std::lock_guard<std::mutex> lock(g_lock);
            g_client = nullptr;
        }
        delete client;
        if (done.on_finished)
            done.on_finished(done_ctx, status.error ? 1 : 0, status.message.c_str());
    }).detach();
    return 0;
}

extern "C" void ovpn_stop(void)
{
    std::lock_guard<std::mutex> lock(g_lock);
    if (g_client)
        g_client->stop();
}

extern "C" void ovpn_reconnect(void)
{
    std::lock_guard<std::mutex> lock(g_lock);
    if (g_client)
        g_client->reconnect(0);
}

extern "C" int ovpn_running(void)
{
    std::lock_guard<std::mutex> lock(g_lock);
    return g_client ? 1 : 0;
}

extern "C" int ovpn_get_stats(ovpn_transport_stats *out)
{
    std::lock_guard<std::mutex> lock(g_lock);
    std::memset(out, 0, sizeof(*out));
    out->ms_since_rx = -1;
    if (!g_client)
        return -1;
    ClientAPI::TransportStats ts = g_client->transport_stats();
    out->bytes_in = ts.bytesIn;
    out->bytes_out = ts.bytesOut;
    out->packets_in = ts.packetsIn;
    out->packets_out = ts.packetsOut;
    if (ts.lastPacketReceived >= 0)
        out->ms_since_rx = (int)((long long)ts.lastPacketReceived * 1000 / 1024);   // binary ms
    return 0;
}
