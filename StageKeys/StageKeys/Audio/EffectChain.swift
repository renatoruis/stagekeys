import AVFoundation
import AudioKit
import AudioToolbox
import Foundation
import SoundpipeAudioKit

final class EffectChain {
    let ladder = EffectChain.makeLadder()
    let filter: AVAudioUnitEQ
    let compressor: AVAudioUnit?
    let reverb = ZitaReverb(Mixer(), predelay: 20, midReleaseTime: 2.5, dampingFrequency: 6_000, dryWetMix: 0)
    private let rotaryNode: AVAudioUnit?
    private let rotary: RotaryAudioUnit?

    init() {
        filter = AVAudioUnitEQ(numberOfBands: 2)
        filter.bands[0].filterType = .lowShelf
        filter.bands[0].frequency = 220
        filter.bands[1].filterType = .highShelf
        filter.bands[1].frequency = 5_000
        for band in filter.bands {
            band.gain = 0
            band.bypass = true
        }
        reverb.stop()
        compressor = Self.makeCompressor()
        let made = Self.makeRotary()
        rotaryNode = made?.node
        rotary = made?.unit
    }

    func install(on output: MotorOutput, from source: AVAudioNode, to target: AVAudioNode, format: AVAudioFormat?, sends: [AVAudioConnectionPoint] = []) {
        output.attach(ladder.avAudioNode)
        output.attach(filter)
        output.attach(reverb.avAudioNode)
        if let compressor { output.attach(compressor) }
        if let rotaryNode { output.attach(rotaryNode) }
        wire(on: output, from: source, to: target, format: format, sends: sends)
    }

    /// Connects (or reconnects, e.g. after a sample-rate change) source → chain → target.
    /// `sends` also receive the source, before the chain.
    func wire(on output: MotorOutput, from source: AVAudioNode, to target: AVAudioNode, format: AVAudioFormat?, sends: [AVAudioConnectionPoint] = []) {
        for node in [source, rotaryNode, ladder.avAudioNode, filter, compressor, reverb.avAudioNode].compactMap({ $0 }) {
            output.engine.disconnectNodeOutput(node)
        }
        let head: AVAudioNode = rotaryNode ?? ladder.avAudioNode
        output.engine.connect(source, to: [AVAudioConnectionPoint(node: head, bus: 0)] + sends, fromBus: 0, format: format)
        if let rotaryNode {
            output.connect(rotaryNode, to: ladder.avAudioNode, format: format)
        }
        output.connect(ladder.avAudioNode, to: filter, format: format)
        if let compressor {
            output.connect(filter, to: compressor, format: format)
            output.connect(compressor, to: reverb.avAudioNode, format: format)
        } else {
            output.connect(filter, to: reverb.avAudioNode, format: format)
        }
        output.connect(reverb.avAudioNode, to: target, format: format)
    }

    static func makeLadder() -> MoogLadder {
        let ladder = MoogLadder(Mixer(), cutoffFrequency: 18_000, resonance: 0)
        ladder.stop()
        return ladder
    }

    /// Moog ladder, 24 dB/oct; fully open bypasses it. `resonance` 0…1 maps below self-oscillation.
    static func applyCutoff(_ ladder: MoogLadder, _ cutoff: Double, resonance: Double? = nil) {
        let open = cutoff >= 0.98
        open ? ladder.stop() : ladder.start()
        guard !open else { return }
        ladder.cutoffFrequency = AUValue(200.0 * pow(18_000.0 / 200.0, min(1, max(0, cutoff))))
        ladder.resonance = AUValue(0.9 * min(1, max(0, resonance ?? 0)))
    }

    func apply(cutoff: Double, resonance: Double?, compressor amount: Double, reverb wet: Double, rotary mode: Int, low: Double, high: Double) {
        Self.applyCutoff(ladder, cutoff, resonance: resonance)
        let filtering = cutoff < 0.98
        filter.globalGain = filtering ? Float(6 * min(1, max(0, resonance ?? 0))) : 0
        for (band, value) in [(filter.bands[0], low), (filter.bands[1], high)] {
            let gain = Float((min(1, max(0, value)) - 0.5) * 24)
            band.gain = gain
            band.bypass = abs(gain) < 0.25
        }
        reverb.dryWetMix = AUValue(min(1, max(0, wet)) * 0.8)
        wet < 0.001 ? reverb.stop() : reverb.start()
        rotary?.setSpeed(mode)
        if let compressor {
            Self.applyCompressor(compressor, amount: amount)
        }
    }

    private static func makeRotary() -> (node: AVAudioUnit, unit: RotaryAudioUnit)? {
        RotaryAudioUnit.register()
        let description = RotaryAudioUnit.component
        let semaphore = DispatchSemaphore(value: 0)
        var created: AVAudioUnit?
        AVAudioUnit.instantiate(with: description, options: []) { unit, _ in
            created = unit
            semaphore.signal()
        }
        semaphore.wait()
        guard let created, let unit = created.auAudioUnit as? RotaryAudioUnit else { return nil }
        return (created, unit)
    }

    private static func makeCompressor() -> AVAudioUnit? {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let semaphore = DispatchSemaphore(value: 0)
        var created: AVAudioUnit?
        AVAudioUnit.instantiate(with: description, options: []) { unit, _ in
            created = unit
            semaphore.signal()
        }
        semaphore.wait()
        if let created { applyCompressor(created, amount: 0) }
        return created
    }

    private static func applyCompressor(_ unit: AVAudioUnit, amount: Double) {
        let audioUnit = unit.audioUnit
        var bypass: UInt32 = amount < 0.02 ? 1 : 0
        AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_BypassEffect,
            kAudioUnitScope_Global,
            0,
            &bypass,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard bypass == 0 else { return }
        let clamped = Float(min(1, max(0, amount)))
        AudioUnitSetParameter(audioUnit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -36 * clamped, 0)
        AudioUnitSetParameter(audioUnit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 5 - 4 * clamped, 0)
        AudioUnitSetParameter(audioUnit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.002, 0)
        AudioUnitSetParameter(audioUnit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.08, 0)
        AudioUnitSetParameter(audioUnit, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 24 * clamped, 0)
    }
}

final class RotaryAudioUnit: AUAudioUnit {
    static let component = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x73726F74,
        componentManufacturer: 0x73746B73,
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static var registered = false
    static func register() {
        guard !registered else { return }
        registered = true
        AUAudioUnit.registerSubclass(
            RotaryAudioUnit.self,
            as: component,
            name: "StageKeys Rotary",
            version: 1
        )
    }

    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var delay = [Float](repeating: 0, count: 8192)
    private var write = 0
    private var phase = 0.0
    private var currentHz = 0.0
    private var targetHz = 0.0
    private var sampleRate = 44_100.0

    func setSpeed(_ mode: Int) {
        targetHz = mode == 0 ? 0 : 6.6
    }

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray {
        AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
    }

    override var outputBusses: AUAudioUnitBusArray {
        AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        sampleRate = outputBus.format.sampleRate
    }

    override var canProcessInPlace: Bool { true }

    override var internalRenderBlock: AUInternalRenderBlock {
        { [self] _, timestamp, frameCount, _, outputData, _, pull in
            guard let pull else { return kAudioUnitErr_NoConnection }
            var flags = AudioUnitRenderActionFlags()
            let status = pull(&flags, timestamp, frameCount, 0, outputData)
            if status != noErr { return status }
            self.process(outputData, frames: Int(frameCount))
            return noErr
        }
    }

    private func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard frames > 0, let left = channel(buffers, 0, frames) else { return }
        let right = buffers.count > 1 ? channel(buffers, 1, frames) : nil
        let rate = sampleRate
        let slew = 1 - exp(-1 / (rate * 0.55))
        let mask = delay.count - 1
        for index in 0..<frames {
            currentHz += (targetHz - currentHz) * slew
            let spinning = currentHz > 0.05 || targetHz > 0
            let sampleL = left[index]
            let sampleR = right?[index] ?? sampleL
            delay[write] = (sampleL + sampleR) * 0.5
            if !spinning {
                write = (write + 1) & mask
                continue
            }
            phase += currentHz / rate
            if phase > 1 { phase -= 1 }
            let angle = phase * 2 * .pi
            let lfoL = sin(angle)
            let lfoR = sin(angle + 2.2)
            let lagL = Int(rate * (0.0014 + 0.002 * (0.5 + 0.5 * lfoL)))
            let lagR = Int(rate * (0.0014 + 0.002 * (0.5 + 0.5 * lfoR)))
            let wetL = delay[(write - max(1, lagL)) & mask]
            let wetR = delay[(write - max(1, lagR)) & mask]
            write = (write + 1) & mask
            let ampL = Float(0.42 + 0.58 * (0.5 + 0.5 * lfoL))
            let ampR = Float(0.42 + 0.58 * (0.5 + 0.5 * lfoR))
            left[index] = sampleL * 0.28 + wetL * ampL
            right?[index] = sampleR * 0.28 + wetR * ampR
        }
    }

    private func channel(_ buffers: UnsafeMutableAudioBufferListPointer, _ index: Int, _ frames: Int) -> UnsafeMutablePointer<Float>? {
        guard buffers.indices.contains(index), let data = buffers[index].mData else { return nil }
        let available = Int(buffers[index].mDataByteSize) / MemoryLayout<Float>.size
        guard available >= frames else { return nil }
        return data.assumingMemoryBound(to: Float.self)
    }
}
