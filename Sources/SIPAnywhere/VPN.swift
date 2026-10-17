import COpenVPN
import CSIPCore
import Foundation
import Network

/// In-app VPN settings. The VPN is private to the app: only its SIP signalling and
/// audio go through it, the rest of the Mac keeps using the normal connection.
/// Any OpenVPN server works (e.g. OpenVPN Access Server, pfSense, NAS VPN apps, many routers):
/// the user imports the .ovpn profile the server provides.
///
/// The profile (it can contain keys) and the password are kept in the Keychain;
/// the rest in UserDefaults.
struct VPNSettings: Codable, Equatable {
    /// Send calls through the VPN.
    var enabled = false
    /// File name of the imported profile, for display.
    var profileName = ""
    var username = ""

    var trimmedUsername: String { username.trimmingCharacters(in: .whitespaces) }

    private static let defaultsKey = "vpn"
    static let profileKey = "vpn-profile"
    static let passwordKey = "vpn-password"

    static func load() -> VPNSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(VPNSettings.self, from: data) else {
            return VPNSettings()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// What OpenVPN says about a profile, without connecting.
struct VPNProfileInfo: Equatable {
    var valid = false
    var needsCredentials = false
    var server = ""
    var error = ""

    init() {}

    init(profile: String) {
        guard !profile.isEmpty else { return }
        var info = ovpn_profile_info()
        ovpn_profile_check(profile, &info)
        valid = info.valid != 0
        needsCredentials = info.needs_credentials != 0
        server = withUnsafeBytes(of: info.server) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        error = withUnsafeBytes(of: info.error) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

enum VPNState: Equatable {
    case off
    case connecting(String)
    case connected(ip: String)
    case failed(String)
}

/// A VPN tunnel handed over by OpenVPN: the app's end of the packet socket,
/// the address the server assigned to us, and the MTU.
struct VPNTunnel {
    var fd: Int32
    var ip: String
    var mtu: Int32
}

enum VPNSession {
    case none, running, stopping
}

/// State of the VPN traffic diagnostics (see vpnStatsTick).
struct VPNStatsWindow {
    var server = ovpn_transport_stats()     // at the start of the current summary period
    var app = sip_vpn_stats()
    var started = false
    var seconds = 0
    var slowestHandOff: Int32 = 0
    var slowestSend: Int32 = 0
    var lastSecondRx: UInt64 = 0
    var stalledSince: Date?
}

extension SIPEngine {
    // MARK: - VPN settings

    var vpnProfile: String {
        get {
            #if DEBUG
            if let debugVPNProfile { return debugVPNProfile }
            #endif
            return Keychain.password(for: VPNSettings.profileKey)
        }
        set { Keychain.setPassword(newValue, for: VPNSettings.profileKey) }
    }

    var vpnPassword: String {
        get {
            #if DEBUG
            if let debugVPNPassword { return debugVPNPassword }
            #endif
            return Keychain.password(for: VPNSettings.passwordKey)
        }
        set { Keychain.setPassword(newValue, for: VPNSettings.passwordKey) }
    }

    /// Why the VPN cannot be used with the current settings, or nil.
    static func vpnProblem(_ vpn: VPNSettings, profile: String, info: VPNProfileInfo, password: String,
                           transport: AccountSettings.Transport) -> String? {
        guard vpn.enabled else { return nil }
        if profile.isEmpty { return "Import the OpenVPN profile (.ovpn file) of your VPN server." }
        if !info.valid { return "The profile cannot be used: \(info.error)" }
        if transport != .udp { return "Through the VPN, SIP works over UDP only: choose UDP as transport." }
        if info.needsCredentials && (vpn.trimmedUsername.isEmpty || password.isEmpty) {
            return "Enter the VPN username and password."
        }
        return nil
    }

    var vpnUsable: Bool {
        let profile = vpnProfile
        return Self.vpnProblem(vpnSettings, profile: profile, info: VPNProfileInfo(profile: profile),
                               password: vpnPassword, transport: settings.transport) == nil
    }

    // MARK: - VPN session

    /// Starts the VPN; the SIP stack starts once the tunnel is up (see handleTunnelUp).
    func startVPN() {
        switch vpnSession {
        case .running:
            return
        case .stopping:
            restartVPNAfterStop = true
            return
        case .none:
            break
        }
        let profile = vpnProfile
        let info = VPNProfileInfo(profile: profile)
        vpnServerHost = Self.hostName(of: info.server)
        if let problem = Self.vpnProblem(vpnSettings, profile: profile, info: info,
                                         password: vpnPassword, transport: settings.transport) {
            vpnFailed(problem, retry: false)
            showSettings = true
            return
        }
        vpnAuthFailed = false
        vpnLastError = nil
        var cb = ovpn_callbacks()
        cb.on_event = { ctx, name, info, error, fatal in
            let n = name.map { String(cString: $0) } ?? ""
            let i = info.map { String(cString: $0) } ?? ""
            let engine = Unmanaged<SIPEngine>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { engine.handleVPNEvent(n, info: i, error: error != 0, fatal: fatal != 0) }
        }
        cb.on_log = { ctx, text in
            let t = text.map { String(cString: $0) } ?? ""
            let engine = Unmanaged<SIPEngine>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { engine.appendLog("VPN: " + t) }
        }
        cb.on_tunnel_up = { ctx, fd, ip, mtu in
            let a = ip.map { String(cString: $0) } ?? ""
            let engine = Unmanaged<SIPEngine>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { engine.handleTunnelUp(VPNTunnel(fd: fd, ip: a, mtu: mtu)) }
        }
        cb.on_tunnel_down = { ctx in
            let engine = Unmanaged<SIPEngine>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { engine.handleTunnelDown() }
        }
        cb.on_finished = { ctx, error, message in
            let m = message.map { String(cString: $0) } ?? ""
            let engine = Unmanaged<SIPEngine>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { engine.handleVPNFinished(error: error != 0, message: m) }
        }
        var err = [CChar](repeating: 0, count: 512)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let user = info.needsCredentials ? vpnSettings.trimmedUsername : ""
        let pass = info.needsCredentials ? vpnPassword : ""
        appendLog("VPN: connecting to \(info.server.isEmpty ? vpnSettings.profileName : info.server)")
        startNetworkMonitor()
        if ovpn_start(profile, user, pass, &cb, ctx, &err, Int32(err.count)) == 0 {
            vpnSession = .running
            vpnState = .connecting("Connecting")
        } else {
            vpnFailed(String(cString: err), retry: true)
        }
    }

    /// Stops the VPN (asynchronous: handleVPNFinished follows).
    func stopVPN() {
        pendingSIPConnect = nil
        tunnelLostAt = nil
        tunnelLostTimer?.invalidate()
        tunnelLostTimer = nil
        restartVPNAfterStop = false
        closeTunnel()
        if vpnSession == .running {
            vpnSession = .stopping
            ovpn_stop()
        }
        vpnState = .off
    }

    /// At quit: stops the VPN and gives it a moment to say goodbye to the server.
    func stopVPNAndWait() {
        stopVPN()
        let deadline = Date().addingTimeInterval(2)
        while ovpn_running() != 0 && Date() < deadline { usleep(20_000) }
    }

    private func closeTunnel() {
        stopVPNStats()
        if let t = tunnel {
            close(t.fd)
            tunnel = nil
        }
    }

    // MARK: - VPN diagnostics

    /// While the tunnel is up: a traffic summary in the log (how often depends on the
    /// "Log detail" setting), and a warning as soon as nothing arrives during a call, saying
    /// whether the VPN server is still sending (hold-up in the app) or not (network or server).
    private func startVPNStats() {
        stopVPNStats()
        vpnStatsWindow = VPNStatsWindow()
        vpnStatsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.vpnStatsTick() }
        }
    }

    private func stopVPNStats() {
        vpnStatsTimer?.invalidate()
        vpnStatsTimer = nil
    }

    private static func delta(_ now: UInt64, _ before: UInt64) -> UInt64 { now >= before ? now - before : now }
    private static func delta(_ now: Int64, _ before: Int64) -> Int64 { now >= before ? now - before : now }

    private static func size(_ bytes: Int64) -> String {
        bytes < 10_000 ? "\(bytes) B" : String(format: "%.1f kB", Double(bytes) / 1000)
    }

    private static func ago(_ ms: Int32) -> String {
        ms < 0 ? "never" : String(format: "%.1f s ago", Double(ms) / 1000)
    }

    private func vpnStatsTick() {
        var server = ovpn_transport_stats()
        guard ovpn_get_stats(&server) == 0 else { return }
        var app = sip_vpn_stats()
        sip_vpn_stats_get(&app)
        var w = vpnStatsWindow
        if !w.started || app.rx_packets < w.app.rx_packets {     // first tick, or SIP restarted
            w = VPNStatsWindow()
            w.started = true
            w.server = server
            w.app = app
            w.lastSecondRx = app.rx_packets
        }
        w.seconds += 1
        w.slowestHandOff = max(w.slowestHandOff, app.max_delivery_ms)
        w.slowestSend = max(w.slowestSend, app.max_send_ms)
        if app.max_delivery_ms >= 200 || app.max_send_ms >= 200 {
            appendLog("VPN warning: slow inside the app: handing a received packet over took "
                      + "\(app.max_delivery_ms) ms, writing into the tunnel \(app.max_send_ms) ms")
        }

        // During a call audio arrives 50 times a second: a gap means a hold-up.
        let inCall = app.active != 0 && calls.contains { $0.phase == .active && !$0.onHold && !$0.remoteHold }
        if inCall && (app.ms_since_rx < 0 || app.ms_since_rx >= 2000) {
            if w.stalledSince == nil {
                w.stalledSince = Date()
                let serverSending = server.ms_since_rx >= 0 && server.ms_since_rx < 1500
                appendLog("VPN warning: "
                          + (app.ms_since_rx < 0 ? "nothing received yet" : "nothing received for \(app.ms_since_rx / 1000) s")
                          + " during the call; "
                          + "last packet from the VPN server \(Self.ago(server.ms_since_rx)) "
                          + (serverSending ? "(the server is still sending: the hold-up is in the app)"
                                           : "(nothing from the server either: the hold-up is in the network or the VPN server)"))
            }
        } else if let since = w.stalledSince, app.ms_since_rx >= 0, app.ms_since_rx < 2000 {
            appendLog(String(format: "VPN: traffic resumed after %.0f s; %llu packets arrived in the last second",
                             Date().timeIntervalSince(since) + 2, Self.delta(app.rx_packets, w.lastSecondRx)))
            w.stalledSince = nil
        }
        w.lastSecondRx = app.rx_packets

        // Log detail (Settings › Advanced) sets how often a summary is written; warnings
        // about stalls are always written at once.
        let every = settings.vpnLogIntervals
        if every.inCall > 0 && w.seconds >= (inCall ? every.inCall : every.idle) {
            let s0 = w.server, a0 = w.app
            appendLog("VPN \(w.seconds) s: server in \(Self.delta(server.packets_in, s0.packets_in)) pkt "
                      + "\(Self.size(Self.delta(server.bytes_in, s0.bytes_in))), out \(Self.delta(server.packets_out, s0.packets_out)) pkt "
                      + "\(Self.size(Self.delta(server.bytes_out, s0.bytes_out))), last from server \(Self.ago(server.ms_since_rx)) | "
                      + "app in \(Self.delta(app.rx_packets, a0.rx_packets)) (SIP \(Self.delta(app.rx_sip, a0.rx_sip)), "
                      + "audio \(Self.delta(app.rx_media, a0.rx_media)), dropped \(Self.delta(app.rx_dropped, a0.rx_dropped))), "
                      + "out \(Self.delta(app.tx_packets, a0.tx_packets)), send errors \(Self.delta(app.tx_errors, a0.tx_errors)), "
                      + "last in \(Self.ago(app.ms_since_rx)), slowest hand-off \(w.slowestHandOff) ms, slowest send \(w.slowestSend) ms")
            w.server = server
            w.app = app
            w.seconds = 0
            w.slowestHandOff = 0
            w.slowestSend = 0
        }
        vpnStatsWindow = w
    }

    private func vpnFailed(_ message: String, retry: Bool) {
        vpnState = .failed(message)
        pendingSIPConnect = nil
        disconnect(quick: true)
        registration = .failed(code: 0, reason: "VPN: \(message)")
        lastError = "VPN: \(message)"
        guard retry else { return }
        // Same growing pauses as when no proxy answers.
        let delay = Self.retryDelay(level: backoffLevel)
        backoffLevel += 1
        registration = .failed(code: 0, reason: "VPN not connected, next attempt in \(Self.format(delay))")
        lastError = "VPN: \(message). Trying again at "
            + "\(Date().addingTimeInterval(delay).formatted(date: .omitted, time: .shortened)); press ↻ to try now."
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { self.connect(proxyIndex: 0, isFailover: true) }
        }
    }

    // MARK: - VPN callbacks

    private func handleVPNEvent(_ name: String, info: String, error: Bool, fatal: Bool) {
        guard vpnSession == .running else { return }
        appendLog("VPN event: \(name)\(info.isEmpty ? "" : " (\(info))")")
        if error, let text = Self.vpnErrorText(name, info: info) { vpnLastError = text }
        switch name {
        case "AUTH_FAILED":
            vpnAuthFailed = true
        case "RESOLVE":
            vpnState = .connecting("Looking up server")
        case "WAIT", "CONNECTING":
            vpnState = .connecting("Connecting")
        case "GET_CONFIG", "ASSIGN_IP", "ADD_ROUTES":
            vpnState = .connecting("Setting up")
        case "RECONNECTING":
            vpnState = .connecting("Reconnecting")
        case "PAUSE":
            vpnState = .connecting("Paused")
        default:
            break
        }
    }

    /// OpenVPN error events in words.
    private static func vpnErrorText(_ name: String, info: String) -> String? {
        switch name {
        case "AUTH_FAILED": return nil      // handled separately
        case "CONNECTION_TIMEOUT": return "the VPN server did not answer. Check the server address and port, "
            + "and that it can be reached from the Internet"
        case "TRANSPORT_ERROR": return "network error while talking to the VPN server" + (info.isEmpty ? "" : " (\(info))")
        case "CERT_VERIFY_FAIL": return "the VPN server's certificate does not match the profile" + (info.isEmpty ? "" : " (\(info))")
        case "TLS_VERSION_MIN": return "the VPN server requires a TLS version this app does not support"
        case "TUN_SETUP_FAILED", "TUN_IFACE_CREATE": return "the VPN tunnel could not be set up" + (info.isEmpty ? "" : " (\(info))")
        case "INACTIVE_TIMEOUT": return "the VPN was closed for inactivity"
        case "PROXY_ERROR", "PROXY_NEED_CREDS": return "the HTTP proxy in the profile refused the connection"
        default: return info.isEmpty ? name : "\(name): \(info)"
        }
    }

    private func handleTunnelUp(_ t: VPNTunnel) {
        guard vpnSession == .running else {
            close(t.fd)
            return
        }
        closeTunnel()
        tunnel = t
        startVPNStats()
        vpnState = .connected(ip: t.ip)
        // The VPN now goes out on the current route: later changes are compared with it.
        if let path = networkMonitor?.currentPath, path.status == .satisfied {
            vpnRoute = Self.route(of: path)
            vpnRouteBroken = false
        }
        appendLog("VPN: tunnel up, address \(t.ip), MTU \(t.mtu)")
        if let lost = tunnelLostAt {
            // Back after a reconnection with SIP kept alive: move SIP and the calls over.
            tunnelLostAt = nil
            tunnelLostTimer?.invalidate()
            tunnelLostTimer = nil
            let proxy = activeProxyIndex
            if sip_is_running() != 0 && sip_vpn_switch_tunnel(dup(t.fd), t.ip, t.mtu) == 0 {
                appendLog(String(format: "VPN: back after %.0f s; SIP%@ moved to the new tunnel, registering again",
                                 Date().timeIntervalSince(lost), calls.isEmpty ? "" : " and the calls"))
            } else {
                appendLog("VPN: back, but SIP could not be moved to the new tunnel; restarting it")
                disconnect(quick: true)
                connect(proxyIndex: proxy, isFailover: true)
            }
            return
        }
        if let p = pendingSIPConnect {
            pendingSIPConnect = nil
            connect(proxyIndex: p.proxyIndex, isFailover: p.isFailover)
        }
    }

    /// OpenVPN lost the tunnel and is reconnecting (e.g. the Mac changed network). SIP and
    /// the calls are kept and moved to the new tunnel when it is up (handleTunnelUp); if it
    /// does not come back within 45 s, SIP is stopped and started again later.
    private func handleTunnelDown() {
        guard tunnel != nil else { return }
        closeTunnel()
        guard vpnSession == .running else { return }
        vpnState = .connecting("Reconnecting")
        if sip_is_running() != 0 && sip_vpn_tunnel_lost() == 0 {
            appendLog("VPN: tunnel down; keeping SIP\(calls.isEmpty ? "" : " and the calls") while the VPN reconnects")
            tunnelLostAt = Date()
            tunnelLostTimer?.invalidate()
            tunnelLostTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { _ in
                MainActor.assumeIsolated { self.giveUpWaitingForTunnel() }
            }
            return
        }
        appendLog("VPN: tunnel down")
        let proxy = activeProxyIndex
        let wasOnline = isOnline || pendingSIPConnect != nil
        if sip_is_running() != 0 { disconnect(quick: true) }
        vpnState = .connecting("Reconnecting")
        if wasOnline {
            pendingSIPConnect = (proxy, true)
            registration = .registering
        }
    }

    /// The tunnel did not come back in time: stop SIP; it starts again when the VPN is up.
    private func giveUpWaitingForTunnel() {
        guard tunnelLostAt != nil else { return }
        appendLog("VPN: not back after 45 s; SIP will register again when it is")
        let proxy = activeProxyIndex
        disconnect(quick: true)
        if vpnSession == .running {
            pendingSIPConnect = (proxy, true)
            registration = .registering
        }
    }

    // MARK: - Network changes

    /// Watches the Mac's network interfaces. When they change (Wi-Fi to cable, to a
    /// phone's hotspot...), the VPN's connection to the server usually breaks; OpenVPN
    /// would notice only after its keep-alive timeout (about a minute), so it is told to
    /// reconnect at once.
    func startNetworkMonitor() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = Self.networkSignature(of: path)
            let route = Self.route(of: path)
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.networkChanged(to: signature, route: route, satisfied: satisfied) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "network-monitor"))
        networkMonitor = monitor
    }

    /// The usable interfaces in order of preference, without VPN tunnels (other VPN
    /// apps, our own tunnel is not an interface) and loopback.
    nonisolated private static func networkSignature(of path: NWPath) -> String {
        var names: [String] = []
        // macOS sometimes lists an interface twice for a moment ("en0,en0"): not a change.
        for i in path.availableInterfaces where i.type != .other && i.type != .loopback && !names.contains(i.name) {
            names.append(i.name)
        }
        return (path.status == .satisfied ? "" : "offline:") + names.joined(separator: ",")
    }

    /// The interface the traffic goes out on (the first usable one) and its IPv4
    /// address. Other interfaces coming and going (e.g. Wi-Fi while on cable) do not
    /// touch the VPN's connection.
    nonisolated private static func route(of path: NWPath) -> String {
        guard path.status == .satisfied,
              let primary = path.availableInterfaces.first(where: { $0.type != .other && $0.type != .loopback })
        else { return "" }
        return primary.name + " " + ipv4Addresses(of: primary.name).joined(separator: ",")
    }

    nonisolated private static func ipv4Addresses(of interface: String) -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: p.pointee.ifa_name) == interface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result.sorted()
    }

    private func networkChanged(to signature: String, route: String, satisfied: Bool) {
        let previous = networkSignature
        networkSignature = signature
        if previous.isEmpty {
            vpnRoute = route            // first report: the route the VPN connected on
            return
        }
        if signature != previous { appendLog("Network changed: \(previous) → \(signature)") }
        // Offline for a moment, or another interface in front, even briefly: the VPN's
        // connection may be gone, so it reconnects once the network has settled.
        if !satisfied || route != vpnRoute { vpnRouteBroken = true }
        // Wait for the network to settle: a flap (Wi-Fi gone and back within a second)
        // then gives one decision instead of two reconnections in a row, which could leave
        // a registration answered on an already replaced tunnel.
        networkSettleTimer?.invalidate()
        networkSettleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            MainActor.assumeIsolated { self.networkSettled(route: route, satisfied: satisfied) }
        }
    }

    private func networkSettled(route: String, satisfied: Bool) {
        networkSettleTimer = nil
        guard satisfied, !route.isEmpty else { return }       // offline: wait for the network
        let broken = vpnRouteBroken || route != vpnRoute
        guard broken else {
            if vpnSession == .running {
                appendLog("VPN: its route (\(route)) did not change; no reconnection needed")
            }
            return
        }
        vpnRoute = route
        vpnRouteBroken = false
        vpnReconnectToken += 1
        guard vpnSession == .running else { return }
        let token = vpnReconnectToken
        let host = vpnServerHost
        // Right after a change macOS may not have DNS servers yet: OpenVPN's lookup then
        // fails and it retries only after 2 s. Wait (up to 3 s) until the server's name
        // resolves, so the reconnect gets through at the first attempt.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let waited = Self.waitUntilResolvable(host, limit: 3)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, token == self.vpnReconnectToken, self.vpnSession == .running else { return }
                    if waited >= 0.05 {
                        self.appendLog(String(format: "VPN: DNS ready after %.1f s", waited))
                    }
                    self.appendLog("VPN: reconnecting now on the new network")
                    ovpn_reconnect()
                }
            }
        }
    }

    /// "host:port" or "host port N" (as VPNProfileInfo shows it) → "host".
    nonisolated static func hostName(of server: String) -> String {
        if let r = server.range(of: " port ") { return String(server[..<r.lowerBound]) }
        if server.filter({ $0 == ":" }).count == 1, let i = server.firstIndex(of: ":") {
            return String(server[..<i])
        }
        return server
    }

    /// Seconds spent waiting for `host` to resolve, at most `limit`. IP addresses and an
    /// unknown host return at once.
    nonisolated private static func waitUntilResolvable(_ host: String, limit: TimeInterval) -> TimeInterval {
        guard !host.isEmpty, IPv4Address(host) == nil, IPv6Address(host) == nil else { return 0 }
        let start = Date()
        while true {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_DGRAM
            var res: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host, nil, &hints, &res)
            if res != nil { freeaddrinfo(res) }
            let elapsed = Date().timeIntervalSince(start)
            if rc == 0 || elapsed >= limit { return elapsed }
            usleep(200_000)
        }
    }

    private func handleVPNFinished(error: Bool, message: String) {
        let previous = vpnSession
        vpnSession = .none
        closeTunnel()
        if previous == .stopping {
            appendLog("VPN: disconnected")
            if restartVPNAfterStop {
                restartVPNAfterStop = false
                startVPN()
            }
            return
        }
        // Unexpected end: the server refused us, or OpenVPN gave up.
        appendLog("VPN: session ended\(message.isEmpty ? "" : ": \(message)")")
        if vpnAuthFailed {
            vpnFailed("login refused by the VPN server. Check the VPN username and password.", retry: false)
        } else {
            vpnFailed(vpnLastError ?? (message.isEmpty ? "the VPN connection ended" : message), retry: true)
        }
    }
}
