import AppKit
import Foundation

/// Test bench: a copy of the app with the ".bench" identifier (made by scripts/bench/run.sh)
/// that measures the app without the provider. It registers with a stand-in registrar on
/// this Mac and is called by PJSIP's own test phone (pjsua), also on this Mac; then it
/// plays a scripted call: answer, keypad, recording, window, so each part can be
/// measured from outside. Its settings, logs and folders are its own; no password is
/// stored, and calls are silent (volume 0, no ringtone).
@MainActor
enum Bench {
    nonisolated static let isActive = Bundle.main.bundleIdentifier?.hasSuffix(".bench") ?? false

    nonisolated static let registrarPort = 5070
    nonisolated static let localPort = 5080
    nonisolated static let password = "bench"

    /// The account used by the bench: the stand-in registrar on this Mac, no VPN.
    nonisolated static var accountSettings: AccountSettings {
        var s = AccountSettings()
        s.username = "bench"
        s.domain = "127.0.0.1"
        s.proxyAddresses = ["127.0.0.1:\(registrarPort)"]
        s.localPort = localPort
        s.registrationExpiry = 600
        s.connectOnLaunch = true
        s.showInMenuBar = true
        s.incomingCallPanel = true
        s.openWindowAtStartup = false
        s.namesFromContacts = false
        s.missedCallNotifications = false
        s.answeringMachine = false
        s.logDetail = .detailed
        let env = ProcessInfo.processInfo.environment
        if env["BENCH_SRTP"] == "optional" { s.srtp = .optional }
        // Automatic local port, as most users have (the test phone cannot call it then).
        if env["BENCH_AUTOPORT"] == "1" { s.localPort = 0 }
        if isVoicemail {
            // With Do Not Disturb (set by run.sh) the machine answers after 3 s.
            s.answeringMachine = true
            s.amDelay = 3
            s.amMaxSeconds = 30
        }
        return s
    }

    /// The answering machine scenario (scripts/bench/run.sh voicemail).
    nonisolated static var isVoicemail: Bool {
        ProcessInfo.processInfo.environment["BENCH_SCENARIO"] == "voicemail"
    }

    /// The scripted call, step by step (seconds after it rings). Each step is written to
    /// the log ("BENCH step …") so the measuring script can tell the phases apart.
    static func incoming(_ engine: SIPEngine, id: Int32) {
        let steps: [(TimeInterval, String, () -> Void)] = [
            (2, "answer", { engine.answer(id) }),
            (3, "silent", { engine.setVolume(0, for: id) }),
            // 3…20: steady call, panel shown
            (20, "keypad", { CallPanel.shared.toggleKeypad() }),
            (22, "keypad", { CallPanel.shared.toggleKeypad() }),
            (24, "keypad", { CallPanel.shared.toggleKeypad() }),
            (26, "keypad", { CallPanel.shared.toggleKeypad() }),
            (28, "keypad", { CallPanel.shared.toggleKeypad() }),
            (30, "keypad", { CallPanel.shared.toggleKeypad() }),
            (32, "record", { engine.toggleRecording() }),
            (40, "record", { engine.toggleRecording() }),
            // 42…52: steady call with the window open
            (42, "window", { engine.windowRequest += 1 }),
            (52, "window-closed", { MainWindow.close() }),
            // 52…60: steady again; the microphone is switched and back (the log must say
            // so), then the test phone hangs up
            (55, "mic-switch", { engine.inputDeviceName = "MacBook Pro Microphone" }),
            (58, "mic-default", { engine.inputDeviceName = "" }),
        ]
        for (at, name, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                guard engine.calls.contains(where: { $0.id == id }) else { return }
                engine.appendLog("BENCH step \(name)")
                action()
            }
        }
    }
}
