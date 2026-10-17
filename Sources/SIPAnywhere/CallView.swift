import SwiftUI

/// The in-call screen: header (direction, number, timer, encryption, quality),
/// a card with the other party and yourself, and a control bar.
struct CallView: View {
    @Environment(SIPEngine.self) private var engine
    let call: ActiveCall

    @State private var showKeypad = false
    @State private var dtmf = ""
    @State private var showStats = false
    @State private var showTransfer = false
    @State private var showAddCall = false
    @State private var showCalls = false

    var body: some View {
        VStack(spacing: 14) {
            header
            card
            if let waiting = engine.waitingCall { WaitingBanner(call: waiting) }
            if !engine.otherCalls.isEmpty { otherCallsStrip }
            if call.voicemail { answeringMachineBar } else if call.phase == .incoming { incomingBar } else { controlBar }
        }
        .padding(16)
        .background(Color(white: 0.04))
        .environment(\.colorScheme, .dark)
        .onChange(of: call.id) { showKeypad = false; dtmf = "" }
        .onKeyDown(handleKey)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: call.incoming ? "arrow.down.left" : "arrow.up.right")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(call.incoming ? Color.green : Color.blue)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(call.title).lineLimit(1)
                    if let start = call.connectedAt {
                        Text("|").foregroundStyle(.secondary)
                        TimelineView(.periodic(from: start, by: 1)) { ctx in
                            Text(Self.format(ctx.date.timeIntervalSince(start))).monospacedDigit()
                        }
                    }
                }
                .font(.system(size: 22, weight: .bold))
                Label(call.encrypted ? "Encrypted call (SRTP)" : "Unencrypted call",
                      systemImage: call.encrypted ? "lock.fill" : "lock.open")
                    .font(.callout)
                    .foregroundStyle(call.encrypted ? Color.green : Color.primary)
            }
            Spacer()
            if call.isLive { volumeControl.padding(.top, 6) }
            Button { showStats.toggle() } label: { QualityBars(level: call.quality) }
                .buttonStyle(.plain)
                .help(qualityHelp)
                .popover(isPresented: $showStats, arrowEdge: .bottom) { CallStats(call: call) }
        }
    }

    /// Volume of this call only. The speaker icon switches between full and low,
    /// e.g. for a long wait with hold music.
    private var volumeControl: some View {
        HStack(spacing: 6) {
            Button {
                engine.setVolume(call.volume < 1 ? 1 : Self.lowVolume, for: call.id)
            } label: {
                Image(systemName: volumeIcon).frame(width: 20)
            }
            .buttonStyle(.plain)
            .help(call.volume < 1 ? "Back to full volume" : "Lower this call to \(Int(Self.lowVolume * 100))%")
            Slider(value: Binding(get: { Double(call.volume) },
                                  set: { engine.setVolume(Float($0), for: call.id) }), in: 0...1)
                .controlSize(.small)
                .frame(width: 110)
                .help("Volume of this call only; the Mac's volume does not change. Arrow keys: ±5%, ±1% below 5%")
            Text("\(Int((call.volume * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .font(.callout)
        .foregroundStyle(call.volume < 1 ? Color.orange : Color.secondary)
    }

    static let lowVolume: Float = 0.15

    /// Next step up or down: 5% steps, and 1% steps at 5% and below, for fine control
    /// of a quiet call. A slider position in between moves to the next step.
    static func volumeStep(_ v: Float, by direction: Int) -> Float {
        let p = Int((v * 100).rounded())
        let next: Int
        if direction > 0 {
            next = p < 5 ? p + 1 : p - p % 5 + 5
        } else {
            next = p <= 5 ? p - 1 : (p % 5 == 0 ? p - 5 : p - p % 5)
        }
        return Float(min(max(next, 0), 100)) / 100
    }

    private var volumeIcon: String {
        switch call.volume {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private var qualityHelp: String {
        switch call.quality {
        case 4: return "Excellent call quality"
        case 3: return "Good call quality"
        case 2: return "Fair call quality"
        case 1: return "Poor call quality"
        case 0: return "No audio received"
        default: return "Call quality not available yet"
        }
    }

    // MARK: Card

    private var card: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.17))
            if showKeypad {
                VStack(spacing: 12) {
                    Text(dtmf.isEmpty ? " " : dtmf).font(.title2.monospaced()).lineLimit(1).truncationMode(.head)
                    Keypad { key in
                        dtmf.append(key)
                        engine.sendDTMF(key)
                    }
                }
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 10) {
                    Avatar(text: call.title, size: 110)
                        .opacity(call.onHold ? 0.45 : 1)
                    Text(call.title).font(.system(size: 26, weight: .light)).lineLimit(1)
                    if !call.uri.isEmpty {
                        Text(call.uri).font(.callout).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                    }
                    statusChips
                }
                .padding(.bottom, 70)
            }
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    if !showKeypad { Text(call.title).font(.callout).lineLimit(1) }
                    Spacer()
                    if !showKeypad { SelfTile(name: ownName, muted: call.muted) }
                }
            }
            .padding(12)
        }
        .frame(maxHeight: .infinity)
    }

    private var ownName: String {
        engine.settings.displayName.isEmpty ? engine.settings.sipUser : engine.settings.displayName
    }

    private var statusChips: some View {
        HStack(spacing: 8) {
            if call.phase != .active {
                Chip(text: call.statusText, color: .gray)
            }
            if call.onHold { Chip(text: "On hold", systemImage: "pause.fill", color: .orange) }
            if call.remoteHold { Chip(text: "Holding you", systemImage: "pause.fill", color: .orange) }
            if call.muted { Chip(text: "Microphone muted", systemImage: "mic.slash.fill", color: .red) }
            if call.recording { Chip(text: "Recording", systemImage: "record.circle.fill", color: .red) }
            if call.voicemail {
                Chip(text: "Answering machine", systemImage: "recordingtape", color: .blue)
            } else if call.voicemailPending {
                Chip(text: "Do Not Disturb", systemImage: "moon.fill", color: .purple)
            }
            if call.conferenceWith != nil { Chip(text: "Conference", systemImage: "person.3.fill", color: .blue) }
            if let t = call.transferStatus { Chip(text: t, systemImage: "phone.arrow.right", color: .blue) }
        }
    }

    private var otherCallsStrip: some View {
        VStack(spacing: 6) {
            ForEach(engine.otherCalls) { other in
                HStack(spacing: 10) {
                    Image(systemName: other.onHold ? "pause.circle.fill" : "phone.circle.fill")
                        .foregroundStyle(other.onHold ? .orange : .green)
                    Text(other.title).lineLimit(1)
                    Text(other.onHold ? "On hold" : other.statusText).foregroundStyle(.secondary)
                    Spacer()
                    if other.conferenceWith == call.id {
                        Text("In conference").foregroundStyle(.blue)
                        Button("Split") { engine.splitConference() }
                            .help("Separate the calls again: this one is put on hold")
                    } else {
                        if engine.mergeCandidate?.id == other.id {
                            Button("Merge") { engine.mergeCalls() }
                                .help("Join the two calls: everyone hears everyone")
                        }
                        Button("Switch") { engine.switchTo(other.id) }
                    }
                    Button("End") { engine.hangup(other.id) }
                }
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13)))
            }
        }
    }

    // MARK: Controls

    /// The answering machine has the call: take it, or let the caller leave the message.
    private var answeringMachineBar: some View {
        HStack(spacing: 60) {
            BarButton(icon: "phone.down.fill", label: "End", tint: .red, wide: true) { engine.hangup() }
            BarButton(icon: "phone.fill", label: "Take Call", tint: .green, wide: true) { engine.takeCall(call.id) }
                .help("Talk to the caller: the answering machine stops (what it recorded is kept)")
        }
        .padding(.vertical, 4)
    }

    private var incomingBar: some View {
        HStack(spacing: 60) {
            BarButton(icon: "phone.down.fill", label: "Decline", tint: .red, wide: true) { engine.hangup() }
            BarButton(icon: "phone.fill", label: "Answer", tint: .green, wide: true) { engine.answer() }
                .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.vertical, 4)
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            BarButton(icon: call.muted ? "mic.slash.fill" : "mic.fill",
                      label: call.muted ? "Unmute" : "Mute", on: call.muted, onTint: .red) { engine.toggleMute() }
                .help("Mute or unmute the microphone (⇧⌘M)")
            BarButton(icon: "circle.grid.3x3.fill", label: "Keypad", on: showKeypad) { showKeypad.toggle() }
                .disabled(call.phase != .active)
                .help("Send tones, e.g. to answer a voice menu")
            BarButton(icon: call.recording ? "stop.circle.fill" : "record.circle",
                      label: call.recording ? "Stop" : "Record", on: call.recording, onTint: .red) {
                engine.toggleRecording()
            }
            .disabled(call.phase != .active)
            .help(call.recording
                  ? "Stop recording (⌥⌘R)"
                  : "Record this call, both sides, to a file in Music › \(AppIdentity.name) (⌥⌘R). "
                    + "Only you may keep it: ask the other party before recording or sharing it.")
            MoreMenu(showStats: $showStats)

            Spacer(minLength: 12)

            BarButton(icon: call.onHold ? "play.fill" : "pause.fill",
                      label: call.onHold ? "Resume" : "Hold", on: call.onHold, onTint: .orange) { engine.toggleHold() }
                .disabled(!engine.canHold)
                .help(call.onHold ? "Resume the call (⇧⌘H)" : "Put the call on hold (⇧⌘H)")
            BarButton(icon: "phone.arrow.right", label: "Transfer") { showTransfer = true }
                .disabled(call.phase != .active)
                .help("Transfer the call to another number or to your other call")
                .popover(isPresented: $showTransfer, arrowEdge: .top) {
                    TransferPopover(call: call) { showTransfer = false }
                }
            BarButton(icon: "phone.badge.plus", label: "Add call") { showAddCall = true }
                .disabled(engine.calls.count >= 4)
                .help("Call someone else; this call is put on hold")
                .popover(isPresented: $showAddCall, arrowEdge: .top) {
                    NumberPopover(title: "Add call", subtitle: "The current call is put on hold.",
                                  action: "Call") { number in
                        showAddCall = false
                        engine.dial(number)
                    }
                }
            BarButton(icon: "list.bullet", label: "Calls", badge: engine.calls.count > 1 ? engine.calls.count : nil) {
                showCalls = true
            }
            .disabled(engine.calls.count < 2)
            .help("All calls")
            .popover(isPresented: $showCalls, arrowEdge: .top) { CallsPopover { showCalls = false } }

            Spacer(minLength: 12)

            BarButton(icon: "phone.down.fill", label: "End", tint: .red, wide: true) { engine.hangup() }
                .help("End the call")
        }
    }

    /// During a connected call, typed digits (also from the numeric keypad) and * #
    /// are sent as tones and shown on the keypad; Esc hides the keypad.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              engine.call?.phase == .active else { return false }
        if event.keyCode == KeyCode.escape, showKeypad {
            showKeypad = false
            return true
        }
        // Arrows: volume of this call, 5% a step. The key monitor keeps the view as it
        // was when it appeared, so the current call comes from the engine.
        guard let current = engine.call else { return false }
        switch event.keyCode {
        case KeyCode.upArrow, KeyCode.rightArrow:
            engine.setVolume(Self.volumeStep(current.volume, by: 1), for: current.id)
            return true
        case KeyCode.downArrow, KeyCode.leftArrow:
            engine.setVolume(Self.volumeStep(current.volume, by: -1), for: current.id)
            return true
        default:
            break
        }
        guard let chars = event.characters, chars.count == 1,
              "0123456789*#".contains(chars) else { return false }
        showKeypad = true
        dtmf.append(chars)
        engine.sendDTMF(chars)
        return true
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600
            ? String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Pieces

private struct Avatar: View {
    let text: String
    let size: CGFloat

    var body: some View {
        let initial = text.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
        Circle()
            .fill(Color(red: 0.88, green: 0.92, blue: 0.95))
            .frame(width: size, height: size)
            .overlay(
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.27, green: 0.35, blue: 0.45))
            )
    }
}

private struct SelfTile: View {
    let name: String
    let muted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Avatar(text: name, size: 48)
                Spacer()
            }
            HStack(spacing: 4) {
                Text(name).font(.caption).lineLimit(1)
                if muted { Image(systemName: "mic.slash.fill").font(.caption2).foregroundStyle(.red) }
            }
        }
        .padding(10)
        .frame(width: 130)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.24)))
        .help("You")
    }
}

private struct Chip: View {
    let text: String
    var systemImage: String?
    let color: Color

    var body: some View {
        Group {
            if let systemImage { Label(text, systemImage: systemImage) } else { Text(text) }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.85)))
        .lineLimit(1)
    }
}

/// Four signal-style bars; `level` -1 = unknown (all dim).
struct QualityBars: View {
    let level: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i <= level ? color : Color.secondary.opacity(0.35))
                    .frame(width: 5, height: CGFloat(6 + i * 5))
            }
        }
        .frame(height: 26, alignment: .bottom)
        .padding(4)
        // The whole area answers clicks, not only the thin bars (also the gaps and the
        // space above the short bars).
        .contentShape(Rectangle())
    }

    private var color: Color {
        switch level {
        case 4, 3: return .white
        case 2: return .yellow
        default: return .red
        }
    }
}

/// Round control button with a label underneath, as in the call bar.
private struct BarButton: View {
    let icon: String
    let label: String
    var on = false
    var onTint: Color = .white
    var tint: Color?
    var wide = false
    var badge: Int?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 5) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(foreground)
                    .frame(width: wide ? 72 : 46, height: 46)
                    .background(Capsule().fill(background))
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Text("\(badge)").font(.caption2.bold()).foregroundStyle(.white)
                                .padding(4).background(Circle().fill(Color.blue)).offset(x: 4, y: -4)
                        }
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var background: Color {
        if let tint { return tint }
        return on ? onTint : Color(white: 0.3)
    }

    private var foreground: Color {
        if tint != nil { return .white }
        return on ? (onTint == .white ? .black : .white) : .white
    }
}

/// ⋮ menu: audio devices and call statistics.
private struct MoreMenu: View {
    @Environment(SIPEngine.self) private var engine
    @Binding var showStats: Bool

    var body: some View {
        VStack(spacing: 5) {
            Menu {
                AudioDevicePickers(engine: engine)
                Divider()
                Button("Call statistics…") { showStats = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .bold))
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color(white: 0.3)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Audio devices and call statistics")
            Text("More").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct CallStats: View {
    @Environment(SIPEngine.self) private var engine
    let call: ActiveCall

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            row("Codec", call.codec.isEmpty ? "—" : call.codec)
            row("Signalling", engine.settings.transport.label)
            row("Audio", call.encrypted ? "Encrypted (SRTP)" : "Unencrypted")
            let m = engine.mediaStats[call.id] ?? MediaStats()
            row("Packet loss", call.quality < 0 ? "—" : String(format: "%.1f %%", m.lossPct))
            row("Jitter", call.quality < 0 ? "—" : "\(m.jitterMs) ms")
            row("Round trip", m.rttMs > 0 ? "\(m.rttMs) ms" : "—")
        }
        .font(.callout)
        .padding(14)
        .frame(minWidth: 230)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit().textSelection(.enabled)
        }
    }
}

/// Small number entry used by "Add call" and "Transfer".
private struct NumberPopover: View {
    let title: String
    let subtitle: String
    let action: String
    let onSubmit: (String) -> Void
    @State private var number = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Number", text: $number, prompt: Text("0612345678"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                Button(action, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(number.filter(\.isNumber).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !number.filter(\.isNumber).isEmpty else { return }
        onSubmit(number)
    }
}

private struct TransferPopover: View {
    @Environment(SIPEngine.self) private var engine
    let call: ActiveCall
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NumberPopover(title: "Transfer \(call.title)",
                          subtitle: "Blind transfer: the call is passed on and you leave it.",
                          action: "Transfer") { number in
                engine.transfer(to: number)
                done()
            }
            let others = engine.otherCalls.filter { $0.phase == .active }
            if !others.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Or connect with your other call").font(.caption).foregroundStyle(.secondary)
                    ForEach(others) { other in
                        Button("Connect \(call.title) with \(other.title)") {
                            engine.transfer(toCall: other.id)
                            done()
                        }
                    }
                }
                .padding(14)
            }
        }
    }
}

private struct CallsPopover: View {
    @Environment(SIPEngine.self) private var engine
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calls").font(.headline)
            ForEach(engine.calls) { c in
                HStack(spacing: 10) {
                    Image(systemName: c.id == engine.call?.id ? "speaker.wave.2.fill"
                          : c.onHold ? "pause.circle.fill" : "phone.circle.fill")
                        .frame(width: 18)
                    VStack(alignment: .leading) {
                        Text(c.title)
                        Text(c.phase == .incoming ? "Ringing" : c.onHold ? "On hold" : c.statusText)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if c.id != engine.call?.id && c.phase != .incoming {
                        Button("Switch") { engine.switchTo(c.id); done() }
                    }
                    Button("End") { engine.hangup(c.id) }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// Banner for a second incoming call while you are in a call.
private struct WaitingBanner: View {
    @Environment(SIPEngine.self) private var engine
    let call: ActiveCall

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "phone.arrow.down.left").foregroundStyle(.green)
            VStack(alignment: .leading) {
                Text("Incoming call").font(.caption).foregroundStyle(.secondary)
                Text(call.title).lineLimit(1)
            }
            Spacer()
            PillButton(title: "Decline", icon: "phone.down.fill", color: .red) { engine.decline(call.id) }
            PillButton(title: "Hold & Answer", icon: "phone.fill", color: .green) { engine.answer(call.id) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13)))
    }
}

private struct PillButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
