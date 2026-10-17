import AppKit
import AVFoundation
import CSIPCore
import Foundation
import Network

enum RegistrationState: Equatable {
    case offline
    case registering
    case registered(expires: Int)
    case failed(code: Int, reason: String)
}

enum CallPhase: Equatable {
    case dialing, ringingOut, incoming, connecting, active, ended
}

struct ActiveCall: Equatable, Identifiable {
    var id: Int32
    var number: String
    var displayName = ""
    var uri = ""
    var phase: CallPhase
    var incoming: Bool
    var connectedAt: Date?
    var muted = false
    var volume: Float = 1       // what we hear of this call, 0...1 of the system volume
    var recording = false       // being recorded to a file (see Extras.swift)
    var conferenceWith: Int32?  // joined with this other call (conference)
    var voicemailPending = false    // Do Not Disturb: silent, the answering machine answers later
    var voicemail = false           // answered by the answering machine
    var messagePath: String?        // where the machine records the caller
    var onHold = false          // put on hold by us
    var remoteHold = false      // put on hold by the other party
    var statusText = ""
    var transferStatus: String?
    var hangupRequested = false
    // Live media information, refreshed every 2 seconds (the figures that change at
    // every refresh are kept apart, in SIPEngine.mediaStats).
    var encrypted = false
    var quality = -1            // -1 unknown, 0 no audio, 1...4
    var codec = ""

    var title: String { displayName.isEmpty ? number : displayName }
    var isLive: Bool { phase != .incoming && phase != .ended }
}

/// A call's network figures, which change at every refresh. Kept out of ActiveCall so
/// that only the statistics view redraws for them, not everything showing the call.
struct MediaStats: Equatable {
    var lossPct = 0.0
    var jitterMs = 0
    var rttMs = 0
}

struct RecentCall: Codable, Identifiable, Hashable {
    var id = UUID()
    var number: String
    var name: String?
    var date: Date
    var incoming: Bool
    var answered: Bool
    var duration: TimeInterval
    var voicemail: Bool? = nil      // a message was left on the answering machine
}

/// The log's lines (see SIPEngine.logStore).
@MainActor
@Observable
final class LogStore {
    var lines: [String] = []
}

struct AudioDevice: Identifiable, Hashable {
    var id: Int32
    var name: String
    var inputs: Int
    var outputs: Int
}

/// Bridges the C SIP core to SwiftUI. All published state is mutated on the main thread.
@MainActor
@Observable
final class SIPEngine {
    static let passwordKey = "default"

    /// Stable identity of this installation, sent in the registration as +sip.instance
    /// (RFC 5626), so the registrar recognises refreshes as coming from the same device.
    static let instanceID: String = {
        let key = "sipInstanceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()
    private static let instanceIDCString = strdup(instanceID)

    var settings = AccountSettings.load()
    var registration: RegistrationState = .offline
    /// All calls, in the order they started. At most one is live (not on hold).
    private(set) var calls: [ActiveCall] = []
    /// The call shown on the call screen.
    private(set) var currentCallID: Int32?
    /// Chosen microphone and speaker by name ("" = system default), remembered
    /// between launches and applied whenever the SIP stack runs.
    var inputDeviceName = UserDefaults.standard.string(forKey: "audioInput") ?? "" {
        didSet {
            UserDefaults.standard.set(inputDeviceName, forKey: "audioInput")
            applyAudioDevices()
        }
    }
    var outputDeviceName = UserDefaults.standard.string(forKey: "audioOutput") ?? "" {
        didSet {
            UserDefaults.standard.set(outputDeviceName, forKey: "audioOutput")
            applyAudioDevices()
        }
    }
    var lastError: String?
    /// The Mac's microphones and speakers, refreshed when they change (the menus read
    /// this instead of asking Core Audio at every redraw).
    private(set) var systemAudioDevices = SystemAudioDevice.all()
    /// The log lines live in their own object: a new line then updates only the Log tab,
    /// not every view that watches the engine.
    let logStore = LogStore()
    var log: [String] { logStore.lines }
    private(set) var recents: [RecentCall] = []
    var showSettings = false

    // In-app VPN (see VPN.swift).
    var vpnSettings = VPNSettings.load()
    var vpnState: VPNState = .off
    var vpnSession = VPNSession.none
    var tunnel: VPNTunnel?
    /// The SIP connection to make once the VPN tunnel is up.
    var pendingSIPConnect: (proxyIndex: Int, isFailover: Bool)?
    var restartVPNAfterStop = false
    var vpnAuthFailed = false
    /// The last error OpenVPN reported in this session, in words.
    var vpnLastError: String?

    /// Only one copy of the app may be registered with an account (see RegistrationLock).
    private let registrationLock = RegistrationLock()
    var registrationConflict: RegistrationConflict?
    /// The user chose to register although another softphone is open.
    private var allowWithOtherSoftphone = false

    // Following audio device changes (see audioHardwareChanged).
    private var audioChangeWork: DispatchWorkItem?
    private var lastDefaultInput = AudioHardwareMonitor.defaultDevice(input: true)
    private var lastDefaultOutput = AudioHardwareMonitor.defaultDevice(input: false)
    private var lastInputPresent = true
    private var lastOutputPresent = true
    private var lastDeviceNames = Set(SystemAudioDevice.all().map(\.name).filter { !$0.hasPrefix("VPAUAggregateAudioDevice") })
    /// Device changes not yet handed to the SIP stack (applied when the call ends).
    private var audioDevicesPending = false

    // VPN diagnostics (see VPN.swift).
    var vpnStatsTimer: Timer?
    /// Since when the tunnel is gone while SIP and the calls are kept (see handleTunnelDown).
    var tunnelLostAt: Date?
    var tunnelLostTimer: Timer?
    /// Watches the Mac's network, to reconnect the VPN at once when it changes.
    var networkMonitor: NWPathMonitor?
    var networkSignature = ""
    /// The interface the VPN goes out on, with its address ("en11 192.168.1.5"), when the
    /// VPN last (re)connected; and whether that route broke since (offline, or replaced).
    var vpnRoute = ""
    var vpnRouteBroken = false
    var networkSettleTimer: Timer?
    /// The VPN server's host name, resolved before reconnecting after a network change.
    var vpnServerHost = ""
    /// Bumped on every network change; only the latest pending reconnect runs.
    var vpnReconnectToken = 0
    var vpnStatsWindow = VPNStatsWindow()

    /// A proxy failure seen during a call, handled when the last call ends.
    private var failoverAfterCalls: String?

    private var ringTimer: Timer?
    private var statsTimer: Timer?
    /// Network figures of the active calls (see refreshMediaInfo).
    private(set) var mediaStats: [Int32: MediaStats] = [:]

    /// Index into `settings.proxies` of the outbound proxy in use.
    private(set) var activeProxyIndex = 0
    /// Proxies tried since the last successful registration.
    private var failoverAttempts = 0
    private var registrationWatchdog: Timer?
    /// Pending retry after every proxy failed, and how many such rounds failed in a row.
    var retryTimer: Timer?
    var backoffLevel = 0
    /// The local port chosen at the first start of this session (when the setting is
    /// "automatic"), reused for every reconnect so the provider sees one device.
    private var sessionPort: Int32 = 0

    /// Pause before the next round after every proxy failed: 30 s doubling up to
    /// 15 min, randomised to 50–100 % (as RFC 5626 recommends), so the provider is
    /// not flooded with attempts.
    static func retryDelay(level: Int) -> TimeInterval {
        let ceiling = min(900, 30 * pow(2, Double(min(level, 10))))
        return ceiling * Double.random(in: 0.5...1)
    }
    /// A proxy that does not answer within this time is considered down.
    static let registrationTimeout: TimeInterval = 10
    /// Incremented on every (re)start of the SIP stack, so that late events
    /// from a stopped stack are ignored. Read from SIP threads.
    @ObservationIgnored nonisolated(unsafe) private var generation = 0

    var activeProxy: String? {
        let p = settings.proxies
        return p.indices.contains(activeProxyIndex) ? p[activeProxyIndex] : nil
    }

    var call: ActiveCall? {
        calls.first { $0.id == currentCallID } ?? calls.first
    }

    /// An incoming call that arrived while another call is on screen (call waiting).
    var waitingCall: ActiveCall? {
        calls.first { $0.phase == .incoming && $0.id != call?.id }
    }

    var otherCalls: [ActiveCall] {
        calls.filter { $0.id != call?.id && $0.phase != .incoming }
    }

    /// Incoming calls not answered (nor declined by us) since Recents was last viewed.
    var missedCalls = UserDefaults.standard.integer(forKey: "missedCalls") {
        didSet {
            UserDefaults.standard.set(missedCalls, forKey: "missedCalls")
            NSApp.dockTile.badgeLabel = missedCalls > 0 ? "\(missedCalls)" : nil
        }
    }
    /// Incoming calls are refused (busy) and only noted in Recents.
    var doNotDisturb = UserDefaults.standard.bool(forKey: "doNotDisturb") {
        didSet { UserDefaults.standard.set(doNotDisturb, forKey: "doNotDisturb") }
    }
    /// Messages on the answering machine, newest first, and those already listened to.
    var voiceMessages: [VoiceMessage] = AnsweringMachine.messages()
    var heardMessages = Set(UserDefaults.standard.stringArray(forKey: "voicemailHeard") ?? []) {
        didSet { UserDefaults.standard.set(Array(heardMessages), forKey: "voicemailHeard") }
    }
    let greetingRecorder = GreetingRecorder()
    /// A tab the window should show (set from a notification or the menu bar).
    var requestedTab: Int?
    /// Set to ask the menu bar extra to open the main window.
    var windowRequest = 0
    /// Whether the main window is open (for the menu bar's Open / Close Window item).
    var mainWindowOpen = false
    /// The window was closed and opened only for an incoming call: it closes again when
    /// the calls are over, leaving the menu bar icon (with the missed call count).
    var windowOpenedForCall = false
    /// The call panel was put away ("–") for the calls in progress; back with
    /// Show Call Panel in the menu bar, or at the next call.
    var callPanelHidden = false
    /// Bumped when the Contacts names change, so that views showing names redraw.
    private(set) var contactsVersion = 0
    @ObservationIgnored lazy var contacts: ContactsDirectory = {
        let d = ContactsDirectory()
        d.onChange = { [weak self] in self?.contactsVersion += 1 }
        return d
    }()

    init() {
        if let data = UserDefaults.standard.data(forKey: "recents"),
           let r = try? JSONDecoder().decode([RecentCall].self, from: data) {
            recents = r
        }
        AudioHardwareMonitor.start { [weak self] in
            MainActor.assumeIsolated { self?.audioHardwareChanged() }
        }
    }

    #if DEBUG
    /// Used by tests instead of the Keychain.
    var debugPassword: String?
    var debugVPNProfile: String?
    var debugVPNPassword: String?
    #endif

    var password: String {
        get {
            #if DEBUG
            if let debugPassword { return debugPassword }
            #endif
            if Bench.isActive { return Bench.password }
            return Keychain.password(for: Self.passwordKey)
        }
        set {
            guard !Bench.isActive else { return }
            Keychain.setPassword(newValue, for: Self.passwordKey)
        }
    }

    // MARK: - Connection

    func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                Task { @MainActor in
                    self.lastError = "Microphone access denied. Enable it in System Settings › Privacy & Security › Microphone."
                }
            }
        }
    }

    /// Connects using the first (primary) outbound proxy.
    func connect() {
        if settings.namesFromContacts { contacts.load() }
        if doNotDisturb && settings.answeringMachine { prepareGreeting() }
        connect(proxyIndex: 0)
    }

    /// Switches to another outbound proxy (not while calls are in progress).
    func useProxy(_ index: Int) {
        guard calls.isEmpty else {
            lastError = "The proxy can be changed when no call is in progress."
            return
        }
        connect(proxyIndex: index)
    }

    func connect(proxyIndex: Int, isFailover: Bool = false) {
        // After a failure, don't wait for the unreachable proxy to answer an un-REGISTER.
        disconnect(quick: isFailover)
        generation += 1
        lastError = nil
        if !isFailover {
            failoverAttempts = 0
            backoffLevel = 0
        }
        let s = settings
        guard s.isComplete else {
            lastError = "Complete the account configuration."
            showSettings = true
            return
        }
        let pwd = password
        guard !pwd.isEmpty else {
            lastError = "Enter the SIP password in the account configuration."
            showSettings = true
            return
        }
        guard isFailover || mayRegister(s) else { return }
        // Through the VPN: start it first; SIP follows once the tunnel is up.
        var vpnTunnel: VPNTunnel?
        if vpnSettings.enabled {
            guard let t = tunnel else {
                pendingSIPConnect = (proxyIndex, isFailover)
                registration = .registering
                startVPN()
                return
            }
            vpnTunnel = t
        } else if vpnSession != .none || vpnState != .off {
            // Also clears a failed VPN state left from before the VPN was turned off.
            stopVPN()
        }
        var err = [CChar](repeating: 0, count: 512)
        var cb = sip_callbacks()
        cb.on_reg_state = { ctx, code, reason, expires in
            let r = reason.map { String(cString: $0) } ?? ""
            let engine = Unmanaged<SIPEngine>.fromOpaque(ctx!).takeUnretainedValue()
            let gen = engine.generation
            DispatchQueue.main.async {
                engine.handleRegistration(code: Int(code), reason: r, expires: Int(expires), generation: gen)
            }
        }
        cb.on_incoming_call = { ctx, callID, remote in
            let r = remote.map { String(cString: $0) } ?? ""
            let engine = Unmanaged<SIPEngine>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { engine.handleIncoming(id: callID, remote: r) }
        }
        cb.on_call_state = { ctx, callID, state, code, reason, remote in
            let rs = reason.map { String(cString: $0) } ?? ""
            let rm = remote.map { String(cString: $0) } ?? ""
            let engine = Unmanaged<SIPEngine>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async {
                engine.handleCallState(id: callID, state: Int(state), code: Int(code), reason: rs, remote: rm)
            }
        }
        cb.on_transfer_status = { ctx, callID, code, reason, final in
            let r = reason.map { String(cString: $0) } ?? ""
            let engine = Unmanaged<SIPEngine>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async {
                engine.handleTransfer(id: callID, code: Int(code), reason: r, final: final != 0)
            }
        }
        cb.on_log = { ctx, _, msg in
            let m = msg.map { String(cString: $0) } ?? ""
            let engine = Unmanaged<SIPEngine>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { engine.appendLog(m) }
        }

        let proxies = s.proxies
        activeProxyIndex = proxies.indices.contains(proxyIndex) ? proxyIndex : 0
        let proxyURI = s.proxyURI(proxies[activeProxyIndex])
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let rc: Int32 = s.displayName.withCString { dn in
            s.sipUser.withCString { user in
                s.authUser.withCString { auth in
                    pwd.withCString { pw in
                        s.sipDomain.withCString { dom in
                            proxyURI.withCString { proxy in
                              (vpnTunnel?.ip ?? "").withCString { vpnIP in
                                var c = sip_config()
                                c.display_name = dn
                                c.user = user
                                c.auth_user = auth
                                c.password = pw
                                c.domain = dom
                                c.proxy = proxy
                                c.transport = Int32(s.transport.sipValue)
                                c.tls_verify = s.verifyTLSCertificate ? 1 : 0
                                c.srtp = Int32(s.srtp.sipValue)
                                c.local_port = s.localPort > 0 ? Int32(s.localPort) : sessionPort
                                c.reg_timeout = Int32(s.registrationExpiry)
                                c.instance_id = UnsafePointer(Self.instanceIDCString)
                                c.quiet_log = s.logDetail == .off ? 1 : 0
                                c.g729 = s.g729 == .preferred ? 1 : s.g729 == .off ? -1 : 0
                                if let t = vpnTunnel {
                                    // sip_start owns the descriptor it gets; the tunnel keeps its own.
                                    c.use_vpn = 1
                                    c.vpn_fd = dup(t.fd)
                                    c.vpn_ip = vpnIP
                                    c.vpn_mtu = t.mtu
                                }
                                return sip_start(&c, &cb, ctx, &err, Int32(err.count))
                              }
                            }
                        }
                    }
                }
            }
        }
        if rc != 0 && s.localPort == 0 && sessionPort != 0 {
            // The session port is no longer free: let the system pick another one.
            sessionPort = 0
            connect(proxyIndex: proxyIndex, isFailover: isFailover)
            return
        }
        if rc == 0 {
            if s.localPort == 0 { sessionPort = sip_local_port() }
            registration = .registering
            if !inputDeviceName.isEmpty || !outputDeviceName.isEmpty { applyAudioDevices() }
            startWatchdog()
        } else {
            registration = .offline
            lastError = String(cString: err)
        }
    }

    func disconnect(quick: Bool = false) {
        tunnelLostAt = nil
        tunnelLostTimer?.invalidate()
        tunnelLostTimer = nil
        stopWatchdog()
        retryTimer?.invalidate()
        retryTimer = nil
        stopRinging()
        if quick { sip_stop_quick() } else { sip_stop() }
        // Whatever the stopped stack still reports (e.g. its pending REGISTER
        // failing) must not trigger a new attempt.
        generation += 1
        registration = .offline
        calls.forEach(finishCall)
        calls = []
        currentCallID = nil
        updateStatsTimer()
    }

    /// True unless the app is offline (registered, registering, or waiting to retry).
    var isOnline: Bool {
        if case .offline = registration { return false }
        return true
    }

    /// Unregisters and stops all SIP traffic, including pending retries, until
    /// the user registers again.
    func goOffline() {
        guard calls.isEmpty else {
            lastError = "End the call before going offline."
            return
        }
        disconnect()
        registrationLock.release()
        stopVPN()
        lastError = nil
    }

    func reregister() {
        if sip_is_running() != 0 {
            registration = .registering
            sip_reregister()
            startWatchdog()
        } else {
            connect()
        }
    }

    // MARK: - One registration per account

    /// False (and explains why in an alert) if another copy of the app is registered
    /// with this account, or if another SIP softphone is open and may be.
    private func mayRegister(_ s: AccountSettings) -> Bool {
        if let holder = registrationLock.acquire(account: "\(s.sipUser)@\(s.sipDomain)") {
            let app = holder.pid > 0 ? NSRunningApplication(processIdentifier: holder.pid) : nil
            registrationConflict = RegistrationConflict(
                title: "\(holder.name) is already registered",
                message: "\(holder.name) is registered as \(s.sipUser). Two registrations of the same line "
                    + "can make the provider stop answering both. Go offline in \(holder.name) or quit it "
                    + "(a call in progress there would end).",
                otherApp: app)
            return false
        }
        if !allowWithOtherSoftphone, let other = Self.openSoftphone() {
            registrationLock.release()
            registrationConflict = RegistrationConflict(
                title: "\(other) is open",
                message: "If \(other) is registered with the same line (\(s.sipUser)), the provider may stop "
                    + "answering both. Quit \(other) or turn its account off first.",
                canRegisterAnyway: true)
            return false
        }
        return true
    }

    /// Asks the other copy to quit (it unregisters as it quits), then registers.
    func quitOtherCopyAndConnect(_ conflict: RegistrationConflict) {
        guard let app = conflict.otherApp else { return }
        let name = conflict.otherName
        app.terminate()
        lastError = "Waiting for \(name) to quit…"
        let deadline = Date().addingTimeInterval(20)
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            MainActor.assumeIsolated {
                if app.isTerminated {
                    timer.invalidate()
                    self.lastError = nil
                    self.connect()
                } else if Date() > deadline {
                    timer.invalidate()
                    self.lastError = "\(name) did not quit. Quit it, then register."
                }
            }
        }
    }

    /// Other SIP softphone apps, by the start of their names.
    private static let otherSoftphones = ["Linphone", "Zoiper", "Bria", "X-Lite", "Telephone",
                                          "Groundwire", "Acrobits Softphone"]

    /// The name of another SIP softphone running on this Mac, if any.
    private static func openSoftphone() -> String? {
        NSWorkspace.shared.runningApplications.lazy.compactMap(\.localizedName).first { name in
            otherSoftphones.contains { name.lowercased().hasPrefix($0.lowercased()) }
        }
    }

    func registerAnyway() {
        allowWithOtherSoftphone = true
        connect()
    }

    // MARK: - Proxy failover

    static func format(_ t: TimeInterval) -> String {
        t < 90 ? "\(Int(t)) s" : "\(Int((t / 60).rounded())) min"
    }

    private func startWatchdog() {
        stopWatchdog()
        let gen = generation
        registrationWatchdog = Timer.scheduledTimer(withTimeInterval: Self.registrationTimeout, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard gen == self.generation, case .registering = self.registration else { return }
                self.failover(after: "no response")
            }
        }
    }

    private func stopWatchdog() {
        registrationWatchdog?.invalidate()
        registrationWatchdog = nil
    }

    /// Timeouts, transport errors and server errors mean the proxy may be down;
    /// authentication errors (401/403/404...) would fail on every proxy.
    private static func isProxyFailure(_ code: Int) -> Bool {
        code == 0 || code == 408 || code >= 500
    }

    /// Re-registers to verify that the proxy still answers; if it does not within
    /// `registrationTimeout`, the watchdog reconnects or moves to the next proxy.
    private func checkConnection() {
        guard sip_is_running() != 0 else { return }
        registration = .registering
        sip_reregister()
        startWatchdog()
    }

    /// After the current proxy failed: moves to the next one, or with a single proxy
    /// reconnects on a fresh connection (new socket, so the router creates a new mapping).
    private func failover(after problem: String) {
        stopWatchdog()
        // Nothing came back at all: the next attempt goes out from a new local port. A
        // router or VPN server may hold a stale NAT or firewall entry for the old port and
        // keep dropping the replies to it for as long as we keep using it.
        if problem == "no response" && settings.localPort == 0 && sessionPort != 0 {
            appendLog("No response to the registration: the next attempt uses a new local port")
            sessionPort = 0
        }
        let proxies = settings.proxies
        let failed = activeProxy ?? "?"
        guard calls.isEmpty, !proxies.isEmpty else {
            if case .registering = registration { registration = .failed(code: 0, reason: problem) }
            lastError = "Registration via \(failed) failed: \(problem)."
            // Switching proxy would end the call: do it once the calls are over.
            if !calls.isEmpty { failoverAfterCalls = problem }
            return
        }
        failoverAttempts += 1
        guard failoverAttempts < max(proxies.count, 2) else {
            // Every proxy failed: stop sending, and try again later with growing pauses.
            let delay = Self.retryDelay(level: backoffLevel)
            backoffLevel += 1
            disconnect(quick: true)
            failoverAttempts = 0
            registration = .failed(code: 0, reason: "No answer, next attempt in \(Self.format(delay))")
            lastError = (proxies.count > 1
                ? "No outbound proxy answered (last tried \(failed): \(problem)). "
                : "Registration via \(failed) failed: \(problem). ")
                + "Trying again at \(Date().addingTimeInterval(delay).formatted(date: .omitted, time: .shortened)); "
                + "press ↻ to try now."
            retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { self.connect(proxyIndex: 0, isFailover: true) }
            }
            return
        }
        let next = proxies.count > 1 ? (activeProxyIndex + 1) % proxies.count : activeProxyIndex
        connect(proxyIndex: next, isFailover: true)
        lastError = proxies.count > 1
            ? "\(failed) did not work (\(problem)); switched to \(proxies[next])."
            : "No answer from \(failed) (\(problem)); reconnected."
    }

    // MARK: - Calls

    /// Starts a call. An existing live call is put on hold first ("add call").
    func dial(_ number: String) {
        let n = number.filter { "0123456789+*#".contains($0) }
        guard !n.isEmpty else { return }
        guard case .registered = registration else {
            lastError = "Not registered."
            return
        }
        guard calls.count < 4 else {
            lastError = "Too many calls."
            return
        }
        holdLiveCalls()
        var id: Int32 = -1
        var err = [CChar](repeating: 0, count: 256)
        if sip_make_call(n, &id, &err, Int32(err.count)) == 0 {
            calls.append(ActiveCall(id: id, number: n, displayName: contactName(for: n) ?? "",
                                    uri: "sip:\(n)@\(settings.sipDomain)",
                                    phase: .dialing, incoming: false, statusText: "Calling…"))
            currentCallID = id
            updateStatsTimer()
        } else {
            lastError = String(cString: err)
        }
    }

    /// Answers the given incoming call (default: the one on screen), holding any live call.
    func answer(_ id: Int32? = nil) {
        guard let target = id ?? call?.id,
              let c = calls.first(where: { $0.id == target }), c.phase == .incoming else { return }
        holdLiveCalls(except: target)
        update(target) { $0.voicemailPending = false }
        sip_answer(target, 200)
        currentCallID = target
        updateRinging()
    }

    func decline(_ id: Int32) {
        sip_hangup(id, 603)
    }

    /// Ends the given call (default: the one on screen); declines it if still ringing.
    func hangup(_ id: Int32? = nil) {
        guard let target = id ?? call?.id,
              let c = calls.first(where: { $0.id == target }) else { return }
        update(target) { $0.hangupRequested = true }
        sip_hangup(target, c.phase == .incoming ? 603 : 0)
    }

    /// Brings another call to the screen: the current one is held and the other resumed.
    func switchTo(_ id: Int32) {
        guard id != call?.id, let target = calls.first(where: { $0.id == id }), target.phase != .incoming else { return }
        holdLiveCalls(except: id)
        if target.onHold { setHold(id, false) }
        currentCallID = id
    }

    /// True while there is a call whose microphone can be muted.
    var canMute: Bool { call?.isLive ?? false }

    var canHold: Bool { call?.phase == .active }

    func toggleMute() {
        guard canMute, let c = call else { return }
        update(c.id) { $0.muted.toggle() }
        sip_set_mute(c.id, c.muted ? 0 : 1)
    }

    /// Lowers (or restores) only this call, e.g. to keep hold music quiet.
    func setVolume(_ level: Float, for id: Int32) {
        let v = min(max(level, 0), 1)
        update(id) { $0.volume = v }
        sip_set_volume(id, v)
    }

    func toggleHold() {
        guard canHold, let c = call else { return }
        if c.onHold { holdLiveCalls(except: c.id) }
        setHold(c.id, !c.onHold)
    }

    func sendDTMF(_ digit: String) {
        guard let c = call, c.phase == .active else { return }
        sip_send_dtmf(c.id, digit)
        if settings.keypadTones { sip_play_keypad_tone(digit) }
    }

    /// Feedback for a key pressed while dialling (no call: the tone is played by the
    /// app itself, without opening the microphone).
    func keypadFeedback(_ keys: String) {
        guard settings.keypadTones, let key = keys.last else { return }
        keypadTonePlayer.play(key)
    }

    @ObservationIgnored private lazy var keypadTonePlayer = KeypadTonePlayer()

    /// Blind transfer of the call on screen to a number.
    func transfer(to number: String) {
        let n = number.filter { "0123456789+*#".contains($0) }
        guard let c = call, c.phase == .active, !n.isEmpty else { return }
        var err = [CChar](repeating: 0, count: 256)
        if sip_transfer(c.id, n, &err, Int32(err.count)) == 0 {
            update(c.id) { $0.transferStatus = "Transferring to \(n)…" }
        } else {
            lastError = String(cString: err)
        }
    }

    /// Attended transfer: connects the party of the call on screen with the party of `other`.
    func transfer(toCall other: Int32) {
        guard let c = call, c.phase == .active, other != c.id else { return }
        var err = [CChar](repeating: 0, count: 256)
        if sip_transfer_to_call(c.id, other, &err, Int32(err.count)) == 0 {
            let name = calls.first { $0.id == other }?.title ?? ""
            update(c.id) { $0.transferStatus = "Transferring to \(name)…" }
        } else {
            lastError = String(cString: err)
        }
    }

    // MARK: - Audio devices

    func audioDevices() -> [AudioDevice] {
        (0..<sip_audio_dev_count()).compactMap { i in
            var name = [CChar](repeating: 0, count: 128)
            var inputs: Int32 = 0, outputs: Int32 = 0
            guard sip_audio_dev_info(i, &name, Int32(name.count), &inputs, &outputs) == 0 else { return nil }
            return AudioDevice(id: i, name: String(cString: name), inputs: Int(inputs), outputs: Int(outputs))
        }
    }

    /// Devices come and go in bursts (AirPods appear as a microphone and a speaker,
    /// then become the default): act once things settle.
    private func audioHardwareChanged() {
        audioChangeWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { self.followAudioDevices() } }
        audioChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func followAudioDevices() {
        let input = AudioHardwareMonitor.defaultDevice(input: true)
        let output = AudioHardwareMonitor.defaultDevice(input: false)
        // macOS adds and removes its own helper device ("VPAUAggregateAudioDevice") every
        // time voice processing starts or stops: not a change of the user's devices.
        let devices = SystemAudioDevice.all().filter { !$0.name.hasPrefix("VPAUAggregateAudioDevice") }
        if devices != systemAudioDevices { systemAudioDevices = devices }
        let names = Set(devices.map(\.name))
        let listChanged = names != lastDeviceNames
        lastDeviceNames = names
        let inputPresent = inputDeviceName.isEmpty || devices.contains { $0.name == inputDeviceName && $0.hasInput }
        let outputPresent = outputDeviceName.isEmpty || devices.contains { $0.name == outputDeviceName && $0.hasOutput }
        // The call needs its sound device reopened only if it uses a default that changed,
        // or its chosen device came or went; other changes wait until the call ends.
        let relevant = ((inputDeviceName.isEmpty || !inputPresent) && input != lastDefaultInput)
            || ((outputDeviceName.isEmpty || !outputPresent) && output != lastDefaultOutput)
            || inputPresent != lastInputPresent || outputPresent != lastOutputPresent
        lastDefaultInput = input
        lastDefaultOutput = output
        lastInputPresent = inputPresent
        lastOutputPresent = outputPresent
        guard sip_is_running() != 0, relevant || listChanged else { return }
        appendLog("Audio devices changed; system default: microphone "
                  + "\(SystemAudioDevice.name(of: input) ?? "none"), speaker \(SystemAudioDevice.name(of: output) ?? "none")")
        if calls.contains(where: { $0.isLive }) && !relevant {
            audioDevicesPending = true
        } else {
            applyAudioDevices()
        }
    }

    /// Hands the chosen devices to the SIP stack (matched by name, since its device
    /// numbers change when devices are plugged in). A missing device falls back to
    /// the system default until it is connected again. During a call the sound device
    /// is reopened, so the call moves to the new devices (or the new system default).
    private func applyAudioDevices() {
        guard sip_is_running() != 0 else { return }
        audioDevicesPending = false
        // A chosen device that is not connected falls back to the system default.
        let devices = SystemAudioDevice.all()
        let inputMissing = !inputDeviceName.isEmpty && !devices.contains { $0.name == inputDeviceName && $0.hasInput }
        let outputMissing = !outputDeviceName.isEmpty && !devices.contains { $0.name == outputDeviceName && $0.hasOutput }
        let input = inputMissing ? "" : inputDeviceName
        let output = outputMissing ? "" : outputDeviceName
        // With both on the system default, macOS voice processing uses the system devices.
        // With only one, name the current system default for the other: PJSIP's own
        // "default" can be a virtual device (e.g. a conferencing app's).
        let bothDefault = input.isEmpty && output.isEmpty
        let inputName = !input.isEmpty || bothDefault ? input
            : SystemAudioDevice.name(of: AudioHardwareMonitor.defaultDevice(input: true)) ?? ""
        let outputName = !output.isEmpty || bothDefault ? output
            : SystemAudioDevice.name(of: AudioHardwareMonitor.defaultDevice(input: false)) ?? ""
        var inputFound: Int32 = 1, outputFound: Int32 = 1
        let rc = sip_apply_audio_devs(inputName, outputName, calls.contains { $0.isLive } ? 1 : 0,
                                      &inputFound, &outputFound)
        if rc == 1 {
            // The sound device stays open for a moment after a call: try again once it closed.
            audioDevicesPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { if self.audioDevicesPending { self.applyAudioDevices() } }
            }
        } else if rc != 0 {
            lastError = "Cannot use the selected audio device."
        } else {
            // Moved during a call (chosen in the menus, or a default that changed): log
            // what the call uses from now on.
            if calls.contains(where: { $0.isLive }) { logCallAudioDevices(changed: true) }
        }
        if rc == 0 && inputMissing {
            lastError = "\(inputDeviceName) is not connected; using the system default microphone."
        } else if rc == 0 && outputMissing {
            lastError = "\(outputDeviceName) is not connected; using the system default speaker."
        }
    }

    // MARK: - Call helpers

    func update(_ id: Int32, _ change: (inout ActiveCall) -> Void) {
        guard let i = calls.firstIndex(where: { $0.id == id }) else { return }
        // Only a real change is published: the 2 s stats refresh otherwise redraws every
        // window and the menu bar for nothing.
        var call = calls[i]
        change(&call)
        if call != calls[i] { calls[i] = call }
    }

    func setHold(_ id: Int32, _ hold: Bool) {
        if sip_set_hold(id, hold ? 1 : 0) == 0 {
            update(id) { $0.onHold = hold }
        }
    }

    func holdLiveCalls(except id: Int32? = nil) {
        let partner = id.flatMap { i in calls.first { $0.id == i }?.conferenceWith }
        for c in calls where c.id != id && c.id != partner && c.phase == .active && !c.onHold {
            setHold(c.id, true)
        }
    }

    private func updateRinging() {
        if calls.contains(where: { $0.phase == .incoming && !$0.voicemailPending }) {
            if ringTimer == nil { startRinging() }
        } else {
            stopRinging()
        }
    }

    private func updateStatsTimer() {
        if calls.isEmpty {
            statsTimer?.invalidate()
            statsTimer = nil
        } else if statsTimer == nil {
            statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated { self.refreshMediaInfo() }
            }
        }
    }

    private func refreshMediaInfo() {
        var stats: [Int32: MediaStats] = [:]
        for c in calls where c.phase == .active {
            var info = sip_media_info()
            guard sip_call_media_info(c.id, &info) == 0 else { continue }
            let codec = withUnsafeBytes(of: info.codec) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            update(c.id) {
                $0.encrypted = info.encrypted != 0
                $0.quality = Int(info.quality)
                $0.codec = codec
                $0.remoteHold = Int(info.media_status) == SIP_MEDIA_REMOTE_HOLD
            }
            stats[c.id] = MediaStats(lossPct: info.loss_pct, jitterMs: Int(info.jitter_ms), rttMs: Int(info.rtt_ms))
        }
        if stats != mediaStats { mediaStats = stats }
    }

    func clearRecents() {
        recents = []
        saveRecents()
    }

    func deleteRecent(_ r: RecentCall) {
        recents.removeAll { $0.id == r.id }
        saveRecents()
    }

    func clearLog() { logStore.lines = [] }

    // MARK: - Callback handlers

    private func handleRegistration(code: Int, reason: String, expires: Int, generation gen: Int) {
        guard gen == generation else { return }
        if code / 100 == 2 {
            failoverAfterCalls = nil
            stopWatchdog()
            failoverAttempts = 0
            backoffLevel = 0
            registration = expires > 0 ? .registered(expires: expires) : .offline
        } else {
            registration = .failed(code: code, reason: reason)
            if Self.isProxyFailure(code) {
                failover(after: "\(code) \(reason)")
            } else {
                stopWatchdog()
            }
        }
    }

    private func handleIncoming(id: Int32, remote: String) {
        var c = ActiveCall(id: id, number: "", phase: .incoming, incoming: true, statusText: "Incoming call")
        Self.applyRemote(remote, to: &c)
        if c.displayName.isEmpty, let name = contactName(for: c.number) { c.displayName = name }
        if doNotDisturb {
            if settings.answeringMachine { waitForAnsweringMachine(c) } else { refuseForDoNotDisturb(c) }
            return
        }
        calls.append(c)
        if currentCallID == nil || calls.count == 1 { currentCallID = id }
        // With the call panel the app in use keeps the keyboard; the panel appears instead.
        if !settings.usesCallPanel {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.requestUserAttention(.criticalRequest)
        }
        updateRinging()
        updateStatsTimer()
        if Bench.isActive { Bench.incoming(self, id: id) }
    }

    private func handleCallState(id: Int32, state: Int, code: Int, reason: String, remote: String) {
        guard let i = calls.firstIndex(where: { $0.id == id }) else { return }
        var c = calls[i]
        switch state {
        case SIP_CALL_CALLING:
            c.phase = .dialing; c.statusText = "Calling…"
        case SIP_CALL_EARLY:
            if !c.incoming { c.phase = .ringingOut; c.statusText = "Ringing…" }
        case SIP_CALL_CONNECTING:
            c.phase = .connecting; c.statusText = "Connecting…"
        case SIP_CALL_CONFIRMED:
            if c.phase != .active {
                c.connectedAt = Date()
                logCallAudioDevices()
            }
            c.phase = .active; c.statusText = "Connected"
        case SIP_CALL_DISCONNECTED:
            // An outgoing call that never got past "Calling…" may mean the path to the
            // proxy is broken (e.g. a router dropped the NAT mapping) although we still
            // look registered.
            let gotNoAnswer = !c.incoming && c.phase == .dialing && [408, 487, 503].contains(code)
            c.phase = .ended
            if c.connectedAt == nil && !c.incoming && code >= 300 && !(code == 487 && c.hangupRequested) {
                lastError = "Call ended: \(code) \(reason)"
            }
            finishCall(c)
            calls.remove(at: i)
            if let p = c.conferenceWith { update(p) { $0.conferenceWith = nil } }
            if currentCallID == id {
                // Show a remaining call (it stays on hold until resumed).
                currentCallID = (calls.first { $0.phase != .incoming } ?? calls.first)?.id
            }
            updateRinging()
            updateStatsTimer()
            if calls.isEmpty, let problem = failoverAfterCalls {
                failoverAfterCalls = nil
                failover(after: problem)
            } else if gotNoAnswer && calls.isEmpty {
                checkConnection()
            }
            if calls.isEmpty && audioDevicesPending { applyAudioDevices() }
            return
        default:
            break
        }
        Self.applyRemote(remote, to: &c)
        calls[i] = c
        updateRinging()
    }

    /// The devices a call really uses. With the system defaults, PJSIP hands the audio to
    /// macOS voice processing, which uses the defaults whatever device name PJSIP's own
    /// log lines show.
    private func logCallAudioDevices(changed: Bool = false) {
        func pick(_ chosen: String, input: Bool) -> String {
            let present = SystemAudioDevice.all().contains { $0.name == chosen && (input ? $0.hasInput : $0.hasOutput) }
            if !chosen.isEmpty && present { return chosen }
            return SystemAudioDevice.name(of: AudioHardwareMonitor.defaultDevice(input: input)) ?? "none"
        }
        let mic = pick(inputDeviceName, input: true), speaker = pick(outputDeviceName, input: false)
        let mode = inputDeviceName.isEmpty && outputDeviceName.isEmpty
            ? "macOS voice processing (system default devices)" : "chosen devices, software echo canceller"
        appendLog("Call audio\(changed ? " now" : ""): microphone \(mic), speaker \(speaker); \(mode)")
    }

    private func handleTransfer(id: Int32, code: Int, reason: String, final: Bool) {
        update(id) {
            if !final {
                $0.transferStatus = "Transferring… (\(code) \(reason))"
            } else if code / 100 == 2 {
                $0.transferStatus = "Transferred"
            } else {
                $0.transferStatus = nil
                // Refused outright (e.g. 403 "REFER is not allowed from this side"): say so
                // plainly rather than as a technical failure.
                lastError = [403, 405, 501, 603].contains(code)
                    ? "Your provider does not allow call transfer (\(code) \(reason))."
                    : "Transfer failed: \(code) \(reason)"
            }
        }
    }

    private func finishCall(_ c: ActiveCall) {
        if c.voicemail || c.voicemailPending {
            let finish = { [weak self] in
                guard let self, !self.finishVoicemail(c) else { return }
                self.addPlainRecent(c)
            }
            // PJSIP completes the message file a moment after the call ends (the media
            // clock removes the recorder, which then writes the WAV header): before that,
            // the file still looks empty.
            if let path = c.messagePath {
                AnsweringMachine.whenComplete(URL(fileURLWithPath: path), then: finish)
            } else {
                finish()
            }
            return
        } else if c.incoming && c.connectedAt == nil && !c.hangupRequested {
            noteMissedCall(c, notify: true)
        }
        addPlainRecent(c)
    }

    private func addPlainRecent(_ c: ActiveCall) {
        let duration = c.connectedAt.map { Date().timeIntervalSince($0) } ?? 0
        addRecent(RecentCall(number: c.number, name: c.displayName.isEmpty ? nil : c.displayName,
                             date: Date(), incoming: c.incoming,
                             answered: c.connectedAt != nil, duration: duration))
    }

    /// A call shown without ringing (the answering machine's), made current if none is.
    func addSilentCall(_ c: ActiveCall) {
        calls.append(c)
        if currentCallID == nil { currentCallID = c.id }
    }

    func makeCurrent(_ id: Int32) {
        currentCallID = id
    }

    func addRecent(_ r: RecentCall) {
        recents.insert(r, at: 0)
        if recents.count > 200 { recents.removeLast(recents.count - 200) }
        saveRecents()
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: "recents")
        }
    }

    func appendLog(_ line: String) {
        var text = line.trimmingCharacters(in: .newlines)
        // PJSIP lines start with their own time; the app's and the VPN's get one here,
        // so that the VPN's steps can be timed against the SIP messages.
        if !Self.startsWithTime(text) { text = Self.logTime.string(from: Date()) + " " + text }
        logStore.lines.append(text)
        if logStore.lines.count > 3000 { logStore.lines.removeFirst(logStore.lines.count - 3000) }
        // "Log detail: Off": nothing is written to disk.
        guard settings.logDetail != .off else { return }
        logFile?.write(Data((text + "\n").utf8))
    }

    private static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// "HH:MM:SS." at the start, as in PJSIP's log lines.
    private static func startsWithTime(_ s: String) -> Bool {
        let c = Array(s.utf8.prefix(9))
        guard c.count == 9 else { return false }
        let digit = { (b: UInt8) in b >= 48 && b <= 57 }
        return digit(c[0]) && digit(c[1]) && c[2] == 58 && digit(c[3]) && digit(c[4])
            && c[5] == 58 && digit(c[6]) && digit(c[7]) && c[8] == 46
    }

    /// ~/Library/Logs/<app name>/sip.log — the SIP log is also kept on disk
    /// for troubleshooting. The previous log is kept as sip.old.log once it exceeds 5 MB.
    static let logFileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/\(AppIdentity.name)", isDirectory: true)
        #if DEBUG
        return dir.appendingPathComponent("sip-debug.log")  // test builds don't touch the real log
        #else
        return dir.appendingPathComponent("sip.log")
        #endif
    }()

    /// Opened on first use (and again after deleteLogFiles).
    private var logFileHandle: FileHandle?

    private var logFile: FileHandle? {
        if logFileHandle == nil { logFileHandle = Self.openLogFile() }
        return logFileHandle
    }

    /// Deletes the log files of this build (the current one and the previous one)
    /// and empties the Log tab.
    func deleteLogFiles() {
        try? logFileHandle?.close()
        logFileHandle = nil
        let dir = Self.logFileURL.deletingLastPathComponent()
        for name in [Self.logFileURL.lastPathComponent, "sip.old.log"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        logStore.lines = []
    }

    private static func openLogFile() -> FileHandle? {
        let url = Self.logFileURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
            let old = url.deletingLastPathComponent().appendingPathComponent("sip.old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        handle?.write(Data("\n===== \(AppIdentity.name) started \(Date()) =====\n".utf8))
        return handle
    }

    // MARK: - Ringtone

    private func startRinging() {
        stopRinging()
        let play = { if !Bench.isActive { _ = NSSound(named: "Glass")?.play() } }
        play()
        ringTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in play() }
    }

    private func stopRinging() {
        ringTimer?.invalidate()
        ringTimer = nil
    }

    /// Splits `"Name" <sip:+15551234@example.com;user=phone>` into display name
    /// ("Name"), URI ("sip:+15551234@example.com") and number ("+15551234").
    static func parseRemote(_ s: String) -> (name: String, uri: String, number: String) {
        var name = "", uri = s.trimmingCharacters(in: .whitespaces)
        if let lt = uri.firstIndex(of: "<"), let gt = uri.lastIndex(of: ">"), lt < gt {
            name = uri[..<lt].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"")))
            uri = String(uri[uri.index(after: lt)..<gt])
        }
        if let semi = uri.firstIndex(of: ";") { uri = String(uri[..<semi]) }
        var number = uri
        for scheme in ["sips:", "sip:", "tel:"] where number.hasPrefix(scheme) {
            number.removeFirst(scheme.count)
        }
        if let at = number.firstIndex(of: "@") { number = String(number[..<at]) }
        return (name, uri, number.isEmpty ? s : number)
    }

    /// Caller IDs that mean "no number": hidden by the caller (anonymous) or not
    /// provided by the line (e.g. "Unsubscribed" <sip:unsubscribed@unsubscribed.invalid>).
    static func isUnknownCaller(_ r: (name: String, uri: String, number: String)) -> Bool {
        let n = r.number.lowercased()
        return ["anonymous", "unsubscribed", "unknown", "unavailable", "restricted", "private"].contains(n)
            || r.uri.lowercased().hasSuffix(".invalid")
    }

    private static func applyRemote(_ remote: String, to c: inout ActiveCall) {
        guard !remote.isEmpty else { return }
        let r = parseRemote(remote)
        if isUnknownCaller(r) {
            // Keep a number already known (e.g. from the asserted identity at ringing).
            guard c.number.isEmpty else { return }
            c.uri = ""
            c.displayName = unknownCallerName
            return
        }
        c.number = r.number
        c.uri = r.uri
        if !r.name.isEmpty { c.displayName = r.name }
    }

    static let unknownCallerName = "Unknown caller"
}

private extension AccountSettings.Transport {
    var sipValue: Int {
        switch self {
        case .udp: return SIP_TRANSPORT_UDP
        case .tcp: return SIP_TRANSPORT_TCP
        case .tls: return SIP_TRANSPORT_TLS
        }
    }
}

private extension AccountSettings.SRTP {
    var sipValue: Int {
        switch self {
        case .off: return SIP_SRTP_OFF
        case .optional: return SIP_SRTP_OPTIONAL
        case .required: return SIP_SRTP_REQUIRED
        }
    }
}

#if DEBUG
extension SIPEngine {
    /// Fills the engine with sample calls, for rendering the call screen without a SIP server.
    func loadPreviewCalls(waiting: Bool) {
        settings.displayName = "Casa"
        calls = [
            ActiveCall(id: 0, number: "5550100", uri: "sip:5550100@sip.example.com", phase: .active, incoming: false,
                       connectedAt: Date().addingTimeInterval(-8656), muted: true, statusText: "Connected",
                       quality: 3, codec: "PCMA/8000"),
            ActiveCall(id: 1, number: "0612345678", displayName: "Mario Rossi", uri: "sip:0612345678@sip.example.com",
                       phase: .active, incoming: false, connectedAt: Date().addingTimeInterval(-60),
                       onHold: true, statusText: "Connected"),
        ]
        if waiting {
            calls.append(ActiveCall(id: 2, number: "3471234567", uri: "sip:3471234567@sip.example.com",
                                    phase: .incoming, incoming: true, statusText: "Incoming call"))
        }
        mediaStats[0] = MediaStats(lossPct: 0.4, jitterMs: 12, rttMs: 48)
        currentCallID = 0
    }
}
#endif
