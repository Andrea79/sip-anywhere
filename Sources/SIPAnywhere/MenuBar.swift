import AppKit
import SwiftUI

/// The Settings window, separate from the main one so that the app can be set up from
/// the menu bar without opening the phone window.
enum SettingsWindow {
    static let id = "settings"

    @MainActor static func open(_ openWindow: OpenWindowAction) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The app's identifier for its main window (a single `Window` scene).
enum MainWindow {
    static let id = "main"

    /// Shows the window and brings the app to the front.
    @MainActor static func open(_ openWindow: OpenWindowAction) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes the window, as its close button does.
    @MainActor static func close() {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true && $0.isVisible }?.performClose(nil)
    }
}

/// Icon in the menu bar, showing the state at a glance: registered, offline, a call.
struct MenuBarLabel: View {
    var engine: SIPEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
            if engine.missedCalls + engine.newVoiceMessages > 0 {
                Text("\(engine.missedCalls + engine.newVoiceMessages)")
            }
        }
            .help(MenuBarMenu.statusText(engine))
            .onChange(of: engine.showSettings) { show in
                if show { SettingsWindow.open(openWindow); engine.showSettings = false }
            }
            .onChange(of: engine.windowRequest) { _ in
                engine.windowOpenedForCall = false     // opened on purpose: keep it
                MainWindow.open(openWindow)
            }
            .onChange(of: engine.calls.isEmpty) {
                closeWindowIfOpenedForCall($0)
                if $0 { engine.callPanelHidden = false }
                updatePanel()
            }
            .onChange(of: engine.callPanelHidden) { _ in updatePanel() }
            .onChange(of: engine.mainWindowOpen) { _ in updatePanel() }
            .onChange(of: visibleCallID) { _ in updatePanel() }
            // An incoming call opens the window (if closed) so it can be answered, or the
            // call panel under the icon. The window is shown without taking the keyboard
            // from the app in use: a Return typed there must not answer the call.
            .onChange(of: hasIncomingCall) { incoming in
                guard incoming else { return }
                if engine.settings.usesCallPanel && !engine.mainWindowOpen {
                    updatePanel()
                    return
                }
                if !engine.mainWindowOpen { engine.windowOpenedForCall = true }
                openWindow(id: MainWindow.id)
                DispatchQueue.main.async {
                    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true }?
                        .orderFrontRegardless()
                }
            }
    }

    /// An incoming call that rings (not one waiting silently for the answering machine).
    private var hasIncomingCall: Bool { engine.calls.contains { $0.phase == .incoming && !$0.voicemailPending } }

    /// The call shown in the panel: any call except one waiting silently for the
    /// answering machine.
    private var visibleCallID: Int32? { engine.calls.first { !$0.voicemailPending }?.id }

    /// The panel is shown while there is a call, the window is closed and the panel is
    /// the chosen way; hidden otherwise.
    private func updatePanel() {
        if engine.settings.usesCallPanel && !engine.mainWindowOpen && visibleCallID != nil
            && !engine.callPanelHidden {
            CallPanel.shared.show(engine) {
                engine.windowOpenedForCall = false
                MainWindow.open(openWindow)
            }
        } else if CallPanel.shared.isVisible {
            CallPanel.shared.hide()
        }
    }

    private func closeWindowIfOpenedForCall(_ noCalls: Bool) {
        guard noCalls, engine.windowOpenedForCall else { return }
        engine.windowOpenedForCall = false
        MainWindow.close()
    }

    private var symbol: String {
        if hasIncomingCall { return "phone.fill.arrow.down.left" }
        if !engine.calls.isEmpty { return "phone.connection.fill" }
        if engine.doNotDisturb && engine.isOnline { return "moon.fill" }
        switch engine.registration {
        case .registered: return "phone.fill"
        case .registering: return "phone"
        case .offline, .failed: return "phone.down"
        }
    }
}

/// The menu under the menu bar icon.
struct MenuBarMenu: View {
    var engine: SIPEngine
    @Environment(\.openWindow) private var openWindow

    // Status first, then the window (always in the same place), the call, what is
    // new, the line's state, and the app itself.
    var body: some View {
        Text(Self.statusText(engine))
        if engine.vpnSettings.enabled {
            Text(vpnText)
        }
        Divider()
        if engine.mainWindowOpen {
            // Like the window's close button: the app stays here, ready for calls.
            Button("Close Window") { MainWindow.close() }
        } else {
            Button("Open \(AppIdentity.name)") {
                engine.windowOpenedForCall = false
                MainWindow.open(openWindow)
            }
        }
        if let call = engine.call {
            Divider()
            Text(call.voicemail ? "Answering machine: \(call.title)"
                 : call.phase == .incoming ? "Incoming call: \(call.title)" : "Call: \(call.title)")
            if call.phase == .incoming || call.voicemail {
                Button(call.voicemail ? "Take Call" : "Answer") {
                    MainWindow.open(openWindow)
                    engine.takeCall(call.id)
                }
            }
            if engine.callPanelHidden && !engine.mainWindowOpen {
                Button("Show Call Panel") { engine.callPanelHidden = false }
            }
            Button(call.phase == .incoming ? "Decline" : "End Call") { engine.hangup() }
        }
        if engine.missedCalls > 0 || engine.newVoiceMessages > 0 {
            Divider()
            if engine.missedCalls > 0 {
                Button("Missed Calls: \(engine.missedCalls)") { engine.showRecents() }
            }
            if engine.newVoiceMessages > 0 {
                Button("New Voice Messages: \(engine.newVoiceMessages)") { engine.showMessages() }
            }
        }
        Divider()
        Toggle("Do Not Disturb", isOn: Binding(get: { engine.doNotDisturb },
                                               set: { _ in engine.toggleDoNotDisturb() }))
        if engine.isOnline {
            Button("Go Offline") { engine.goOffline() }
                .disabled(!engine.calls.isEmpty)
        } else {
            Button("Register") { engine.connect() }
                .disabled(!engine.settings.isComplete)
        }
        Divider()
        Button("Settings…") { SettingsWindow.open(openWindow) }
            .keyboardShortcut(",")
        // The app menu's About is out of reach while the app lives in the menu bar only.
        Button("About \(AppIdentity.name)") { About.show() }
        Divider()
        Button("Quit \(AppIdentity.name)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    static func statusText(_ engine: SIPEngine) -> String {
        switch engine.registration {
        case .registered:
            return engine.settings.sipUser.isEmpty ? "Registered" : "Registered: \(engine.settings.sipUser)"
        case .registering: return "Registering…"
        case .offline: return "Offline"
        case .failed(let code, let reason): return "Not registered (\(code) \(reason))"
        }
    }

    private var vpnText: String {
        switch engine.vpnState {
        case .off: return "VPN: off"
        case .connecting: return "VPN: connecting…"
        case .connected(let ip): return "VPN: connected (\(ip))"
        case .failed: return "VPN: not connected"
        }
    }
}
