import AppKit
import SwiftUI

/// A small panel under the menu bar icon: Answer / Decline while a call rings, then a
/// mini call control (duration, mute, keypad, end; ⊕ opens the window). Used instead of opening
/// the main window when Settings › Startup › Incoming calls is "Panel", and only while
/// the main window is closed. It never takes the keyboard from the app in use.
@MainActor
final class CallPanel {
    static let shared = CallPanel()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let state = CallPanelState()
    /// The panel's content for a given state (the live one, or one being measured).
    private var content: ((CallPanelState) -> AnyView)?

    func show(_ engine: SIPEngine, openWindow: @escaping () -> Void) {
        if panel == nil {
            let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 120),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                            backing: .buffered, defer: true)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            panel = p
        }
        guard let p = panel else { return }
        content = { state in AnyView(CallPanelView(openWindow: openWindow).environment(engine).environment(state)) }
        let host = FirstClickHostingView(rootView: content!(state))
        // Measured before it goes in: from then on the panel's size is set here (see
        // setHeight), not by SwiftUI, which would make the panel grow upwards.
        let size = host.fittingSize
        host.sizingOptions = []
        p.contentView = host
        p.setContentSize(size)
        place(p)
        p.orderFrontRegardless()
        // Arrow keys change the call's volume and digits are sent as tones, as in the
        // window, once the panel has been clicked (it never takes the keyboard by itself).
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak engine] event in
                guard let self, let engine, event.window === self.panel, let call = engine.call,
                      call.phase == .active, !call.voicemail else { return event }
                switch event.keyCode {
                case KeyCode.upArrow, KeyCode.rightArrow:
                    engine.setVolume(CallView.volumeStep(call.volume, by: 1), for: call.id)
                case KeyCode.downArrow, KeyCode.leftArrow:
                    engine.setVolume(CallView.volumeStep(call.volume, by: -1), for: call.id)
                default:
                    guard let c = event.charactersIgnoringModifiers, c.count == 1, "0123456789*#".contains(c),
                          event.modifierFlags.intersection([.command, .control, .option]).isEmpty
                    else { return event }
                    if !event.isARepeat { self.state.press(c, engine) }
                }
                return nil
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        state.keypad = false
        state.keypadDrawn = false
        state.digits = ""
    }

    /// Opens or closes the keypad below the buttons. Only the keypad moves: the panel's
    /// window takes the larger size at once (its lower part still empty and see-through),
    /// then SwiftUI slides the keypad out from under the buttons; closing slides it back
    /// and then shrinks the window. The window itself is never animated, so the header,
    /// volume and buttons stay exactly where they are.
    func toggleKeypad() {
        guard let p = panel else { return }
        let open = !state.keypad
        state.keypad = open
        let slide = Animation.easeInOut(duration: 0.2)
        if open {
            setHeight(of: p, to: p.frame.height + keypadHeight)
            withAnimation(slide) { state.keypadDrawn = true } completion: { p.invalidateShadow() }
            // Typed digits (numeric keypad included) go straight to the keypad: the panel
            // takes the keyboard, without bringing the app forward.
            p.makeKey()
        } else {
            withAnimation(slide) { state.keypadDrawn = false } completion: { [weak self] in
                guard let self, !self.state.keypad else { return }
                self.setHeight(of: p, to: p.frame.height - self.keypadHeight)
                p.invalidateShadow()
            }
        }
    }

    /// Changes the window's height keeping its top edge where it is.
    private func setHeight(of p: NSPanel, to height: CGFloat) {
        let f = p.frame
        p.setFrame(NSRect(x: f.minX, y: f.maxY - height, width: f.width, height: height), display: true)
    }

    /// How much taller the panel is with the keypad: measured once, on copies of the
    /// content (measuring costs a few tens of milliseconds; the keypad never changes size).
    private var keypadHeight: CGFloat {
        if let h = measuredKeypadHeight { return h }
        guard let content else { return 0 }
        func height(_ keypad: Bool) -> CGFloat {
            let probe = CallPanelState()
            probe.keypad = keypad
            probe.keypadDrawn = keypad
            return NSHostingView(rootView: content(probe)).fittingSize.height
        }
        let h = height(true) - height(false)
        measuredKeypadHeight = h
        return h
    }
    private var measuredKeypadHeight: CGFloat?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Under our menu bar icon (the status item's window), else top right of the screen.
    private func place(_ p: NSPanel) {
        let size = p.frame.size
        let icon = NSApp.windows.first { $0.className.contains("NSStatusBarWindow") && $0.isVisible }?.frame
        let screen = (icon.flatMap { f in NSScreen.screens.first { $0.frame.contains(f.origin) } } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = icon.map { $0.midX - size.width / 2 } ?? (screen.maxX - size.width - 12)
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let y = (icon?.minY ?? screen.maxY) - size.height - 6
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// What the panel shows beyond the call itself, kept while its content is rebuilt.
@MainActor
@Observable
final class CallPanelState {
    /// The keypad is open (or opening).
    var keypad = false
    /// The keypad is drawn: also while the panel slides closed over it.
    var keypadDrawn = false
    /// Tones sent during this call, shown above the keypad.
    var digits = ""

    func press(_ key: String, _ engine: SIPEngine) {
        digits.append(key)
        engine.sendDTMF(key)
    }
}

/// Borderless panels cannot become key by default; this one can (without activating
/// the app, being non-activating).
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The panel is usually not the key window: its buttons must act on the first click
/// (Answer), not spend it bringing the panel forward.
private final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct CallPanelView: View {
    @Environment(SIPEngine.self) private var engine
    @Environment(CallPanelState.self) private var state
    let openWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let call = engine.call {
                header(call)
                // Always laid out, shown during a call: the panel keeps one size (it is
                // placed once under the icon) from ringing to talking.
                volume(call)
                    .opacity(isTalking(call) ? 1 : 0)
                    .disabled(!isTalking(call))
                if call.phase == .incoming && !call.voicemailPending {
                    HStack(spacing: 10) {
                        PanelButton(title: "Decline", icon: "phone.down.fill", color: .red) { engine.hangup(call.id) }
                        PanelButton(title: "Answer", icon: "phone.fill", color: .green) { engine.answer(call.id) }
                    }
                } else if call.voicemail {
                    HStack(spacing: 10) {
                        PanelButton(title: "End", icon: "phone.down.fill", color: .red) { engine.hangup(call.id) }
                        PanelButton(title: "Take Call", icon: "phone.fill", color: .green) { engine.takeCall(call.id) }
                    }
                } else {
                    VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        PanelButton(title: call.muted ? "Unmute" : "Mute",
                                    icon: call.muted ? "mic.slash.fill" : "mic.fill",
                                    color: call.muted ? .red : .gray) { engine.toggleMute() }
                            .disabled(!engine.canMute)
                        PanelButton(title: "Keypad", icon: "circle.grid.3x3.fill",
                                    color: state.keypad ? .blue : .gray) { CallPanel.shared.toggleKeypad() }
                        PanelButton(title: "End", icon: "phone.down.fill", color: .red) { engine.hangup(call.id) }
                    }
                    // The keypad slides out from under the buttons: clipped, it never
                    // passes over them.
                    VStack(spacing: 0) {
                        if state.keypadDrawn {
                            VStack(spacing: 8) {
                                Text(state.digits.isEmpty ? " " : state.digits)
                                    .font(.title3.monospaced()).lineLimit(1).truncationMode(.head)
                                Keypad(size: 48) { state.press($0, engine) }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                            .transition(.move(edge: .top))
                        }
                    }
                    .clipped()
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 330)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        // Pinned to the top of the window: while the keypad slides, the rest stays still
        // and the window's empty lower part stays see-through.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func header(_ call: ActiveCall) -> some View {
        HStack(spacing: 10) {
            Image(systemName: call.phase == .incoming ? "phone.fill.arrow.down.left"
                  : call.voicemail ? "recordingtape" : "phone.connection.fill")
                .font(.title2)
                .foregroundStyle(call.voicemail ? .blue : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.title).font(.headline).lineLimit(1)
                Group {
                    if call.phase == .incoming {
                        Text("Incoming call")
                    } else if call.voicemail {
                        Text("Answering machine")
                    } else if let start = call.connectedAt {
                        TimelineView(.periodic(from: start, by: 1)) { ctx in
                            Text(CallView.format(ctx.date.timeIntervalSince(start))
                                 + (call.onHold ? " · On hold" : "") + (call.recording ? " · Recording" : ""))
                                .monospacedDigit()
                        }
                    } else {
                        Text(call.statusText)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            status
            if call.phase == .active && !call.voicemail { moreMenu(call) }
            Button(action: openWindow) {
                Image(systemName: "plus.circle").font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Open the window")
            if call.phase != .incoming {
                Button { engine.callPanelHidden = true } label: {
                    Image(systemName: "minus.circle").font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Put the panel away; the call goes on. Show it again from the menu bar icon.")
            }
        }
    }

    /// Recording at one click (during a call), and the VPN at a glance; their help says more.
    @ViewBuilder
    private var status: some View {
        HStack(spacing: 6) {
            if let call = engine.call, isTalking(call) {
                Button { engine.toggleRecording() } label: {
                    Image(systemName: call.recording ? "record.circle.fill" : "record.circle")
                        .foregroundStyle(call.recording ? Color.red : Color.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(!engine.canRecord)
                .help(call.recording ? "Recording: click to stop" : "Record the call")
            }
            if engine.vpnSettings.enabled {
                switch engine.vpnState {
                case .connected(let ip):
                    Image(systemName: "lock.shield.fill").foregroundStyle(.green).help("VPN connected (\(ip))")
                case .connecting:
                    Image(systemName: "lock.shield").foregroundStyle(.orange).help("VPN connecting…")
                case .failed, .off:
                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red).help("VPN not connected")
                }
            }
        }
        .font(.callout)
    }

    private func isTalking(_ call: ActiveCall) -> Bool {
        call.phase != .incoming && !call.voicemail && !call.voicemailPending
    }

    /// The call's own volume, as in the window: the speaker icon switches 100% / 15%.
    private func volume(_ call: ActiveCall) -> some View {
        HStack(spacing: 8) {
            Button {
                engine.setVolume(call.volume < 1 ? 1 : CallView.lowVolume, for: call.id)
            } label: {
                Image(systemName: call.volume < 0.01 ? "speaker.slash.fill"
                      : call.volume < 0.34 ? "speaker.wave.1.fill"
                      : call.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            .help(call.volume < 1 ? "Back to full volume" : "Lower this call to \(Int(CallView.lowVolume * 100))%")
            Slider(value: Binding(get: { Double(call.volume) }, set: { engine.setVolume(Float($0), for: call.id) }),
                   in: 0...1)
                .controlSize(.small)
            Text("\(Int((call.volume * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .font(.callout)
        .foregroundStyle(call.volume < 1 ? Color.orange : Color.secondary)
    }

    /// Like the window's More menu: devices, hold, the recordings folder (recording itself
    /// has its own button).
    private func moreMenu(_ call: ActiveCall) -> some View {
        Menu {
            AudioDevicePickers(engine: engine)
            Divider()
            Button(call.onHold ? "Resume" : "Hold") { engine.toggleHold() }
                .disabled(!engine.canHold)
            Button("Show Recordings") { engine.showRecordings() }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Audio devices, hold, recordings")
    }
}

private struct PanelButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .controlSize(.regular)
    }
}
