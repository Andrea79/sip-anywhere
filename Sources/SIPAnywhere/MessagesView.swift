import AVFoundation
import SwiftUI

/// The answering machine's messages, newest first: play, delete, show in Finder.
struct MessagesView: View {
    @Environment(SIPEngine.self) private var engine
    @State private var player: AVAudioPlayer?
    @State private var playing: String?
    /// The message waiting for the user to confirm its deletion.
    @State private var toDelete: VoiceMessage?

    var body: some View {
        VStack(spacing: 0) {
            if engine.voiceMessages.isEmpty {
                Spacer()
                Text("No messages").foregroundStyle(.secondary)
                Text(engine.settings.answeringMachine
                     ? "With Do Not Disturb on, the answering machine answers after \(engine.settings.amDelay) s."
                     : "The answering machine is off (Settings › Answering machine).")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                Spacer()
            } else {
                List(engine.voiceMessages) { m in
                    HStack {
                        Button { toggle(m) } label: {
                            Image(systemName: playing == m.id ? "stop.circle.fill" : "play.circle.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.borderless)
                        .help(playing == m.id ? "Stop" : "Play")
                        VStack(alignment: .leading) {
                            Text(title(m)).fontWeight(engine.heardMessages.contains(m.id) ? .regular : .bold)
                            Text(m.date, format: .dateTime.day().month().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(CallView.format(m.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.url]) }
                        Button("Delete…", role: .destructive) { toDelete = m }
                    }
                }
            }
            Divider()
            HStack {
                Button("Show in Finder") { engine.showVoicemail() }
                Spacer()
                Text("Right-click a message to delete it").font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .confirmationDialog("Delete this message?",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            presenting: toDelete) { m in
            Button("Move to Trash", role: .destructive) { delete(m) }
            Button("Cancel", role: .cancel) {}
        } message: { m in
            Text("\(title(m)), \(m.date.formatted(.dateTime.day().month().hour().minute())). "
                 + "The recording goes to the Trash, where it can still be recovered.")
        }
        .onAppear { engine.refreshVoiceMessages() }
        .onDisappear { player?.stop() }
    }

    private func title(_ m: VoiceMessage) -> String {
        engine.contactName(for: m.caller) ?? m.caller
    }

    private func toggle(_ m: VoiceMessage) {
        if playing == m.id {
            player?.stop()
            playing = nil
            return
        }
        player?.stop()
        guard let p = try? AVAudioPlayer(contentsOf: m.url) else { return }
        player = p
        p.play()
        playing = m.id
        engine.markHeard(m)
        let id = m.id
        DispatchQueue.main.asyncAfter(deadline: .now() + p.duration + 0.2) {
            if playing == id && !(player?.isPlaying ?? false) { playing = nil }
        }
    }

    private func delete(_ m: VoiceMessage) {
        if playing == m.id { player?.stop(); playing = nil }
        engine.deleteMessage(m)
    }
}
