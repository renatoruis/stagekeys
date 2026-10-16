import AVFoundation
import AudioToolbox
import Foundation

/// The Keys motor: four SF2 parts, each with its own effect chain, summed into a peak limiter.
final class SF2Engine {
    static let partCount = KeySlot.slotCount

    struct Stats {
        var voices: [Int] = Array(repeating: 0, count: SF2Engine.partCount)
        /// Fraction of the buffer period spent rendering all parts.
        var load: Double = 0
        /// Keys held down; notes ringing on the sustain pedal are not included.
        var keys: [Set<Int>] = Array(repeating: [], count: SF2Engine.partCount)
    }

    /// Parts may listen to different inputs: any held pedal, and the first wheel away from rest.
    struct Controllers: Equatable {
        var sustain = false
        var bend: Double = 0
        var modWheel: Double = 0
    }

    let parts: [SF2Part] = (0..<partCount).map { _ in SF2Part() }
    private var sources: [AVAudioSourceNode] = []
    private var chains: [EffectChain] = []
    private let bus = AVAudioMixerNode()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    ))
    private let space = SendBus(node: Supermassive.makeNode(), count: partCount)
    var spaceNode: AVAudioUnit? { space.node }
    private var output: MotorOutput?
    private var timer: Timer?
    private(set) var graphRate = 44_100.0
    private var graphFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    func install(on output: MotorOutput, sampleRate: Double) {
        self.output = output
        applyGraphRate(sampleRate)
        let format = graphFormat
        output.attach(bus)
        output.attach(limiter)
        output.connect(limiter, to: output.mixer, format: format)
        output.connect(bus, to: limiter, format: format)
        space.install(on: output, to: bus, format: format)
        for (index, part) in parts.enumerated() {
            let source = Self.makeSource(part, format: format)
            let chain = EffectChain()
            output.attach(source)
            chain.install(on: output, from: source, to: bus, format: format, sends: sends(index))
            sources.append(source)
            chains.append(chain)
            applySends(index)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.collect()
        }
    }

    /// Rebuilds the graph at the output device rate. Voices restart silent.
    @discardableResult
    func setGraphRate(_ rate: Double) -> Bool {
        guard let output, sources.count == Self.partCount else { return false }
        let next = rate > 0 ? rate : 44_100
        guard abs(next - graphRate) > 0.5 else { return false }
        applyGraphRate(next)
        let format = graphFormat
        output.reconnect(limiter, to: output.mixer, format: format)
        output.reconnect(bus, to: limiter, format: format)
        space.rewire(on: output, to: bus, format: format)
        for index in parts.indices {
            output.engine.disconnectNodeOutput(sources[index])
            output.engine.detach(sources[index])
            let source = Self.makeSource(parts[index], format: format)
            sources[index] = source
            output.attach(source)
            chains[index].wire(on: output, from: source, to: bus, format: format, sends: sends(index))
            applySends(index)
        }
        return true
    }

    /// Post-fader sends; their tails keep ringing after a send closes.
    private func sends(_ index: Int) -> [AVAudioConnectionPoint] {
        space.points(index)
    }

    private func applySends(_ index: Int) {
        let source = sources.indices.contains(index) ? sources[index] : nil
        space.apply(index, source: source)
    }

    var meterNodes: [AVAudioNode] { chains.map(\.reverb.avAudioNode) }
    var masterMeterNode: AVAudioNode { limiter }

    /// Safe from the MIDI thread.
    func setMaster(_ volume: Double) {
        bus.outputVolume = Self.gain(volume)
    }

    func setProgram(_ program: SF2Program?, part: Int) {
        guard parts.indices.contains(part) else { return }
        parts[part].setProgram(program)
    }

    func program(part: Int) -> SF2Program? {
        parts.indices.contains(part) ? parts[part].program : nil
    }

    func configure(part: Int, slot: KeySlot) {
        guard parts.indices.contains(part) else { return }
        parts[part].update {
            $0.enabled = slot.enabled
            $0.gain = Self.gain(slot.volume)
            $0.octave = Int32(slot.octave)
            $0.followsSustain = slot.sustain
            $0.velocityCurve = slot.velocity
            $0.followsBend = slot.bend
            $0.tuneCents = Float(((slot.tune ?? 0.5) - 0.5) * 100)
            $0.pan = Float(((slot.pan ?? 0.5) - 0.5) * 2)
        }
        let source = sources.indices.contains(part) ? sources[part] : nil
        space.setLevel(part, slot.space ?? 0, source: source)
        if chains.indices.contains(part) {
            chains[part].apply(
                cutoff: slot.cutoff ?? 1, resonance: slot.resonance, compressor: slot.compressor ?? 0, reverb: slot.reverb ?? 0, rotary: slot.rotary,
                low: slot.low ?? 0.5, high: slot.high ?? 0.5
            )
        }
    }

    /// Applies to all parts; notes already held still release on the key that was pressed.
    func setTranspose(_ semitones: Int) {
        for part in parts { part.update { $0.transpose = Int32(semitones) } }
    }

    /// Safe from the MIDI thread.
    func setVolume(part: Int, volume: Double) {
        guard parts.indices.contains(part) else { return }
        parts[part].update { $0.gain = Self.gain(volume) }
    }

    /// Safe from the MIDI thread.
    func setEnabled(part: Int, enabled: Bool) {
        guard parts.indices.contains(part) else { return }
        parts[part].update { $0.enabled = enabled }
    }

    /// Safe from the MIDI thread. Bit `i` of `mask` sends the event to part `i`.
    func handle(_ event: MIDIEvent, parts mask: UInt8 = 0xF) {
        let kind: KeyEvent.Kind
        switch event.kind {
        case .noteOn: kind = .noteOn
        case .noteOff: kind = .noteOff
        case .control: kind = .control
        case .pitchBend: kind = .pitchBend
        default: return
        }
        let key = KeyEvent(kind: kind, data1: UInt8(clamping: event.data1), data2: UInt8(clamping: event.data2), host: event.hostTime)
        for (index, part) in parts.enumerated() where mask & (1 << UInt8(index)) != 0 { part.send(key) }
    }

    func panic() {
        for part in parts { part.send(KeyEvent(kind: .panic)) }
    }

    func stats() -> Stats {
        var stats = Stats()
        for (index, part) in parts.enumerated() {
            let report = part.report
            stats.voices[index] = Int(report.activeVoices)
            if report.bufferNanos > 0 { stats.load += report.renderNanos / report.bufferNanos }
            var keys = Set<Int>()
            for bit in 0..<64 {
                if report.keysLow & (1 << UInt64(bit)) != 0 { keys.insert(bit) }
                if report.keysHigh & (1 << UInt64(bit)) != 0 { keys.insert(bit + 64) }
            }
            stats.keys[index] = keys
        }
        return stats
    }

    func controllers() -> Controllers {
        let reports = parts.map(\.report)
        return Controllers(
            sustain: reports.contains { $0.sustain },
            bend: Double(reports.first { $0.bend != 0 }?.bend ?? 0),
            modWheel: Double(reports.first { $0.modWheel != 0 }?.modWheel ?? 0)
        )
    }

    private func collect() {
        let stopped = !(output?.engine.isRunning ?? false)
        for part in parts { part.collect(renderStopped: stopped) }
    }

    private func applyGraphRate(_ rate: Double) {
        let next = rate > 0 ? rate : 44_100
        graphRate = next
        if let format = AVAudioFormat(standardFormatWithSampleRate: next, channels: 2) {
            graphFormat = format
        }
        for part in parts { part.update { $0.sampleRate = next } }
    }

    private static func gain(_ volume: Double) -> Float {
        let level = Float(min(1, max(0, volume)))
        return level * level
    }

    private static func makeSource(_ part: SF2Part, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            part.render(frames: Int(frameCount), left: left, right: right)
            return noErr
        }
    }
}
