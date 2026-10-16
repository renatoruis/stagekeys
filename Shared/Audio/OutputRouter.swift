import AVFoundation
import AudioToolbox
import CoreAudio

struct AudioDevice: Identifiable, Equatable {
    var uid: String
    var audioID: AudioDeviceID
    var name: String
    var outputChannels: Int

    var id: String { uid }
}

struct ChannelOption: Identifiable, Equatable {
    var id: String
    var title: String
    var pick: ChannelPick
}

final class MotorOutput {
    let motor: Motor
    let engine = AVAudioEngine()
    let mixer = AVAudioMixerNode()
    private var inputDisabled = false
    private var mixerConnected = false

    init(motor: Motor) {
        self.motor = motor
        engine.attach(mixer)
    }

    func attach(_ node: AVAudioNode) {
        engine.attach(node)
    }

    func connect(_ node: AVAudioNode, to target: AVAudioNode, format: AVAudioFormat?) {
        engine.connect(node, to: target, format: format)
    }

    func reconnect(_ node: AVAudioNode, to target: AVAudioNode, format: AVAudioFormat) {
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: target, format: format)
    }

    func reconnect(_ node: AVAudioNode, format: AVAudioFormat) {
        reconnect(node, to: mixer, format: format)
    }

    fileprivate func apply(device: AudioDevice, pick: ChannelPick, bufferFrames: UInt32) throws {
        if engine.isRunning {
            engine.stop()
        }
        guard let audioUnit = engine.outputNode.audioUnit else {
            throw RouterError.noOutput
        }
        if !inputDisabled {
            var enabled: UInt32 = 0
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &enabled,
                UInt32(MemoryLayout<UInt32>.size)
            )
            inputDisabled = true
        }
        var deviceID = device.audioID
        let deviceStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard deviceStatus == noErr else { throw RouterError.device(deviceStatus) }

        if mixerConnected {
            engine.disconnectNodeOutput(mixer)
        }
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)
        mixerConnected = true
        mixer.pan = pick.kind == .right ? 1 : (pick.kind == .left || pick.kind == .mono ? -1 : 0)
        OutputRouter.setBufferFrames(bufferFrames, device: device.audioID)
        engine.prepare()
        OutputRouter.applyChannelMap(pick, channels: device.outputChannels, audioUnit: audioUnit)
        try engine.start()
        OutputRouter.applyChannelMap(pick, channels: device.outputChannels, audioUnit: audioUnit)
    }
}

final class OutputRouter {
    private(set) var devices: [AudioDevice] = []
    private var outputs: [Motor: MotorOutput] = [:]
    var bufferFrames: UInt32 = 128
    var onChange: (() -> Void)?
    private(set) var lastError: String?
    private var listenerInstalled = false

    init() {
        for motor in Motor.allCases {
            outputs[motor] = MotorOutput(motor: motor)
        }
        refreshDevices()
        installListener()
    }

    func output(for motor: Motor) -> MotorOutput {
        outputs[motor]!
    }

    func refreshDevices() {
        devices = Self.outputDevices()
        onChange?()
    }

    func device(uid: String?) -> AudioDevice? {
        if let uid, let match = devices.first(where: { $0.uid == uid }) {
            return match
        }
        return devices.first { $0.uid == Self.defaultOutputUID() } ?? devices.first
    }

    func apply(route: MotorRoute, to motor: Motor) {
        guard let output = outputs[motor], let device = device(uid: route.deviceUID) else {
            lastError = "No output device for \(motor.title)."
            onChange?()
            return
        }
        do {
            try output.apply(device: device, pick: route.pick, bufferFrames: bufferFrames)
            lastError = nil
        } catch {
            lastError = "Could not open \(device.name) for \(motor.title)."
        }
        onChange?()
    }

    func applyBuffer(_ frames: Int) {
        let allowed = [64, 128, 256]
        bufferFrames = UInt32(allowed.contains(frames) ? frames : 128)
    }

    func nominalSampleRate(uid: String?) -> Double {
        guard let id = device(uid: uid)?.audioID else { return 44_100 }
        return Self.nominalSampleRate(id)
    }

    func channelOptions(for device: AudioDevice?) -> [ChannelOption] {
        let channels = max(device?.outputChannels ?? 2, 1)
        if channels == 1 {
            return [ChannelOption(id: "mono-0", title: "Channel 1", pick: ChannelPick(kind: .mono, channel: 0))]
        }
        var options = [
            ChannelOption(id: "stereo", title: "Stereo (1–2)", pick: .stereo),
            ChannelOption(id: "left", title: "Left", pick: .left),
            ChannelOption(id: "right", title: "Right", pick: .right),
        ]
        guard channels > 2 else { return options }
        var index = 0
        while index + 1 < channels {
            options.append(ChannelOption(
                id: "pair-\(index)",
                title: "Channels \(index + 1)–\(index + 2)",
                pick: ChannelPick(kind: .pair, channel: index)
            ))
            index += 2
        }
        for channel in 0..<channels {
            options.append(ChannelOption(
                id: "mono-\(channel)",
                title: "Channel \(channel + 1)",
                pick: ChannelPick(kind: .mono, channel: channel)
            ))
        }
        return options
    }

    private func installListener() {
        guard !listenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.refreshDevices()
        }
        listenerInstalled = true
    }

    fileprivate static func applyChannelMap(_ pick: ChannelPick, channels: Int, audioUnit: AudioUnit) {
        let count = max(channels, 1)
        var map = [Int32](repeating: -1, count: count)
        switch pick.kind {
        case .stereo:
            map[0] = 0
            if count > 1 { map[1] = 1 }
        case .left:
            map[0] = 0
        case .right:
            if count > 1 { map[1] = 1 } else { map[0] = 0 }
        case .mono:
            let channel = min(max(0, pick.channel), count - 1)
            map[channel] = 0
        case .pair:
            let channel = min(max(0, pick.channel), count - 1)
            map[channel] = 0
            if channel + 1 < count { map[channel + 1] = 1 }
        }
        map.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_ChannelMap,
                kAudioUnitScope_Output,
                0,
                base,
                UInt32(count * MemoryLayout<Int32>.size)
            )
        }
    }

    private static func nominalSampleRate(_ device: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(44_100)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else {
            return 44_100
        }
        return rate
    }

    fileprivate static func setBufferFrames(_ frames: UInt32, device: AudioDeviceID) {
        var rangeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange(mMinimum: 0, mMaximum: 4096)
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        if AudioObjectGetPropertyData(device, &rangeAddress, 0, nil, &rangeSize, &range) == noErr {
            let clamped = min(max(Double(frames), range.mMinimum), range.mMaximum)
            var value = UInt32(clamped)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        }
    }

    private static func outputDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let channels = outputChannelCount(id)
            guard channels > 0, let uid = copyString(kAudioDevicePropertyDeviceUID, from: id) else { return nil }
            let name = copyString(kAudioDevicePropertyDeviceNameCFString, from: id) ?? uid
            return AudioDevice(uid: uid, audioID: id, name: name, outputChannels: channels)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return copyString(kAudioDevicePropertyDeviceUID, from: device)
    }

    private static func outputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func copyString(_ selector: AudioObjectPropertySelector, from object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

enum RouterError: Error {
    case noOutput
    case device(OSStatus)
}
