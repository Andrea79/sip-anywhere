import AppKit
import SwiftUI
import UserNotifications

@main
struct SIPAnywhereApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var engine = SIPEngine()

    var body: some Scene {
        // One window: with the menu bar icon it can be closed and opened again while
        // the app keeps running.
        Window(AppIdentity.name, id: MainWindow.id) {
            ContentView()
                .environment(engine)
                .frame(minWidth: 340, idealWidth: 360, minHeight: 600)
                .onAppear {
                    appDelegate.engine = engine
                    // In the Dock while the window is open.
                    NSApp.setActivationPolicy(.regular)
                    engine.mainWindowOpen = true
                    startup()
                }
                .onDisappear {
                    engine.mainWindowOpen = false
                    // Window closed: only the menu bar icon remains.
                    if engine.settings.showInMenuBar { NSApp.setActivationPolicy(.accessory) }
                }
        }
        .windowResizability(.contentSize)
        .launchWindow(!AppDelegate.startsInMenuBarOnly)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // The same About as the menu bar's, with the link to the source code.
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppIdentity.name)") { About.show() }
            }
            CommandMenu("Account") {
                Button(engine.isOnline ? "Register Again" : "Register") {
                    if engine.isOnline { engine.reregister() } else { engine.connect() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!engine.settings.isComplete)
                Button("Go Offline") { engine.goOffline() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!engine.isOnline || !engine.calls.isEmpty)
                Divider()
                Toggle("Do Not Disturb", isOn: Binding(get: { engine.doNotDisturb },
                                                       set: { _ in engine.toggleDoNotDisturb() }))
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("Audio") {
                AudioDevicePickers(engine: engine)
            }
            CommandMenu("Call") {
                Button(engine.call?.muted == true ? "Unmute Microphone" : "Mute Microphone") {
                    engine.toggleMute()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!engine.canMute)
                Button(engine.call?.onHold == true ? "Resume Call" : "Hold Call") {
                    engine.toggleHold()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!engine.canHold)
                Button(engine.call?.recording == true ? "Stop Recording" : "Record Call") {
                    engine.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!engine.canRecord)
                Button("Merge Calls") { engine.mergeCalls() }
                    .disabled(engine.mergeCandidate == nil)
                Button("Show Recordings") { engine.showRecordings() }
                Divider()
                Button("End Call") { engine.hangup() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(engine.call == nil)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { engine.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window("Settings", id: SettingsWindow.id) {
            SettingsView().environment(engine)
        }
        .windowResizability(.contentSize)
        .launchWindow(false)

        MenuBarExtra(isInserted: Binding(get: { engine.settings.showInMenuBar }, set: { _ in })) {
            MenuBarMenu(engine: engine)
        } label: {
            // Also where startup happens when the window does not open at launch.
            MenuBarLabel(engine: engine)
                .onAppear { startup() }
        }
    }

    /// Once per launch, from the window or the menu bar icon, whichever appears first.
    private func startup() {
        appDelegate.engine = engine
        guard !appDelegate.started else { return }
        appDelegate.started = true
        engine.requestMicrophoneAccess()
        if engine.settings.connectOnLaunch && engine.settings.isComplete {
            engine.connect()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var engine: SIPEngine?
    /// Startup work (registration at launch) runs once, not each time the window opens.
    var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Network errors are handled where they occur; never die of SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        UNUserNotificationCenter.current().delegate = self
        // Starting in the menu bar only: no Dock icon, and the app in use keeps the focus.
        if Self.startsInMenuBarOnly {
            NSApp.setActivationPolicy(.accessory)
            return
        }
        // Needed when launched as a bare SwiftPM executable (no bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Missed call notifications also appear while the app is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Clicking a missed call notification opens the window on Recents.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.engine?.showRecents() }
        }
        completionHandler()
    }

    /// With the menu bar icon the app keeps running (and receiving calls) without a window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !(engine?.settings.showInMenuBar ?? false) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            engine?.disconnect()
            engine?.stopVPNAndWait()
        }
    }
}

extension AppDelegate {
    /// "Open the window at startup" is off, and the app can live without it (account set
    /// up, menu bar icon shown).
    static var startsInMenuBarOnly: Bool {
        let s = AccountSettings.load()
        return !s.openWindowAtStartup && s.showInMenuBar && s.isComplete
    }
}

extension Scene {
    /// Whether the window opens at launch. macOS 15 can keep it from opening at all; on
    /// macOS 14 it opens (and the user closes it).
    func launchWindow(_ open: Bool) -> some Scene {
        if #available(macOS 15.0, *) {
            return defaultLaunchBehavior(open ? .automatic : .suppressed)
        } else {
            return self
        }
    }
}
