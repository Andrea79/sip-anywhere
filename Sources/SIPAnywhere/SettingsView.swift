import AVFoundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Account configuration mask. Anyone using the app enters their own SIP
/// account here; it is stored per macOS user.
///
/// Every field follows the same pattern: a title, a grey placeholder showing an
/// example value, and an orange hint underneath while the value is missing or invalid.
struct SettingsView: View {
    @Environment(SIPEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var draft = AccountSettings()
    @State private var password = ""
    @State private var revealPassword = false
    @State private var showAdvanced = false
    @State private var loaded = false
    /// Proxy rows with stable identities, so rows can be removed and reordered safely.
    @State private var proxyRows: [ProxyRow] = []
    // In-app VPN
    @State private var vpn = VPNSettings()
    @State private var vpnProfile = ""
    @State private var vpnInfo = VPNProfileInfo()
    @State private var vpnPassword = ""
    @State private var revealVPNPassword = false
    @State private var importingProfile = false
    @State private var importError: String?
    @State private var confirmDeleteLogs = false

    private struct ProxyRow: Identifiable, Equatable {
        let id = UUID()
        var address: String
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                // Identity: who you are on the network (sip:username@domain).
                Section {
                    Field("Username", hint: draft.usernameProblem) {
                        TextField("Username", text: $draft.username,
                                  prompt: Text(AccountSettings.usernamePlaceholder))
                    }
                    Field("SIP domain", hint: draft.domainProblem,
                          note: draft.usernameProblem == nil ? "SIP address: sip:\(draft.sipUser)@\(draft.sipDomain)" : nil) {
                        TextField("SIP domain", text: $draft.domain,
                                  prompt: Text(AccountSettings.domainPlaceholder))
                    }
                    Field("Display name", hint: nil,
                          note: "Optional. Shown next to your number in SIP messages.") {
                        TextField("Display name", text: $draft.displayName, prompt: Text("Mario Rossi"))
                    }
                } header: {
                    Text("Identity")
                }

                // Login: the credentials used to authenticate.
                Section {
                    Field("Auth username", hint: nil,
                          note: "Optional. Only if your provider gives a login name different from the username.") {
                        TextField("Auth username", text: $draft.authUserOverride,
                                  prompt: Text("Same as username"))
                    }
                    Field("Password", hint: AccountSettings.passwordProblem(password)) {
                        HStack {
                            if revealPassword {
                                TextField("Password", text: $password,
                                          prompt: Text(AccountSettings.passwordPlaceholder))
                            } else {
                                SecureField("Password", text: $password,
                                            prompt: Text(AccountSettings.passwordPlaceholder))
                            }
                            Button { revealPassword.toggle() } label: {
                                Image(systemName: revealPassword ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(revealPassword ? "Hide password" : "Show password")
                        }
                    }
                } header: {
                    Text("Login")
                }

                // Server: where the app connects.
                Section {
                    Field("Outbound SIP proxies", hint: draft.proxies.isEmpty
                          ? "Enter your outbound SIP proxy IP address." : nil) {
                        proxyList
                    }
                    Row("Transport", note: draft.proxyURIs.isEmpty ? nil
                        : (draft.proxyURIs.count == 1 ? "Proxy URI: " : "Proxy URIs:\n")
                          + draft.proxyURIs.joined(separator: "\n")) {
                        Picker("Transport", selection: $draft.transport) {
                            ForEach(AccountSettings.Transport.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                } header: {
                    Text("Server")
                } footer: {
                    FooterText("Enter each proxy's IP address, optionally with :port, in order of preference. "
                         + "If registration through a proxy fails or gets no answer within "
                         + "\(Int(SIPEngine.registrationTimeout)) seconds, the next one is tried; you can also "
                         + "switch from the status bar. No DNS lookup is done. "
                         + "Default ports: 5060 for UDP/TCP, 5061 for TLS.")
                }

                vpnSection

                Section {
                    DisclosureGroup("Advanced (optional)", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 12) {
                            Row("Media encryption (SRTP)") {
                                Picker("Media encryption (SRTP)", selection: $draft.srtp) {
                                    ForEach(AccountSettings.SRTP.allCases, id: \.self) { Text($0.label).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .fixedSize()
                            }
                            Field("Local SIP port", hint: nil,
                                  note: "0 = automatic (recommended; 5060 can clash with your router's own phone service)") {
                                TextField("Local SIP port", value: $draft.localPort,
                                          format: .number.grouping(.never), prompt: Text("0"))
                            }
                            Field("Registration expiry (seconds)", hint: nil) {
                                TextField("Registration expiry", value: $draft.registrationExpiry,
                                          format: .number.grouping(.never), prompt: Text("3600"))
                            }
                            Toggle("Verify TLS server certificate", isOn: $draft.verifyTLSCertificate)
                                .disabled(draft.transport != .tls)
                            Row("Log detail", note: logDetailNote) {
                                Picker("Log detail", selection: $draft.logDetail) {
                                    ForEach(AccountSettings.LogDetail.allCases, id: \.self) { Text($0.label).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .fixedSize()
                            }
                            Row("Log files") {
                                Button("Delete…") { confirmDeleteLogs = true }
                                .confirmationDialog("Delete the log files?", isPresented: $confirmDeleteLogs) {
                                    Button("Delete", role: .destructive) { engine.deleteLogFiles() }
                                } message: {
                                    Text("The SIP log on disk (with phone numbers and SIP messages) and the Log tab "
                                         + "are emptied. This cannot be undone.")
                                }
                            }

                        }
                        .padding(.top, 8)
                    }
                } footer: {
                    if showAdvanced {
                        FooterText("Certificate verification only works when the proxy URI uses a host name "
                             + "that matches the server certificate, not a bare IP.")
                    }
                }

                // One style throughout: text fields have their title above (they need the
                // width); menus, numbers, buttons and switches are one row, title on the left.
                Section {
                    Row("Microphone") { AudioDevicePicker(engine: engine, input: true) }
                    Row("Speaker") { AudioDevicePicker(engine: engine, input: false) }
                    Toggle("Keypad tones", isOn: $draft.keypadTones)
                } header: {
                    Text("Audio")
                } footer: {
                    FooterText("Devices change immediately, also during a call (also in the Audio menu). "
                               + "Keypad tones: the standard telephone tones when you press a key, "
                               + "while dialling and during calls; only you hear them.")
                }

                Section {
                    Toggle("Names from Contacts", isOn: $draft.namesFromContacts)
                    Toggle("Notify missed calls", isOn: $draft.missedCallNotifications)
                    Row("G.729 (low bandwidth)", note: "Preferred applies from the next registration") {
                        Picker("G.729 (low bandwidth)", selection: $draft.g729) {
                            Text("Only if needed").tag(AccountSettings.G729Use.last)
                            Text("Preferred").tag(AccountSettings.G729Use.preferred)
                            Text("Off").tag(AccountSettings.G729Use.off)
                        }
                    }
                    Row("Recordings") { Button("Show in Finder") { engine.showRecordings() } }
                } header: {
                    Text("Calls")
                } footer: {
                    FooterText("Names from Contacts: the Mac's address book is read on this Mac only, to show names "
                               + "for numbers. G.729 needs about a third of the bandwidth of the usual codecs, "
                               + "useful on a weak mobile connection. Recordings are WAV files in "
                               + "Music › \(AppIdentity.name) › Recordings.")
                }

                Section {
                    Toggle("Answering machine", isOn: $draft.answeringMachine)
                    Group {
                        Row("Answers after") {
                            HStack(spacing: 6) {
                                Text("\(draft.amDelay) s").monospacedDigit()
                                Stepper("Answers after", value: $draft.amDelay, in: 5...90, step: 5)
                            }
                        }
                        Row("Longest message") {
                            Picker("Longest message", selection: $draft.amMaxSeconds) {
                                Text("30 s").tag(30)
                                Text("1 min").tag(60)
                                Text("2 min").tag(120)
                                Text("3 min").tag(180)
                                Text("5 min").tag(300)
                            }
                        }
                        Toggle("No greeting (beep only)", isOn: $draft.amNoGreeting)
                        Group {
                            Row("Greeting") {
                                Picker("Greeting", selection: $draft.amSpokenGreeting) {
                                    Text("Spoken from a text").tag(true)
                                    Text("My own recording").tag(false)
                                }
                            }
                            if draft.amSpokenGreeting {
                                Row("Greeting language") {
                                    Picker("Greeting language", selection: $draft.amGreetingLanguage) {
                                        Text("Automatic (\(AnsweringMachine.languageName(AnsweringMachine.systemGreetingLanguage)))")
                                            .tag("")
                                        ForEach(AnsweringMachine.greetingLanguages, id: \.code) { Text($0.name).tag($0.code) }
                                    }
                                    // A new language brings its own most natural voice, and its own
                                    // default greeting unless the text was written by the user.
                                    .onChange(of: draft.amGreetingLanguage) { _ in
                                        draft.amVoice = ""
                                        if AnsweringMachine.isDefaultGreeting(draft.amGreetingText) { draft.amGreetingText = "" }
                                    }
                                }
                                // Empty: the default greeting of the language, shown in grey.
                                Field("Greeting text", hint: nil, note: "Leave empty for the default greeting") {
                                    TextField("Greeting text", text: $draft.amGreetingText,
                                              prompt: Text(AnsweringMachine.defaultGreetingText(language: greetingLanguage)),
                                              axis: .vertical)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(2...4)
                                }
                                Row("Voice") {
                                    Picker("Voice", selection: $draft.amVoice) {
                                        Text("Default (\(AnsweringMachine.defaultVoice(language: greetingLanguage)))").tag("")
                                        ForEach(AnsweringMachine.voices(language: greetingLanguage), id: \.self) {
                                            Text($0).tag($0)
                                        }
                                    }
                                    // Rebuilt for each language, so the menu shows the new default.
                                    .id(greetingLanguage)
                                }
                            } else {
                                Row("My greeting", note: "Recorded with the microphone; the beep is added") {
                                    GreetingRecordButton(recorder: engine.greetingRecorder)
                                }
                            }
                        }
                        .disabled(draft.amNoGreeting)
                        Row("Greeting and messages") {
                            HStack {
                                Button("Play Greeting") { playGreeting() }
                                Button("Show Messages") { engine.showVoicemail() }
                            }
                        }
                    }
                    .disabled(!draft.answeringMachine)
                } header: {
                    Text("Answering machine")
                } footer: {
                    FooterText("Works while Do Not Disturb is on: the Mac does not ring, the line's other phones "
                               + "do; if nobody answers in time, the machine plays the greeting, a beep, and "
                               + "records the message. Messages are in the Messages tab and in "
                               + "Music › \(AppIdentity.name) › Voicemail.")
                }

                Section {
                    Toggle("Register at startup", isOn: $draft.connectOnLaunch)
                    Toggle("Show in the menu bar", isOn: $draft.showInMenuBar)
                    LoginItemToggle()
                    Toggle("Open the window at startup", isOn: $draft.openWindowAtStartup)
                        .disabled(!draft.showInMenuBar)
                    Row("Incoming calls", note: "The panel needs the menu bar icon") {
                        Picker("Incoming calls", selection: $draft.incomingCallPanel) {
                            Text("Panel under the menu bar icon").tag(true)
                            Text("Main window").tag(false)
                        }
                    }
                    .disabled(!draft.showInMenuBar)
                } header: {
                    Text("Startup")
                } footer: {
                    FooterText("Open at login applies at once (macOS may ask to allow it in System Settings › "
                         + "General › Login Items). "
                         + (draft.connectOnLaunch
                         ? "The app registers with the provider as soon as it opens."
                         : "The app opens offline. Press Register in the status bar (⌘R) when you want to connect.")
                         + (draft.showInMenuBar
                            ? " Closing the window keeps the app in the menu bar, ready for calls (no Dock icon). "
                              + "Quit from the menu bar icon or with ⌘Q."
                            : " Closing the window quits the app."))
                }

                Section("Summary") {
                    LabeledContent("SIP identity", value: draft.sipUser.isEmpty || draft.sipDomain.isEmpty
                                    ? "—" : "sip:\(draft.sipUser)@\(draft.sipDomain)")
                    LabeledContent("Auth username", value: draft.authUser.isEmpty ? "—" : draft.authUser)
                    LabeledContent(draft.proxyURIs.count > 1 ? "Outbound proxies" : "Outbound proxy",
                                   value: draft.proxyURIs.isEmpty ? "—" : draft.proxyURIs.joined(separator: "\n"))
                    LabeledContent("Security", value: securitySummary)
                    LabeledContent("VPN", value: vpn.enabled
                                   ? (vpnInfo.server.isEmpty ? "On" : "Through \(vpnInfo.server)") : "Off")
                }
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            .formStyle(.grouped)

            HStack {
                Button("Reset to defaults") {
                    draft = AccountSettings()
                    proxyRows = draft.proxyAddresses.map { ProxyRow(address: $0) }
                    password = ""
                    vpn = VPNSettings()
                    vpnProfile = ""
                    vpnInfo = VPNProfileInfo()
                    vpnPassword = ""
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(register: false) }
                    .help(engine.isOnline
                          ? "Save without registering again; changes apply at the next registration"
                          : "Save without registering")
                    .disabled(!canSave)
                Button("Save & Register") { save(register: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 460, height: 640)
        .fileImporter(isPresented: $importingProfile, allowedContentTypes: Self.profileTypes) { result in
            importProfile(result)
        }
        .onAppear {
            guard !loaded else { return }
            draft = engine.settings
            proxyRows = draft.proxyAddresses.map { ProxyRow(address: $0) }
            password = engine.password
            vpn = engine.vpnSettings
            vpnProfile = engine.vpnProfile
            vpnInfo = VPNProfileInfo(profile: vpnProfile)
            vpnPassword = engine.vpnPassword
            loaded = true
        }
        .onChange(of: proxyRows) {
            // A full URI pasted into a proxy row is split into address and transport.
            for i in proxyRows.indices {
                if let parsed = AccountSettings.parseProxyURI(proxyRows[i].address) {
                    proxyRows[i].address = parsed.address
                    if let t = parsed.transport { draft.transport = t }
                }
            }
            draft.proxyAddresses = proxyRows.map(\.address)
        }
    }

    /// Editable, ordered list of outbound proxies: the first is the primary,
    /// the others are tried in order if it fails.
    private var proxyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(proxyRows.enumerated()), id: \.element.id) { i, row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(i + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        TextField("Proxy \(i + 1)", text: binding(for: row.id),
                                  prompt: Text(i == 0 ? AccountSettings.proxyPlaceholder : "192.0.2.11"))
                        Button { move(row.id, by: -1) } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(.borderless)
                            .disabled(i == 0)
                            .help("Try this proxy earlier")
                        Button { proxyRows.removeAll { $0.id == row.id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(proxyRows.count == 1)
                        .help("Remove this proxy")
                    }
                    if i < draft.proxyAddresses.count, !row.address.trimmingCharacters(in: .whitespaces).isEmpty,
                       let problem = draft.proxyProblem(at: i) {
                        Text(problem).font(.caption).foregroundStyle(.orange).padding(.leading, 26)
                    }
                }
            }
            Button {
                proxyRows.append(ProxyRow(address: ""))
            } label: {
                Label("Add proxy", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .padding(.leading, 26)
        }
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { proxyRows.first { $0.id == id }?.address ?? "" },
            set: { value in
                if let i = proxyRows.firstIndex(where: { $0.id == id }) { proxyRows[i].address = value }
            }
        )
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let i = proxyRows.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard proxyRows.indices.contains(j) else { return }
        proxyRows.swapAt(i, j)
    }

    private var vpnProblem: String? {
        SIPEngine.vpnProblem(vpn, profile: vpnProfile, info: vpnInfo, password: vpnPassword,
                             transport: draft.transport)
    }

    private var canSave: Bool {
        draft.isComplete && AccountSettings.passwordProblem(password) == nil && vpnProblem == nil
    }

    // MARK: VPN

    private static let profileTypes: [UTType] = [UTType(filenameExtension: "ovpn"), UTType(filenameExtension: "conf"),
                                                 .plainText].compactMap { $0 }

    @State private var greetingPlayer: AVAudioPlayer?
    /// Bumped by every Play Greeting: only the latest request is played.
    @State private var greetingRequest = 0
    /// Greetings are built one at a time (they write the same files).
    private static let greetingQueue = DispatchQueue(label: "greeting", qos: .userInitiated)

    /// The language of the greeting on screen ("Automatic" resolved).
    private var greetingLanguage: String { AnsweringMachine.greetingLanguage(draft.amGreetingLanguage) }

    /// Builds the greeting from what is on screen (not saved yet) and plays it. A new
    /// request stops the greeting playing and replaces any request still being built.
    private func playGreeting() {
        greetingPlayer?.stop()
        greetingPlayer = nil
        greetingRequest += 1
        let request = greetingRequest, settings = draft
        Self.greetingQueue.async {
            AnsweringMachine.prepareGreeting(from: settings)
            let data = try? Data(contentsOf: AnsweringMachine.greetingURL)
            DispatchQueue.main.async {
                guard request == greetingRequest, let data else { return }
                greetingPlayer = try? AVAudioPlayer(data: data)
                greetingPlayer?.play()
            }
        }
    }

    private var vpnSection: some View {
        Section {
            Toggle("Call through the VPN", isOn: $vpn.enabled)
            Field("OpenVPN profile", hint: vpn.enabled ? profileHint : importError, note: profileNote) {
                HStack {
                    Text(vpnProfile.isEmpty ? "No profile imported" : vpn.profileName)
                        .foregroundStyle(vpnProfile.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(vpnProfile.isEmpty ? "Import…" : "Replace…") { importingProfile = true }
                    if !vpnProfile.isEmpty {
                        Button {
                            vpnProfile = ""
                            vpnInfo = VPNProfileInfo()
                            vpn.profileName = ""
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove the profile")
                    }
                }
            }
            if vpnInfo.needsCredentials {
                Field("VPN username", hint: vpn.enabled && vpn.trimmedUsername.isEmpty
                      ? "Enter the username of your VPN account." : nil) {
                    TextField("VPN username", text: $vpn.username, prompt: Text("mario"))
                }
                Field("VPN password", hint: vpn.enabled && vpnPassword.isEmpty
                      ? "Enter the password of your VPN account." : nil) {
                    HStack {
                        if revealVPNPassword {
                            TextField("VPN password", text: $vpnPassword,
                                      prompt: Text(AccountSettings.passwordPlaceholder))
                        } else {
                            SecureField("VPN password", text: $vpnPassword,
                                        prompt: Text(AccountSettings.passwordPlaceholder))
                        }
                        Button { revealVPNPassword.toggle() } label: {
                            Image(systemName: revealVPNPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealVPNPassword ? "Hide password" : "Show password")
                    }
                }
            }
        } header: {
            Text("VPN")
        } footer: {
            FooterText("Use the VPN to call from anywhere as if the Mac were on your line's own network, at home "
                 + "or at the office, e.g. when your provider only accepts calls from your own line. Only this "
                 + "app's calls go through the VPN; the rest of "
                 + "the Mac keeps using the normal connection. Works with OpenVPN servers (e.g. "
                 + "OpenVPN Access Server, pfSense, many routers): import the .ovpn profile your server provides. "
                 + "The server must let VPN clients reach the Internet.")
        }
    }

    private var profileHint: String? {
        if let importError { return importError }
        if vpnProfile.isEmpty { return "Import the OpenVPN profile (.ovpn file) of your VPN server." }
        if !vpnInfo.valid { return "The profile cannot be used: \(vpnInfo.error)" }
        if draft.transport != .udp { return "Through the VPN, SIP works over UDP only: choose UDP as transport." }
        return nil
    }

    private var profileNote: String? {
        guard !vpnProfile.isEmpty, vpnInfo.valid else { return nil }
        return "Server: \(vpnInfo.server.isEmpty ? "—" : vpnInfo.server)"
            + (vpnInfo.needsCredentials ? " · username and password" : " · certificate login")
    }

    private func importProfile(_ result: Result<URL, Error>) {
        importError = nil
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count < 512 * 1024,
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                importError = "Cannot read \(url.lastPathComponent)."
                return
            }
            let info = VPNProfileInfo(profile: text)
            vpnProfile = text
            vpnInfo = info
            vpn.profileName = url.lastPathComponent
            if info.valid { vpn.enabled = true }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func save(register: Bool) {
        draft.username = draft.sipUser
        draft.domain = draft.sipDomain
        draft.proxyAddresses = draft.proxies
        draft.save()
        engine.password = password
        engine.settings = draft
        engine.prepareGreeting()
        vpn.username = vpn.trimmedUsername
        vpn.save()
        if engine.vpnProfile != vpnProfile { engine.vpnProfile = vpnProfile }
        if engine.vpnPassword != vpnPassword { engine.vpnPassword = vpnPassword }
        engine.vpnSettings = vpn
        // VPN turned off after a failed attempt: no red VPN badge left behind.
        if !vpn.enabled, case .failed = engine.vpnState { engine.vpnState = .off }
        if register { engine.connect() }
        dismiss()
    }

    private var logDetailNote: String {
        if draft.logDetail == .off {
            return "Nothing is written to disk and SIP messages are not logged. The Log tab shows "
                + "only problems, until the app quits. Applies from the next registration."
        }
        let every = draft.vpnLogIntervals
        return "SIP messages are always logged in full. VPN traffic: every \(every.inCall) s during calls, "
            + "every \(every.idle / 60) min otherwise; problems are logged at once."
    }

    private var securitySummary: String {
        let signalling = draft.transport == .tls
            ? (draft.verifyTLSCertificate ? "TLS (verified)" : "TLS")
            : "Unencrypted signalling"
        let media = switch draft.srtp {
        case .off: "unencrypted audio"
        case .optional: "SRTP if offered"
        case .required: "SRTP required"
        }
        return "\(signalling), \(media)"
    }
}

/// A form row: title, control, and underneath either an orange hint (missing or
/// invalid value) or a grey note.
/// A one-row setting: title (and an optional note under it) on the left, the control on the right.
private struct Row<Content: View>: View {
    let title: String
    let note: String?
    @ViewBuilder let content: Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        LabeledContent {
            content.labelsHidden()
        } label: {
            Text(title)
            if let note { Text(note) }
        }
    }
}

private struct Field<Content: View>: View {
    let title: String
    let hint: String?
    let note: String?
    @ViewBuilder let content: Content

    init(_ title: String, hint: String?, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium))
            content.labelsHidden()
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            } else if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Section footer text, justified (SwiftUI's Text only aligns left, centre or right),
/// using AppKit's text field, which supports justified alignment.
private struct FooterText: NSViewRepresentable {
    let text: String

    init(_ text: String) { self.text = text }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.alignment = .justified
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.isSelectable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        field.preferredMaxLayoutWidth = width
        let height = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width,
                                                            height: .greatestFiniteMagnitude)).height ?? 0
        return CGSize(width: width, height: ceil(height))
    }
}

/// Records the user's own answering machine greeting (start / stop).
private struct GreetingRecordButton: View {
    var recorder: GreetingRecorder

    var body: some View {
        Button(recorder.isRecording ? "Stop Recording" : "Record") { recorder.toggle() }
            .help(recorder.isRecording ? "Stop: then Save to use it" : "Record your greeting with the microphone; the beep is added")
    }
}

/// Open at login (macOS Login Items), applied at once rather than on Save.
private struct LoginItemToggle: View {
    // Read when shown, not in the initial values: those run at every redraw of Settings.
    @State private var enabled = false
    @State private var needsApproval = false

    var body: some View {
        Toggle("Open at login", isOn: Binding(get: { enabled }, set: { set($0) }))
            .onAppear { refresh() }
        if needsApproval {
            Text("Allow it in System Settings › General › Login Items.")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    private func set(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        needsApproval = status == .requiresApproval
    }
}
