import CoreAudio
import SwiftUI

/// An audio device as macOS reports it. Listed straight from Core Audio so the
/// choice is available even while the SIP stack is not running.
struct SystemAudioDevice: Hashable, Identifiable {
    var id: String { name }
    let name: String
    let hasInput: Bool
    let hasOutput: Bool

    static func all() -> [SystemAudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            // macOS's own helper for voice processing comes and goes during calls: not a
            // device anyone can choose.
            guard let name = name(of: id), !name.hasPrefix("VPAUAggregateAudioDevice") else { return nil }
            let input = hasStreams(id, kAudioObjectPropertyScopeInput)
            let output = hasStreams(id, kAudioObjectPropertyScopeOutput)
            return input || output ? SystemAudioDevice(name: name, hasInput: input, hasOutput: output) : nil
        }
    }

    static func name(of id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func hasStreams(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }
}

/// Tells when audio devices are plugged in or out, or the system default microphone
/// or speaker changes (e.g. AirPods connecting).
enum AudioHardwareMonitor {
    /// `handler` runs on the main queue.
    static func start(_ handler: @escaping () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in
                handler()
            }
        }
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }
}

/// Microphone and speaker pickers, used in the Audio menu, the in-call ⋮ menu
/// and the settings. An empty name means the system default device.
struct AudioDevicePickers: View {
    var engine: SIPEngine

    var body: some View {
        AudioDevicePicker(engine: engine, input: true, title: "Microphone")
        AudioDevicePicker(engine: engine, input: false, title: "Speaker")
    }
}

/// The microphone or speaker menu. The tick is on the device in use: the chosen one,
/// or "System default" while the chosen one is not connected (the choice is kept,
/// and used again when it returns).
struct AudioDevicePicker: View {
    var engine: SIPEngine
    let input: Bool
    var title = ""

    var body: some View {
        let names = engine.systemAudioDevices.filter { input ? $0.hasInput : $0.hasOutput }.map(\.name)
        let key: ReferenceWritableKeyPath<SIPEngine, String> = input ? \.inputDeviceName : \.outputDeviceName
        let chosen = engine[keyPath: key]
        Picker(title.isEmpty ? (input ? "Microphone" : "Speaker") : title,
               selection: Binding(get: { names.contains(chosen) ? chosen : "" },
                                  set: { engine[keyPath: key] = $0.hasPrefix("missing:") ? String($0.dropFirst(8)) : $0 })) {
            Text("System default").tag("")
            ForEach(names, id: \.self) { Text($0).tag($0) }
            if !chosen.isEmpty && !names.contains(chosen) {
                Text("\(chosen) (not connected; used again when it returns)").tag("missing:" + chosen)
            }
        }
    }
}
