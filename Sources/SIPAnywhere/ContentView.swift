import SwiftUI

struct ContentView: View {
    @Environment(SIPEngine.self) private var engine
    @Environment(\.openWindow) private var openWindow
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            if let call = engine.call {
                // The call screen is always dark, including the status strip.
                VStack(spacing: 0) {
                    StatusBar()
                    CallView(call: call)
                }
                .background(Color(white: 0.04))
                .environment(\.colorScheme, .dark)
                .frame(minWidth: 520, minHeight: 680)
            } else {
                StatusBar()
                Divider()
                Picker("", selection: $tab) {
                    Text("Keypad").tag(0)
                    Text(engine.missedCalls > 0 ? "Recents (\(engine.missedCalls))" : "Recents").tag(1)
                    Text(engine.newVoiceMessages > 0 ? "Messages (\(engine.newVoiceMessages))" : "Messages").tag(2)
                    Text("Log").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)

                switch tab {
                case 0: DialerView()
                case 1: RecentsView(onSelect: { tab = 0 })
                case 2: MessagesView()
                default: LogView()
                }
            }
        }
        .alert(engine.registrationConflict?.title ?? "",
               isPresented: Binding(get: { engine.registrationConflict != nil },
                                    set: { if !$0 { engine.registrationConflict = nil } }),
               presenting: engine.registrationConflict) { conflict in
            if conflict.otherApp != nil {
                Button("Quit \(conflict.otherName) and Register") {
                    DispatchQueue.main.async { engine.quitOtherCopyAndConnect(conflict) }
                }
            }
            if conflict.canRegisterAnyway {
                Button("Register Anyway") { DispatchQueue.main.async { engine.registerAnyway() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { conflict in
            Text(conflict.message)
        }
        // Settings is a window of its own, so it can be opened from the menu bar too.
        // With the menu bar icon, the icon opens it (only once: opening it is not free).
        .onChange(of: engine.showSettings) { show in
            guard show, !engine.settings.showInMenuBar else { return }
            SettingsWindow.open(openWindow)
            engine.showSettings = false
        }
        .onAppear {
            if !engine.settings.isComplete { SettingsWindow.open(openWindow) }
            if let t = engine.requestedTab { tab = t; engine.requestedTab = nil }
        }
        .onChange(of: engine.requestedTab) { t in
            if let t { tab = t; engine.requestedTab = nil }
        }
        .onChange(of: tab) { t in
            if t == 1 { engine.clearMissedCalls() }
        }
    }
}

// MARK: - Registration status

private struct StatusBar: View {
    @Environment(SIPEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    HStack(spacing: 4) {
                        Text(subtitle).lineLimit(1)
                        if engine.settings.isComplete { proxyPicker }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if engine.doNotDisturb {
                    Button { engine.toggleDoNotDisturb() } label: {
                        Label("Do Not Disturb", systemImage: "moon.fill").font(.caption.bold())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.purple)
                    .help("This Mac does not ring; other phones on the line ring as usual. Calls are noted in Recents. "
                          + "Click to turn off (⇧⌘D).")
                }
                if engine.vpnSettings.enabled || engine.vpnState != .off { vpnBadge }
                if engine.isOnline {
                    Button { engine.reregister() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Register again now (⌘R)")
                        .buttonStyle(.borderless)
                    Button { engine.goOffline() } label: { Image(systemName: "power") }
                        .help("Go offline: unregister and stop all attempts (⇧⌘R)")
                        .buttonStyle(.borderless)
                        .disabled(!engine.calls.isEmpty)
                } else {
                    Button("Register") { engine.connect() }
                        .controlSize(.small)
                        .help("Register with the provider (⌘R)")
                        .disabled(!engine.settings.isComplete)
                }
                Button { engine.showSettings = true } label: { Image(systemName: "gearshape") }
                    .help("Account settings")
                    .buttonStyle(.borderless)
            }
            if let err = engine.lastError {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    private var color: Color {
        switch engine.registration {
        case .registered: return .green
        case .registering: return .orange
        case .failed: return .red
        case .offline: return .gray
        }
    }

    private var title: String {
        switch engine.registration {
        case .registered: return "Registered"
        case .registering:
            if case .connecting = engine.vpnState { return "Connecting VPN…" }
            return "Registering…"
        case .failed: return "Registration failed"
        case .offline: return "Offline"
        }
    }

    private var subtitle: String {
        switch engine.registration {
        case .failed(let code, let reason):
            let text = code > 0 ? "\(code) \(reason)" : reason
            return engine.settings.isComplete ? "\(text) via" : text
        default:
            return engine.settings.isComplete ? "\(engine.settings.sipUser) via" : "No account configured"
        }
    }

    /// VPN status: green when the tunnel is up, orange while connecting, red after a failure.
    private var vpnBadge: some View {
        let (color, help): (Color, String) = switch engine.vpnState {
        case .off: (.secondary, "VPN on, not connected (it connects when you register)")
        case .connecting(let step): (.orange, "VPN: \(step)…")
        case .connected(let ip): (.green, "Calls go through the VPN (address \(ip))")
        case .failed(let message): (.red, "VPN: \(message)")
        }
        return Button { engine.showSettings = true } label: {
            HStack(spacing: 2) {
                Image(systemName: "lock.shield.fill")
                Text("VPN").font(.caption.weight(.semibold))
            }
            .foregroundStyle(color)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// The outbound proxy in use; with several proxies, a menu to switch between them.
    @ViewBuilder private var proxyPicker: some View {
        let proxies = engine.settings.proxies
        let current = engine.activeProxy ?? "—"
        if proxies.count > 1 {
            Menu {
                ForEach(proxies.indices, id: \.self) { i in
                    Button {
                        engine.useProxy(i)
                    } label: {
                        if i == engine.activeProxyIndex {
                            Label("\(proxies[i])\(i == 0 ? " (primary)" : "")", systemImage: "checkmark")
                        } else {
                            Text("\(proxies[i])\(i == 0 ? " (primary)" : "")")
                        }
                    }
                }
            } label: {
                Text(current)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!engine.calls.isEmpty)
            .help(engine.calls.isEmpty ? "Switch outbound proxy" : "The proxy can be changed when no call is in progress")
        } else {
            Text(current).lineLimit(1)
        }
    }
}

// MARK: - Dialer

private let keypad: [[(String, String)]] = [
    [("1", ""), ("2", "ABC"), ("3", "DEF")],
    [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
    [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
    [("*", ""), ("0", "+"), ("#", "")],
]

struct Keypad: View {
    /// Diameter of a key: 66 in the window, smaller in the call panel.
    var size: CGFloat = 66
    var onKey: (String) -> Void

    var body: some View {
        VStack(spacing: size * 14 / 66) {
            ForEach(keypad.indices, id: \.self) { r in
                HStack(spacing: size / 3) {
                    ForEach(keypad[r], id: \.0) { key, letters in
                        Button { onKey(key) } label: {
                            VStack(spacing: 0) {
                                Text(key).font(.system(size: size * 26 / 66, weight: .regular, design: .rounded))
                                Text(letters).font(.system(size: max(7, size * 9 / 66), weight: .semibold)).foregroundStyle(.secondary)
                                    .frame(height: size * 10 / 66)
                            }
                            .frame(width: size, height: size)
                            .background(Circle().fill(Color.secondary.opacity(0.15)))
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct DialerView: View {
    @Environment(SIPEngine.self) private var engine
    @AppStorage("lastNumber") private var number = ""

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                // Typed via the keyboard (see handleKey) or the keypad below.
                Text(number.isEmpty ? "Enter a number" : number)
                    .font(.system(size: 28, weight: .light, design: .rounded))
                    .foregroundStyle(number.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity)
                    .contextMenu {
                        Button("Paste") { paste() }
                        Button("Clear") { number = "" }.disabled(number.isEmpty)
                    }
                Button { if !number.isEmpty { number.removeLast() } } label: {
                    Image(systemName: "delete.left").font(.title2)
                }
                .buttonStyle(.borderless)
                .opacity(number.isEmpty ? 0 : 1)
                .help("Delete the last digit (⌫). Esc or Clear erases the number.")
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            Keypad { key in
                number.append(key)
                engine.keypadFeedback(key)
            }

            Button(action: call) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
                    .frame(width: 66, height: 66)
                    .background(Circle().fill(canCall ? Color.green : Color.gray))
            }
            .buttonStyle(.plain)
            .disabled(!canCall)
            .help(number.isEmpty ? "Show the last number called (Return), then call it" : "Call (Return)")
            Spacer(minLength: 0)
        }
        .padding(.bottom, 16)
        .onKeyDown(handleKey)
    }

    /// Digits (also from the numeric keypad), * # +, ⌫/⌦ to delete, Esc/Clear to
    /// erase, Return/Enter to call and ⌘V to paste.
    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods == .command {
            guard event.charactersIgnoringModifiers?.lowercased() == "v" else { return false }
            paste()
            return true
        }
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case KeyCode.delete, KeyCode.forwardDelete:
            if !number.isEmpty { number.removeLast() }
            return true
        case KeyCode.escape, KeyCode.keypadClear:
            number = ""
            return true
        case KeyCode.returnKey, KeyCode.keypadEnter:
            call()
            return true
        default:
            guard let chars = event.characters, !chars.isEmpty,
                  chars.allSatisfy({ "0123456789*#+".contains($0) }) else { return false }
            number.append(chars)
            if !event.isARepeat { engine.keypadFeedback(chars) }
            return true
        }
    }

    private func paste() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        number.append(text.filter { "0123456789*#+".contains($0) })
    }

    /// The last number called, whichever way (keypad, Recents, Contacts).
    private var lastCalled: String? {
        engine.recents.first { !$0.incoming && !$0.number.isEmpty }?.number
    }

    private var canCall: Bool {
        guard case .registered = engine.registration else { return false }
        return !number.isEmpty || lastCalled != nil
    }

    /// Like a phone: with the field empty, Call brings back the last number called
    /// (a second Call dials it); the field is emptied once the call is placed.
    private func call() {
        guard canCall else { return }
        guard !number.isEmpty else {
            number = lastCalled ?? ""
            return
        }
        let before = engine.calls.count
        engine.dial(number)
        if engine.calls.count > before { number = "" }     // kept if the call was refused
    }
}

// MARK: - Recents

struct RecentsView: View {
    @Environment(SIPEngine.self) private var engine
    @AppStorage("lastNumber") private var number = ""
    var onSelect: () -> Void
    /// The entry waiting for the user to confirm its deletion.
    @State private var toDelete: RecentCall?
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            if engine.recents.isEmpty {
                Spacer()
                Text("No recent calls").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(engine.recents) { r in
                    HStack {
                        Image(systemName: r.voicemail == true ? "recordingtape"
                              : r.incoming ? "phone.arrow.down.left" : "phone.arrow.up.right")
                            .foregroundStyle(r.voicemail == true ? Color.blue : r.answered ? Color.secondary : Color.red)
                            .frame(width: 20)
                        VStack(alignment: .leading) {
                            Text(engine.recentTitle(r)).foregroundStyle(r.answered ? Color.primary : Color.red)
                            Text(r.date, format: .dateTime.day().month().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if r.answered {
                            Text(CallView.format(r.duration)).font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if !r.number.isEmpty { engine.dial(r.number) } }
                    .onTapGesture { if !r.number.isEmpty { number = r.number; onSelect() } }
                    .help(r.number.isEmpty ? "The caller's number was not provided"
                                           : "Click to edit, double-click to call; right-click to delete")
                    .contextMenu {
                        if !r.number.isEmpty {
                            Button("Call") { engine.dial(r.number) }
                            Button("Copy Number") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(r.number, forType: .string)
                            }
                            Divider()
                        }
                        Button("Delete…", role: .destructive) { toDelete = r }
                    }
                }
                HStack {
                    Spacer()
                    Button("Clear…") { confirmClear = true }.buttonStyle(.borderless).padding(8)
                }
            }
        }
        .confirmationDialog("Delete this call from Recents?",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            presenting: toDelete) { r in
            Button("Delete", role: .destructive) { engine.deleteRecent(r) }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text("\(engine.recentTitle(r)), \(r.date.formatted(.dateTime.day().month().hour().minute()))")
        }
        .confirmationDialog("Clear all recent calls?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) { engine.clearRecents() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(engine.recents.count) calls are removed from Recents.")
        }
    }
}

// MARK: - Log

struct LogView: View {
    @Environment(SIPEngine.self) private var engine

    var body: some View {
        LogLines(store: engine.logStore, engine: engine)
    }
}

/// Watches only the log, so that new lines redraw this tab and nothing else.
private struct LogLines: View {
    var store: LogStore
    let engine: SIPEngine

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.lines.indices, id: \.self) { i in
                            Text(store.lines[i])
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: store.lines.count) { _, n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.lines.joined(separator: "\n"), forType: .string)
                }
                Button("Show log file") {
                    NSWorkspace.shared.activateFileViewerSelecting([SIPEngine.logFileURL])
                }
                .help(SIPEngine.logFileURL.path)
                Spacer()
                Button("Clear") { engine.clearLog() }
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }
}
