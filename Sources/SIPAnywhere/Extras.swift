import AppKit
import CSIPCore
import Foundation
import UserNotifications

// Names from Contacts, missed call notifications, Do Not Disturb, the answering machine,
// call recording and three-way conference.
extension SIPEngine {

    // MARK: - Names from Contacts

    func contactName(for number: String) -> String? {
        guard settings.namesFromContacts, !number.isEmpty else { return nil }
        _ = contactsVersion     // views showing the name redraw when Contacts change
        return contacts.name(for: number)
    }

    /// What Recents shows for a call: its name, a contact's name, or the number.
    func recentTitle(_ r: RecentCall) -> String {
        if let name = r.name, !name.isEmpty { return name }
        return contactName(for: r.number) ?? r.number
    }

    // MARK: - Do Not Disturb

    func toggleDoNotDisturb() {
        doNotDisturb.toggle()
        if doNotDisturb && settings.answeringMachine { prepareGreeting() }
        appendLog(doNotDisturb ? "Do Not Disturb on: this Mac refuses incoming calls (486), other phones still ring"
                               : "Do Not Disturb off")
    }

    /// Do Not Disturb: this device refuses the call (486 Busy Here). The provider keeps
    /// ringing the line's other phones (e.g. the phone on the router), so the caller
    /// hears ringing, not busy; someone else can still answer. Noted in Recents,
    /// without a notification.
    func refuseForDoNotDisturb(_ c: ActiveCall) {
        sip_hangup(c.id, 486)
        appendLog("Do Not Disturb: refused the call from \(c.title)")
        noteMissedCall(c, notify: false)
        addRecent(RecentCall(number: c.number, name: c.displayName.isEmpty ? nil : c.displayName,
                             date: Date(), incoming: true, answered: false, duration: 0))
    }

    // MARK: - Missed calls

    func noteMissedCall(_ c: ActiveCall, notify: Bool) {
        missedCalls += 1
        guard notify, settings.missedCallNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "Missed call"
        content.body = c.title.isEmpty ? "Unknown caller" : c.title
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { center.add(request) }
        }
    }

    /// Recents was viewed: the missed calls have been seen.
    func clearMissedCalls() {
        if missedCalls != 0 { missedCalls = 0 }
    }

    /// Opens the window on Recents (from a notification or the menu bar).
    func showRecents() {
        requestedTab = 1
        windowRequest += 1
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Call recording

    static var recordingsFolder: URL { AnsweringMachine.recordingsFolder }

    var canRecord: Bool { call?.phase == .active }

    func toggleRecording() {
        guard let c = call, c.phase == .active else { return }
        if c.recording {
            sip_record_stop(c.id)
            update(c.id) { $0.recording = false }
            return
        }
        let folder = Self.recordingsFolder
        let url = AnsweringMachine.newFile(in: folder, caller: c.number.isEmpty ? c.title : c.number)
        if sip_record_start(c.id, url.path) == 0 {
            update(c.id) { $0.recording = true }
        } else {
            lastError = "Could not start recording to \(folder.path)."
        }
    }

    func showRecordings() {
        NSWorkspace.shared.open(Self.recordingsFolder)
    }

    func showVoicemail() {
        NSWorkspace.shared.open(AnsweringMachine.voicemailFolder)
    }

    // MARK: - Conference

    /// The other call that can be joined with the one on screen (exactly two calls,
    /// both connected, not already joined).
    var mergeCandidate: ActiveCall? {
        guard calls.count == 2, let current = call, current.phase == .active,
              current.conferenceWith == nil,
              let other = calls.first(where: { $0.id != current.id }), other.phase == .active
        else { return nil }
        return other
    }

    /// Joins the two calls: both are resumed and hear each other and us.
    func mergeCalls() {
        guard let current = call, let other = mergeCandidate else { return }
        update(current.id) { $0.conferenceWith = other.id }
        update(other.id) { $0.conferenceWith = current.id }
        sip_conference(current.id, other.id, 1)
        for c in [current, other] where c.onHold { setHold(c.id, false) }
        appendLog("Conference: \(current.title) and \(other.title) joined")
    }

    /// Separates the calls again: the other one is put on hold.
    func splitConference() {
        guard let current = call, let otherID = current.conferenceWith else { return }
        sip_conference(current.id, otherID, 0)
        update(current.id) { $0.conferenceWith = nil }
        update(otherID) { $0.conferenceWith = nil }
        setHold(otherID, true)
        appendLog("Conference ended: \(current.title) stays on the line")
    }
}

// MARK: - Answering machine (with Do Not Disturb)

extension SIPEngine {

    /// Do Not Disturb with the answering machine: the Mac stays silent while the line's
    /// other phones ring; if nobody answers within amDelay seconds, the machine does.
    func waitForAnsweringMachine(_ call: ActiveCall) {
        var c = call
        c.voicemailPending = true
        c.statusText = "Answering machine in \(settings.amDelay) s"
        addSilentCall(c)
        appendLog("Do Not Disturb: \(c.title) calling; the answering machine answers in \(settings.amDelay) s")
        let id = c.id
        Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.amDelay), repeats: false) { _ in
            MainActor.assumeIsolated { self.answerWithMachine(id) }
        }
    }

    func answerWithMachine(_ id: Int32) {
        guard let c = calls.first(where: { $0.id == id }), c.phase == .incoming, c.voicemailPending else { return }
        AnsweringMachine.ensureGreeting()
        let message = AnsweringMachine.newFile(in: AnsweringMachine.voicemailFolder,
                                               caller: c.number.isEmpty ? c.title : c.number)
        if sip_voicemail_answer(id, AnsweringMachine.greetingURL.path, message.path, Int32(settings.amMaxSeconds)) == 0 {
            update(id) {
                $0.voicemailPending = false
                $0.voicemail = true
                $0.messagePath = message.path
                $0.statusText = "Answering machine"
            }
        } else {
            lastError = "The answering machine could not answer."
        }
    }

    /// Picks the call up from the answering machine (or before it answers).
    func takeCall(_ id: Int32) {
        guard let c = calls.first(where: { $0.id == id }) else { return }
        if c.voicemailPending {
            update(id) { $0.voicemailPending = false }
            answer(id)
        } else if c.voicemail, sip_voicemail_takeover(id) == 0 {
            update(id) { $0.voicemail = false; $0.statusText = "Connected" }
            makeCurrent(id)
        }
    }

    /// The end of a call the machine handled or was about to. Returns true when a
    /// message was left (then noted as such in Recents).
    func finishVoicemail(_ c: ActiveCall) -> Bool {
        let url = c.messagePath.map { URL(fileURLWithPath: $0) }
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            // Hung up during the greeting, or answered on another phone before the machine.
            noteMissedCall(c, notify: !doNotDisturb)
            return false
        }
        guard AnsweringMachine.duration(of: url) >= 1 else {
            try? FileManager.default.removeItem(at: url)
            noteMissedCall(c, notify: !doNotDisturb)
            return false
        }
        refreshVoiceMessages()
        appendLog("Answering machine: message from \(c.title) saved")
        if settings.missedCallNotifications {
            let content = UNMutableNotificationContent()
            content.title = "New voice message"
            content.body = c.title.isEmpty ? "Unknown caller" : c.title
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { center.add(request) }
            }
        }
        addRecent(RecentCall(number: c.number, name: c.displayName.isEmpty ? nil : c.displayName,
                             date: Date(), incoming: true, answered: false,
                             duration: AnsweringMachine.duration(of: url), voicemail: true))
        return true
    }

    var newVoiceMessages: Int { voiceMessages.filter { !heardMessages.contains($0.id) }.count }

    func refreshVoiceMessages() {
        voiceMessages = AnsweringMachine.messages()
    }

    func markHeard(_ m: VoiceMessage) {
        heardMessages.insert(m.id)
    }

    /// Moves the message's file to the Trash, so that a mistake can be undone there.
    func deleteMessage(_ m: VoiceMessage) {
        if (try? FileManager.default.trashItem(at: m.url, resultingItemURL: nil)) == nil {
            try? FileManager.default.removeItem(at: m.url)
        }
        heardMessages.remove(m.id)
        refreshVoiceMessages()
    }

    /// Opens the window on the Messages tab.
    func showMessages() {
        requestedTab = 2
        windowRequest += 1
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Rebuilds the greeting from the settings (in the background: `say` takes a moment).
    func prepareGreeting() {
        let s = settings
        DispatchQueue.global(qos: .utility).async {
            AnsweringMachine.prepareGreeting(from: s)
        }
    }
}
