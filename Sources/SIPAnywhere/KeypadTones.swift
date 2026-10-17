import AVFoundation
import os

/// The standard telephone keypad tones (DTMF, ITU-T Q.23: one low and one high
/// frequency per key), played while dialling. Output only: the microphone stays off.
/// During a call the tones come from the SIP stack instead (sip_play_keypad_tone).
@MainActor
final class KeypadTonePlayer {
    fileprivate struct Tone: Sendable {
        var low = 0.0, high = 0.0           // Hz
        var phaseLow = 0.0, phaseHigh = 0.0
        var remaining = 0, total = 0        // samples
    }

    private static let frequencies: [Character: (Double, Double)] = [
        "1": (697, 1209), "2": (697, 1336), "3": (697, 1477),
        "4": (770, 1209), "5": (770, 1336), "6": (770, 1477),
        "7": (852, 1209), "8": (852, 1336), "9": (852, 1477),
        "*": (941, 1209), "0": (941, 1336), "#": (941, 1477),
        "+": (941, 1336),                   // "+" is a long press of 0
    ]
    private static let duration = 0.12      // seconds
    private static let level = 0.12         // of full scale, per frequency

    private let engine = AVAudioEngine()
    private let state = OSAllocatedUnfairLock(initialState: Tone())
    private var sampleRate = 48_000.0
    private var started = false
    private var idleTimer: Timer?

    func play(_ key: Character) {
        guard let (low, high) = Self.frequencies[key] else { return }
        if !started { start() }
        guard started else { return }
        let samples = Int(sampleRate * Self.duration)
        state.withLock { $0 = Tone(low: low, high: high, remaining: samples, total: samples) }
        if !engine.isRunning { try? engine.start() }
        // Release the output device shortly after the last key.
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.pause() }
        }
    }

    private func start() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if rate > 0 { sampleRate = rate }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let source = Self.makeSource(format: format, sampleRate: sampleRate, state: state, level: Self.level)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        started = true
    }

    /// The render callback runs on the audio thread: built outside the main actor.
    nonisolated private static func makeSource(format: AVAudioFormat, sampleRate sr: Double,
                                               state: OSAllocatedUnfairLock<Tone>,
                                               level: Double) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            state.withLock { t in
                let fade = sr * 0.005       // 5 ms ramps, so the tone does not click
                for i in 0..<Int(frameCount) {
                    guard t.remaining > 0 else { data[i] = 0; continue }
                    let done = Double(t.total - t.remaining)
                    let gain = min(1, done / fade, Double(t.remaining) / fade) * level
                    data[i] = Float((sin(t.phaseLow) + sin(t.phaseHigh)) * gain)
                    t.phaseLow = (t.phaseLow + 2 * .pi * t.low / sr).truncatingRemainder(dividingBy: 2 * .pi)
                    t.phaseHigh = (t.phaseHigh + 2 * .pi * t.high / sr).truncatingRemainder(dividingBy: 2 * .pi)
                    t.remaining -= 1
                }
            }
            return noErr
        }
    }
}
