import Foundation
import Security

/// SIP account configuration. Everything except the password (the SIP key)
/// lives in UserDefaults; the password is kept in the macOS Keychain.
/// Both are per macOS user, so each person on the Mac has their own account.
struct AccountSettings: Codable, Equatable {
    enum Transport: String, Codable, CaseIterable {
        case udp, tcp, tls
        var label: String { rawValue.uppercased() }
    }

    /// How much the app writes to its log besides the SIP messages (always complete).
    enum LogDetail: String, Codable, CaseIterable {
        case off, standard, detailed
        var label: String { rawValue.capitalized }
    }

    enum SRTP: String, Codable, CaseIterable {
        case off, optional, required
        var label: String { rawValue.capitalized }
    }

    // Placeholders show an example value; hints say what to enter.
    static let usernamePlaceholder = "+15551234567"
    static let passwordPlaceholder = "••••••••"
    static let domainPlaceholder = "sip.example.com"
    static let proxyPlaceholder = "192.0.2.10"

    // Required
    /// SIP username, usually the phone number in international format.
    var username = ""
    var domain = ""
    /// Outbound proxies in priority order: IP or host name, optionally with ":port".
    /// If one does not work, the next is tried.
    var proxyAddresses = [""]
    var transport = Transport.udp

    // Optional
    var displayName = ""
    /// Digest (authentication) username; leave empty to use the username.
    var authUserOverride = ""
    /// 0 = automatic (a random free port). A fixed 5060 can clash with the router's
    /// own phone service and its SIP "helper", which breaks calls.
    var localPort = 0
    var registrationExpiry = 3600
    /// Off by default: the app opens offline until the user registers.
    var connectOnLaunch = false
    var verifyTLSCertificate = false
    /// Off: nothing on disk; Standard: VPN traffic summary once a minute during calls;
    /// Detailed: every 5 s.
    var logDetail = LogDetail.standard
    /// Standard DTMF tones as feedback when pressing keypad keys (dialling and in calls).
    var keypadTones = true
    /// Icon in the menu bar; closing the window then keeps the app running there
    /// (without a Dock icon) instead of quitting it.
    var showInMenuBar = true
    /// Incoming calls show a small panel under the menu bar icon (answer, then a mini
    /// call control) instead of opening the window. Needs the menu bar icon.
    var incomingCallPanel = true
    /// Off: the app starts in the menu bar only (the window when asked for). The window
    /// opens anyway when the account is not set up or there is no menu bar icon.
    var openWindowAtStartup = true
    var usesCallPanel: Bool { showInMenuBar && incomingCallPanel }
    /// Names from the Mac's Contacts for numbers called or calling.
    var namesFromContacts = true
    /// A macOS notification for each missed call.
    var missedCallNotifications = true
    /// G.729: low bandwidth (8 kbit/s), for poor connections.
    var g729 = G729Use.last
    /// Answering machine, while Do Not Disturb is on: answers after amDelay seconds,
    /// plays the greeting and records a message of up to amMaxSeconds.
    var answeringMachine = true
    var amDelay = 25
    var amMaxSeconds = 120
    var amNoGreeting = false                // only the beep
    var amSpokenGreeting = true             // false: the user's own recording
    var amGreetingText = ""                 // "" = the default greeting of the greeting's language
    var amGreetingLanguage = ""             // "en", "it", …; "" = the Mac's language
    var amVoice = ""                        // macOS voice; "" = the most natural one in the greeting's language

    enum G729Use: String, Codable, CaseIterable {
        case last       // offered after G.711 and G.722: used only if the other side needs it
        case preferred  // offered first: saves bandwidth, slightly lower quality
        case off
    }

    /// Seconds between VPN traffic summaries during calls and outside calls.
    var vpnLogIntervals: (inCall: Int, idle: Int) {
        switch logDetail {
        case .off: return (0, 0)          // no summaries
        case .standard: return (60, 600)
        case .detailed: return (5, 60)
        }
    }
    var srtp = SRTP.off

    init() {}

    var sipUser: String {
        username.filter { !$0.isWhitespace }
    }

    var sipDomain: String {
        domain.trimmingCharacters(in: .whitespaces)
    }

    var authUser: String {
        let o = authUserOverride.trimmingCharacters(in: .whitespaces)
        return o.isEmpty ? sipUser : o
    }

    /// The configured proxies without blank rows.
    var proxies: [String] {
        proxyAddresses.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The outbound proxy URI built from an address and the transport,
    /// e.g. "sip:192.0.2.10;transport=tls".
    func proxyURI(_ address: String) -> String {
        "sip:\(address);transport=\(transport.rawValue)"
    }

    var proxyURIs: [String] { proxies.map(proxyURI) }

    /// Splits a pasted or previously saved URI such as "<sip:192.0.2.10:5061;transport=tls;lr>"
    /// into its address and transport. Returns nil for text that is not a URI.
    static func parseProxyURI(_ text: String) -> (address: String, transport: Transport?)? {
        var t = text.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "<>")))
        let lower = t.lowercased()
        guard lower.hasPrefix("sip:") || lower.hasPrefix("sips:") || t.contains(";") else { return nil }
        let transport: Transport?
        if lower.hasPrefix("sips:") {
            transport = .tls
        } else if let r = lower.range(of: "transport=") {
            transport = Transport(rawValue: String(lower[r.upperBound...].prefix { $0.isLetter }))
        } else {
            transport = nil
        }
        if let colon = t.firstIndex(of: ":"), ["sip", "sips"].contains(t[..<colon].lowercased()) {
            t = String(t[t.index(after: colon)...])
        }
        let address = String(t.prefix { $0 != ";" })
        return (address, transport)
    }

    // MARK: Validation (shown as hints under each field)

    var usernameProblem: String? {
        let u = sipUser
        if u.isEmpty { return "Enter your SIP username, usually your phone number." }
        if u.contains("@") || u.lowercased().hasPrefix("sip:") { return "Enter the username only, without sip: or @domain." }
        return nil
    }

    var domainProblem: String? {
        let d = sipDomain
        if d.isEmpty { return "Enter your provider's SIP domain." }
        if d.contains(" ") || d.contains("@") || d.lowercased().hasPrefix("sip:") {
            return "Enter the domain name only, without sip: or @."
        }
        return nil
    }

    /// Problem with one proxy row; blank rows are fine as long as one proxy is set.
    func proxyProblem(at index: Int) -> String? {
        let a = proxyAddresses[index].trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return proxies.isEmpty ? "Enter your outbound SIP proxy IP address." : nil }
        let pattern = #"^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)(:[0-9]{1,5})?$"#
        let port = a.range(of: #":[0-9]+$"#, options: .regularExpression).flatMap { Int(a[$0].dropFirst()) }
        if a.range(of: pattern, options: .regularExpression) == nil || (port.map { !(1...65535).contains($0) } ?? false) {
            return "Enter an IP address or host name, optionally followed by :port."
        }
        return nil
    }

    var proxiesValid: Bool {
        !proxies.isEmpty && proxyAddresses.indices.allSatisfy { proxyProblem(at: $0) == nil }
    }

    static func passwordProblem(_ password: String) -> String? {
        password.isEmpty ? "Enter your SIP password." : nil
    }

    var isComplete: Bool {
        usernameProblem == nil && domainProblem == nil && proxiesValid
    }

    private enum CodingKeys: String, CodingKey {
        case username, domain, proxyAddresses, transport, displayName, authUserOverride
        case localPort, registrationExpiry, connectOnLaunch, verifyTLSCertificate, srtp, settingsVersion, logDetail, keypadTones, showInMenuBar
        case namesFromContacts, missedCallNotifications, g729, incomingCallPanel, openWindowAtStartup
        case answeringMachine, amDelay, amMaxSeconds, amSpokenGreeting, amGreetingText, amVoice, amNoGreeting, amGreetingLanguage
        case proxyAddress, outboundProxy  // read only, from earlier versions
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(username, forKey: .username)
        try c.encode(domain, forKey: .domain)
        try c.encode(proxies, forKey: .proxyAddresses)
        try c.encode(transport, forKey: .transport)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(authUserOverride, forKey: .authUserOverride)
        try c.encode(localPort, forKey: .localPort)
        try c.encode(Self.currentVersion, forKey: .settingsVersion)
        try c.encode(registrationExpiry, forKey: .registrationExpiry)
        try c.encode(connectOnLaunch, forKey: .connectOnLaunch)
        try c.encode(verifyTLSCertificate, forKey: .verifyTLSCertificate)
        try c.encode(srtp, forKey: .srtp)
        try c.encode(logDetail, forKey: .logDetail)
        try c.encode(keypadTones, forKey: .keypadTones)
        try c.encode(showInMenuBar, forKey: .showInMenuBar)
        try c.encode(namesFromContacts, forKey: .namesFromContacts)
        try c.encode(missedCallNotifications, forKey: .missedCallNotifications)
        try c.encode(g729, forKey: .g729)
        try c.encode(incomingCallPanel, forKey: .incomingCallPanel)
        try c.encode(openWindowAtStartup, forKey: .openWindowAtStartup)
        try c.encode(answeringMachine, forKey: .answeringMachine)
        try c.encode(amDelay, forKey: .amDelay)
        try c.encode(amMaxSeconds, forKey: .amMaxSeconds)
        try c.encode(amSpokenGreeting, forKey: .amSpokenGreeting)
        try c.encode(amGreetingText, forKey: .amGreetingText)
        try c.encode(amVoice, forKey: .amVoice)
        try c.encode(amNoGreeting, forKey: .amNoGreeting)
        try c.encode(amGreetingLanguage, forKey: .amGreetingLanguage)
    }

    private static let currentVersion = 5

    // Decode field by field so settings saved by older versions keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AccountSettings()
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? d.username
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? d.domain
        transport = try c.decodeIfPresent(Transport.self, forKey: .transport) ?? d.transport
        proxyAddresses = try c.decodeIfPresent([String].self, forKey: .proxyAddresses) ?? d.proxyAddresses
        if proxyAddresses.isEmpty { proxyAddresses = [""] }
        if !c.contains(.proxyAddresses), let single = try c.decodeIfPresent(String.self, forKey: .proxyAddress) {
            proxyAddresses = [single]
        }
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? d.displayName
        authUserOverride = try c.decodeIfPresent(String.self, forKey: .authUserOverride) ?? d.authUserOverride
        localPort = try c.decodeIfPresent(Int.self, forKey: .localPort) ?? d.localPort
        // Version 1 used 5060 as the default local port; move it to automatic.
        if (try c.decodeIfPresent(Int.self, forKey: .settingsVersion) ?? 1) < 2 && localPort == 5060 {
            localPort = 0
        }
        registrationExpiry = try c.decodeIfPresent(Int.self, forKey: .registrationExpiry) ?? d.registrationExpiry
        connectOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .connectOnLaunch) ?? d.connectOnLaunch
        // Before version 3, registering at startup was the default; it is now off.
        if (try c.decodeIfPresent(Int.self, forKey: .settingsVersion) ?? 1) < 3 {
            connectOnLaunch = false
        }
        verifyTLSCertificate = try c.decodeIfPresent(Bool.self, forKey: .verifyTLSCertificate) ?? d.verifyTLSCertificate
        srtp = try c.decodeIfPresent(SRTP.self, forKey: .srtp) ?? d.srtp
        keypadTones = try c.decodeIfPresent(Bool.self, forKey: .keypadTones) ?? d.keypadTones
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? d.showInMenuBar
        namesFromContacts = try c.decodeIfPresent(Bool.self, forKey: .namesFromContacts) ?? d.namesFromContacts
        missedCallNotifications = try c.decodeIfPresent(Bool.self, forKey: .missedCallNotifications)
            ?? d.missedCallNotifications
        if let raw = try? c.decodeIfPresent(String.self, forKey: .g729) { g729 = G729Use(rawValue: raw) ?? .last }
        incomingCallPanel = try c.decodeIfPresent(Bool.self, forKey: .incomingCallPanel) ?? d.incomingCallPanel
        openWindowAtStartup = try c.decodeIfPresent(Bool.self, forKey: .openWindowAtStartup) ?? d.openWindowAtStartup
        answeringMachine = try c.decodeIfPresent(Bool.self, forKey: .answeringMachine) ?? d.answeringMachine
        amDelay = try c.decodeIfPresent(Int.self, forKey: .amDelay) ?? d.amDelay
        amMaxSeconds = try c.decodeIfPresent(Int.self, forKey: .amMaxSeconds) ?? d.amMaxSeconds
        amSpokenGreeting = try c.decodeIfPresent(Bool.self, forKey: .amSpokenGreeting) ?? d.amSpokenGreeting
        amGreetingText = try c.decodeIfPresent(String.self, forKey: .amGreetingText) ?? d.amGreetingText
        amVoice = try c.decodeIfPresent(String.self, forKey: .amVoice) ?? d.amVoice
        amNoGreeting = try c.decodeIfPresent(Bool.self, forKey: .amNoGreeting) ?? d.amNoGreeting
        amGreetingLanguage = try c.decodeIfPresent(String.self, forKey: .amGreetingLanguage) ?? d.amGreetingLanguage
        // Read as text: a value this version does not know (e.g. "custom", from 1.1)
        // falls back to Standard instead of losing all the settings.
        if let raw = try? c.decodeIfPresent(String.self, forKey: .logDetail) {
            logDetail = LogDetail(rawValue: raw) ?? .standard
        }
        // Earlier versions stored the full proxy URI ("sip:IP;transport=udp").
        if !c.contains(.proxyAddresses) && !c.contains(.proxyAddress),
           let uri = try c.decodeIfPresent(String.self, forKey: .outboundProxy),
           let parsed = Self.parseProxyURI(uri) {
            proxyAddresses = [parsed.address]
            if !c.contains(.transport) { transport = parsed.transport ?? .udp }
        }
    }

    // MARK: Persistence

    private static let defaultsKey = "account"

    static func load() -> AccountSettings {
        if Bench.isActive { return Bench.accountSettings }
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(AccountSettings.self, from: data) else {
            return AccountSettings()
        }
        return s
    }

    func save() {
        guard !Bench.isActive else { return }
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Name of this build ("SIP Anywhere", or "SIP Anywhere Dev" for development
/// builds), used to keep the Keychain item and the log of each build separate.
enum AppIdentity {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "SIP Anywhere"
    static let isDevelopment = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
}

enum Keychain {
    private static let service = Bench.isActive ? "SIPAnywhere.bench.sip"
        : AppIdentity.isDevelopment ? "SIPAnywhere.dev.sip" : "SIPAnywhere.sip"

    static func password(for account: String) -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func setPassword(_ password: String, for account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        guard !password.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
