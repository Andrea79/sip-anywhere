#ifndef OVPNBRIDGE_H
#define OVPNBRIDGE_H

/* Minimal C interface to the OpenVPN 3 client core, for the in-app VPN.
 *
 * The tunnel is private to the app: instead of creating a system network
 * interface, OpenVPN hands the tunnel's IP packets to the app through a local
 * datagram socket (one packet per datagram, each preceded by a 4-byte
 * address-family header as on macOS utun interfaces). Nothing else on the Mac
 * uses the VPN. */

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int valid;              /* 1 if the profile can be used */
    int needs_credentials;  /* 1 if a username and password are required */
    char server[256];       /* first "remote" of the profile, for display */
    char error[256];        /* why the profile is not valid */
} ovpn_profile_info;

typedef struct {
    /* OpenVPN events: CONNECTING, WAIT, AUTH_FAILED, CONNECTED, RECONNECTING,
     * DISCONNECTED, ...; error/fatal as reported by OpenVPN. */
    void (*on_event)(void *ctx, const char *name, const char *info, int error, int fatal);
    void (*on_log)(void *ctx, const char *text);
    /* The tunnel is up: fd carries its IP packets (utun framing); ip is the
     * address the server assigned to us; mtu the tunnel MTU. */
    void (*on_tunnel_up)(void *ctx, int fd, const char *ip, int mtu);
    /* The tunnel is gone (fd closed): disconnect or reconnection. */
    void (*on_tunnel_down)(void *ctx);
    /* ovpn_start's session ended (after ovpn_stop, a fatal error, or AUTH_FAILED). */
    void (*on_finished)(void *ctx, int error, const char *message);
} ovpn_callbacks;

/* Checks a .ovpn profile without connecting. */
void ovpn_profile_check(const char *profile, ovpn_profile_info *info);

/* Starts the VPN in a background thread. Returns 0 if the session started;
 * progress is reported through the callbacks. Only one session at a time. */
int ovpn_start(const char *profile, const char *username, const char *password,
               const ovpn_callbacks *cb, void *ctx, char *err, int err_len);

/* Stops the session (asynchronous: on_finished follows). */
void ovpn_stop(void);

/* Reconnects the running session now (e.g. after the Mac changed network), instead
 * of waiting for the keep-alive timeout. Events and tunnel callbacks follow. */
void ovpn_reconnect(void);

/* 1 while a session is running (until just before on_finished). */
int ovpn_running(void);

typedef struct {
    long long bytes_in, bytes_out;      /* encrypted traffic to/from the VPN server */
    long long packets_in, packets_out;
    int ms_since_rx;                    /* since the last packet from the server; -1 if unknown */
} ovpn_transport_stats;

/* Traffic of the current session, for diagnostics. Returns 0 while a session runs. */
int ovpn_get_stats(ovpn_transport_stats *out);

#ifdef __cplusplus
}
#endif

#endif
