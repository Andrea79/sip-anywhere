import AVFoundation
import Foundation

/// A message left on the answering machine: a WAV file in Music › <app> › Voicemail,
/// named "yyyy-MM-dd HH.mm.ss <caller>.wav".
struct VoiceMessage: Identifiable, Hashable {
    var url: URL
    var date: Date
    var caller: String
    var duration: TimeInterval
    var id: String { url.lastPathComponent }
}

/// Files of the answering machine and of call recordings, and the greeting the
/// machine plays: spoken by macOS from a text, or recorded by the user, always
/// followed by a beep. All audio is 16 kHz mono 16-bit WAV, PJSIP's own rate.
enum AnsweringMachine {
    static let sampleRate = 16_000.0

    // MARK: Folders

    /// Music › <app name>: holds the Voicemail and Recordings folders.
    static var musicFolder: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true)
    }

    static var voicemailFolder: URL { folder("Voicemail") }

    /// Call recordings. Recordings saved before this folder existed (directly in the
    /// Music folder) are moved into it.
    static var recordingsFolder: URL {
        let dir = folder("Recordings")
        let fm = FileManager.default
        if let loose = try? fm.contentsOfDirectory(at: musicFolder, includingPropertiesForKeys: nil) {
            for f in loose where f.pathExtension.lowercased() == "wav" {
                try? fm.moveItem(at: f, to: dir.appendingPathComponent(f.lastPathComponent))
            }
        }
        return dir
    }

    private static func folder(_ name: String) -> URL {
        let dir = musicFolder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// "2026-10-15 21.40.12 +15551234567.wav" in the given folder.
    static func newFile(in folder: URL, caller: String) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let who = caller.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return folder.appendingPathComponent("\(f.string(from: Date())) \(who).wav")
    }

    static func messages() -> [VoiceMessage] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let files = (try? FileManager.default.contentsOfDirectory(at: voicemailFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "wav" }.compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.count > 20, let date = f.date(from: String(name.prefix(19))) else { return nil }
            let caller = String(name.dropFirst(20))
            return VoiceMessage(url: url, date: date, caller: caller, duration: duration(of: url))
        }
        .sorted { $0.date > $1.date }
    }

    /// Runs `then` once the recording at `url` is complete, i.e. its WAV header gives a
    /// length (PJSIP writes it when the recorder is removed, shortly after the call
    /// ends), or after 3 s for a message that is really empty.
    @MainActor
    static func whenComplete(_ url: URL, then: @escaping () -> Void, tries: Int = 15) {
        if tries <= 0 || duration(of: url) > 0 {
            then()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            whenComplete(url, then: then, tries: tries - 1)
        }
    }

    static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: Greeting

    private static var greetingFolder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true)
            .appendingPathComponent("Greeting", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// What the machine plays: the greeting followed by the beep.
    static var greetingURL: URL { greetingFolder.appendingPathComponent("greeting.wav") }
    /// The user's own recorded greeting (without the beep).
    static var recordedGreetingURL: URL { greetingFolder.appendingPathComponent("recorded.wav") }
    private static var spokenGreetingURL: URL { greetingFolder.appendingPathComponent("spoken.wav") }

    /// Default greetings by language: with the first name of the Mac's user, and without.
    private static let greetings: [String: (named: String, unnamed: String)] = [
        "en": ("You have reached %@'s voicemail. Please leave a message after the tone.",
               "You have reached the voicemail. Please leave a message after the tone."),
        "it": ("Risponde la segreteria di %@. Lasciate un messaggio dopo il segnale.",
               "Risponde la segreteria telefonica. Lasciate un messaggio dopo il segnale."),
        "fr": ("Vous êtes sur la messagerie de %@. Laissez un message après le bip.",
               "Vous êtes sur la messagerie. Laissez un message après le bip."),
        "de": ("Hier ist die Mailbox von %@. Bitte hinterlassen Sie eine Nachricht nach dem Signalton.",
               "Hier ist die Mailbox. Bitte hinterlassen Sie eine Nachricht nach dem Signalton."),
        "es": ("Ha llamado al buzón de voz de %@. Deje un mensaje después de la señal.",
               "Ha llamado al buzón de voz. Deje un mensaje después de la señal."),
        "pt": ("Ligou para o correio de voz de %@. Deixe uma mensagem após o sinal.",
               "Ligou para o correio de voz. Deixe uma mensagem após o sinal."),
    ]

    /// The languages with a default greeting, with their own names.
    static let greetingLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("it", "Italiano"), ("fr", "Français"),
        ("de", "Deutsch"), ("es", "Español"), ("pt", "Português"),
    ]

    static func languageName(_ code: String) -> String {
        greetingLanguages.first { $0.code == code }?.name ?? code
    }

    /// The Mac's first preferred language that has a greeting, else English.
    static let systemGreetingLanguage: String = {
        Locale.preferredLanguages.lazy.map { String($0.prefix(2)) }.first { greetings[$0] != nil } ?? "en"
    }()

    /// The language of the greeting setting: "" (automatic) is the Mac's language.
    static func greetingLanguage(_ setting: String) -> String {
        greetings[setting] != nil ? setting : systemGreetingLanguage
    }

    /// The default greeting in a language, with the first name of the Mac's user.
    static func defaultGreetingText(language: String) -> String {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        let g = greetings[language] ?? greetings["en"]!
        return first.isEmpty ? g.unnamed : g.named.replacingOccurrences(of: "%@", with: first)
    }

    /// A text that is one of the default greetings (as earlier versions saved it), not
    /// one the user wrote.
    static func isDefaultGreeting(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return greetingLanguages.contains { defaultGreetingText(language: $0.code) == t }
    }

    /// Voices of macOS's `say` for a language: first Apple's natural voices
    /// (com.apple.voice.*: compact, enhanced, premium) in that language, the Mac's own
    /// region first and best quality first, then other natural voices, then the older
    /// synthetic and novelty voices.
    static func voices(language: String) -> [String] {
        let region = Locale.preferredLanguages.first { $0.hasPrefix(language + "-") }
        func place(_ v: NaturalVoice) -> Int {
            v.language == region ? 0 : v.language.hasPrefix(language + "-") ? 1 : 2
        }
        let natural = voiceCatalog.natural
            .sorted { (place($0), -$0.quality) < (place($1), -$1.quality) }
            .map(\.name)
        var seen = Set<String>()
        return (natural + voiceCatalog.say).filter { seen.insert($0).inserted }
    }

    /// The most natural voice in a language.
    static func defaultVoice(language: String) -> String { voices(language: language).first ?? "" }

    private struct NaturalVoice {
        let name: String        // as `say` knows it
        let language: String    // e.g. "it-IT"
        let quality: Int
    }

    /// The voices, listed once (it runs `say`), then kept: views ask on every update.
    private static let voiceCatalog: (say: [String], natural: [NaturalVoice]) = {
        guard let out = run("/usr/bin/say", ["-v", "?"]) else { return ([], []) }
        var sayNames: [String] = []
        for line in out.split(separator: "\n") {
            guard let r = line.range(of: #"\s+[a-z]{2,3}_[A-Z0-9]{2,3}\s"#, options: .regularExpression) else { continue }
            sayNames.append(line[..<r.lowerBound].trimmingCharacters(in: .whitespaces))
        }
        let available = Set(sayNames)
        let natural = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.identifier.hasPrefix("com.apple.voice.") }
            .compactMap { v -> NaturalVoice? in
                let suffix = v.quality == .premium ? " (Premium)" : v.quality == .enhanced ? " (Enhanced)" : ""
                let name = available.contains(v.name + suffix) ? v.name + suffix : v.name
                guard available.contains(name) else { return nil }
                return NaturalVoice(name: name, language: v.language, quality: v.quality.rawValue)
            }
        return (sayNames, natural)
    }()

    /// Builds greeting.wav from the settings, with the defaults filled in: only the beep,
    /// or the greeting (the text, or the default one of the greeting's language, spoken
    /// with the chosen or the most natural voice; or the user's recording) and the beep.
    @discardableResult
    static func prepareGreeting(from s: AccountSettings) -> Bool {
        if s.amNoGreeting {
            return writeWAV(silence(0.3) + beep() + silence(0.1), to: greetingURL)
        }
        let language = greetingLanguage(s.amGreetingLanguage)
        let own = s.amGreetingText.trimmingCharacters(in: .whitespacesAndNewlines)
        return prepareGreeting(spoken: s.amSpokenGreeting,
                               text: own.isEmpty ? defaultGreetingText(language: language) : own,
                               voice: s.amVoice.isEmpty ? defaultVoice(language: language) : s.amVoice)
    }

    /// Builds greeting.wav from the settings (spoken text or the recording) plus the
    /// beep. Runs `say` for a spoken greeting, so call it off the main thread.
    @discardableResult
    static func prepareGreeting(spoken: Bool, text: String, voice: String) -> Bool {
        var source: URL?
        if spoken {
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var args = ["-o", spokenGreetingURL.path, "--file-format=WAVE", "--data-format=LEI16@16000"]
            if !voice.isEmpty { args = ["-v", voice] + args }
            try? FileManager.default.removeItem(at: spokenGreetingURL)
            if !words.isEmpty, run("/usr/bin/say", args + [words]) != nil,
               FileManager.default.fileExists(atPath: spokenGreetingURL.path) {
                source = spokenGreetingURL
            }
        } else if FileManager.default.fileExists(atPath: recordedGreetingURL.path) {
            source = recordedGreetingURL
        }
        var samples = source.map(readMono16k) ?? []
        samples += silence(0.3) + beep() + silence(0.1)
        return writeWAV(samples, to: greetingURL)
    }

    /// A greeting is needed now (a call is being answered) but none was prepared.
    static func ensureGreeting() {
        if !FileManager.default.fileExists(atPath: greetingURL.path) {
            _ = writeWAV(silence(0.3) + beep() + silence(0.1), to: greetingURL)
        }
    }

    // MARK: Audio helpers

    private static func silence(_ seconds: Double) -> [Int16] {
        [Int16](repeating: 0, count: Int(sampleRate * seconds))
    }

    /// 0.4 s at 1 kHz, with short ramps so that it does not click.
    private static func beep() -> [Int16] {
        let n = Int(sampleRate * 0.4), ramp = sampleRate * 0.01
        return (0..<n).map { i in
            let gain = min(1, Double(i) / ramp, Double(n - i) / ramp) * 0.5
            return Int16(sin(2 * .pi * 1000 * Double(i) / sampleRate) * gain * 32767)
        }
    }

    /// Any audio file as 16 kHz mono 16-bit samples.
    private static func readMono16k(_ url: URL) -> [Int16] {
        guard let file = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil
        else { return [] }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * sampleRate / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var fed = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard let data = output.floatChannelData?[0] else { return [] }
        return (0..<Int(output.frameLength)).map { Int16(max(-1, min(1, data[$0])) * 32767) }
    }

    /// A plain RIFF/WAVE file (PCM, 16 kHz, mono, 16-bit), as PJSIP's player expects.
    private static func writeWAV(_ samples: [Int16], to url: URL) -> Bool {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2), rate = UInt32(sampleRate)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { p in
            for s in p { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        }
        return (try? d.write(to: url, options: .atomic)) != nil
    }

    private static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: out, as: UTF8.self) : nil
    }
}

/// Records the user's own greeting from the microphone (16 kHz mono WAV).
@MainActor
@Observable
final class GreetingRecorder {
    private(set) var isRecording = false
    private var recorder: AVAudioRecorder?

    func toggle() {
        if let r = recorder {
            r.stop()
            recorder = nil
            isRecording = false
            return
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AnsweringMachine.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        guard let r = try? AVAudioRecorder(url: AnsweringMachine.recordedGreetingURL, settings: settings),
              r.record() else { return }
        recorder = r
        isRecording = true
    }
}
