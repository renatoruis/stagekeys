import AudioKit
import AVFoundation
import Foundation
import SoundpipeAudioKit

/// One-shot sample player rendered in a source node: triggers never touch the audio graph.
/// Each hit carries its own gain and reverb send; sends feed a single shared reverb.
final class DrumEngine {
    static let padCount = 8
    private static let voiceCount = 32
    private static let maxPerPad = 4
    private static let sampleSlots = 32
    private static let sendFrames = 4096

    private struct Hit {
        var slot: Int32 = -1
        var pad: Int32 = 0
        var gain: Float = 0
        var send: Float = 0
        var host: UInt64 = 0
    }

    private struct SampleView {
        var left: UnsafePointer<Float>?
        var right: UnsafePointer<Float>?
        var frames = 0
    }

    private struct Voice {
        var slot: Int32 = -1
        var pad: Int32 = 0
        var position = 0
        var gain: Float = 0
        var send: Float = 0
        var fade: Float = 1
        var fadeStep: Float = 0
        var age: UInt64 = 0
    }

    private struct Report {
        var cycle: UInt64 = 0
        var inUse: UInt32 = 0
    }

    private struct State {
        var age: UInt64 = 0
        var report = Report()
        var sampleRate = 44_100.0
        var seen = 0
        var control = 0
    }

    private let hits = EventRing<Hit>(capacity: 256, empty: Hit())
    private let mailbox = RTMailbox<Int, Report>(control: 0, report: Report())
    private let state: UnsafeMutablePointer<State>
    private let voices: UnsafeMutablePointer<Voice>
    private let pending: UnsafeMutablePointer<Hit>
    private let views: UnsafeMutablePointer<SampleView>
    private let sendLeft: UnsafeMutablePointer<Float>
    private let sendRight: UnsafeMutablePointer<Float>

    private let cache: AudioBufferCache
    private let lock = NSLock()
    private var padSlot = Array(repeating: Int32(-1), count: padCount)
    private var gains: [Float] = Array(repeating: 0.9, count: padCount)
    private var sends: [Float] = Array(repeating: 0, count: padCount)
    private var slotBuffers: [AVAudioPCMBuffer?] = Array(repeating: nil, count: sampleSlots)
    private var retired: [Int: UInt64] = [:]
    private var waiting: [Int: AVAudioPCMBuffer] = [:]
    private var urls: [URL?] = Array(repeating: nil, count: padCount)
    private var generation = Array(repeating: 0, count: padCount)

    private var dry: AVAudioSourceNode?
    private var wet: AVAudioSourceNode?
    private let reverb = ZitaReverb(Mixer(), predelay: 20, midReleaseTime: 1.8, dampingFrequency: 7_000, dryWetMix: 1)
    private var output: MotorOutput?
    private var timer: Timer?
    private var graphRate = 44_100.0
    private var graphFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    init(cache: AudioBufferCache) {
        self.cache = cache
        state = .allocate(capacity: 1)
        state.initialize(to: State())
        voices = .allocate(capacity: Self.voiceCount)
        voices.initialize(repeating: Voice(), count: Self.voiceCount)
        pending = .allocate(capacity: 256)
        pending.initialize(repeating: Hit(), count: 256)
        views = .allocate(capacity: Self.sampleSlots)
        views.initialize(repeating: SampleView(), count: Self.sampleSlots)
        sendLeft = .allocate(capacity: Self.sendFrames)
        sendLeft.initialize(repeating: 0, count: Self.sendFrames)
        sendRight = .allocate(capacity: Self.sendFrames)
        sendRight.initialize(repeating: 0, count: Self.sendFrames)
    }

    deinit {
        state.deallocate()
        voices.deallocate()
        pending.deallocate()
        views.deallocate()
        sendLeft.deallocate()
        sendRight.deallocate()
    }

    func install(on output: MotorOutput, sampleRate: Double) {
        self.output = output
        applyGraphRate(sampleRate)
        output.attach(reverb.avAudioNode)
        output.connect(reverb.avAudioNode, to: output.mixer, format: graphFormat)
        buildSources()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.collect()
        }
    }

    /// Rebuilds the source nodes at the device rate. Callers reload the pads afterwards.
    @discardableResult
    func setGraphRate(_ rate: Double) -> Bool {
        guard let output, dry != nil else { return false }
        let next = rate > 0 ? rate : 44_100
        guard abs(next - graphRate) > 0.5 else { return false }
        applyGraphRate(next)
        for node in [dry, wet].compactMap({ $0 }) {
            output.engine.disconnectNodeOutput(node)
            output.engine.detach(node)
        }
        output.reconnect(reverb.avAudioNode, to: output.mixer, format: graphFormat)
        buildSources()
        return true
    }

    var meterNodes: [AVAudioNode] { output.map { [$0.mixer] } ?? [] }

    func setReverb(index: Int, amount: Double) {
        guard sends.indices.contains(index) else { return }
        lock.lock()
        sends[index] = Float(min(1, max(0, amount)))
        lock.unlock()
    }

    func setGain(index: Int, gain: Float) {
        guard gains.indices.contains(index) else { return }
        lock.lock()
        gains[index] = gain
        lock.unlock()
    }

    /// Main thread. Uses the shared cache; the pad stays silent until its sample is decoded.
    func load(index: Int, url: URL?) {
        guard urls.indices.contains(index) else { return }
        generation[index] += 1
        let token = generation[index]
        urls[index] = url
        guard let url else {
            assign(index, buffer: nil)
            return
        }
        if let buffer = cache.cached(url, rate: graphRate) {
            assign(index, buffer: buffer)
            return
        }
        assign(index, buffer: nil)
        cache.load(url, rate: graphRate) { [weak self] buffer in
            guard let self, self.generation[index] == token else { return }
            self.assign(index, buffer: buffer)
        }
    }

    var sampleRate: Double { graphRate }

    /// Any thread. `host` is the MIDI timestamp (0 plays at the next buffer).
    func trigger(index: Int, velocity: Float, host: UInt64 = 0) {
        guard padSlot.indices.contains(index) else { return }
        lock.lock()
        let slot = padSlot[index]
        let hit = Hit(slot: slot, pad: Int32(index), gain: gains[index] * min(1, max(0, velocity)), send: sends[index], host: host)
        if slot >= 0 { hits.push(hit) }
        lock.unlock()
    }

    // MARK: Main thread

    private func assign(_ pad: Int, buffer: AVAudioPCMBuffer?) {
        waiting.removeValue(forKey: pad)
        var slot: Int32 = -1
        if let buffer {
            guard let free = freeSlot() else {
                waiting[pad] = buffer
                return
            }
            slotBuffers[free] = buffer
            views[free] = SampleView(
                left: buffer.floatChannelData.map { UnsafePointer($0[0]) },
                right: buffer.floatChannelData.map { UnsafePointer($0[min(1, Int(buffer.format.channelCount) - 1)]) },
                frames: Int(buffer.frameLength)
            )
            slot = Int32(free)
        }
        lock.lock()
        let old = padSlot[pad]
        padSlot[pad] = slot
        lock.unlock()
        if old >= 0 { retired[Int(old)] = mailbox.read().report.cycle }
    }

    private func freeSlot() -> Int? {
        let current = Set(padSlot)
        return slotBuffers.indices.first { slotBuffers[$0] == nil && !current.contains(Int32($0)) && retired[$0] == nil }
    }

    private func collect() {
        let stopped = !(output?.engine.isRunning ?? false)
        if stopped {
            for index in 0..<Self.voiceCount { voices[index] = Voice() }
        }
        let report = mailbox.read().report
        let current = Set(padSlot)
        for (slot, cycle) in retired where !current.contains(Int32(slot)) {
            let busy = report.inUse & (1 << UInt32(slot)) != 0
            if stopped || (report.cycle >= cycle + 3 && !busy) {
                retired.removeValue(forKey: slot)
                views[slot] = SampleView()
                slotBuffers[slot] = nil
            }
        }
        for (pad, buffer) in waiting {
            assign(pad, buffer: buffer)
        }
    }

    private func applyGraphRate(_ rate: Double) {
        let next = rate > 0 ? rate : 44_100
        graphRate = next
        if let format = AVAudioFormat(standardFormatWithSampleRate: next, channels: 2) {
            graphFormat = format
        }
    }

    private func buildSources() {
        guard let output else { return }
        let dry = AVAudioSourceNode(format: graphFormat) { [unowned self] _, _, frameCount, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.render(frames: Int(frameCount), left: left, right: right)
            return noErr
        }
        let sendLeft = sendLeft
        let sendRight = sendRight
        let wet = AVAudioSourceNode(format: graphFormat) { _, _, frameCount, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let frames = min(Int(frameCount), Self.sendFrames)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            left.update(from: sendLeft, count: frames)
            right.update(from: sendRight, count: frames)
            return noErr
        }
        state.pointee.sampleRate = graphRate
        output.attach(dry)
        output.attach(wet)
        output.connect(dry, to: output.mixer, format: graphFormat)
        output.connect(wet, to: reverb.avAudioNode, format: graphFormat)
        self.dry = dry
        self.wet = wet
    }

    // MARK: Render thread

    private func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let started = HostTime.now()
        let frames = min(frames, Self.sendFrames)
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        sendLeft.update(repeating: 0, count: frames)
        sendRight.update(repeating: 0, count: frames)
        let rate = state.pointee.sampleRate

        let count = hits.drain(into: pending, limit: 256)
        let windowStart = Double(started) - Double(frames) / rate * 1e9 / HostTime.nanosPerTick
        let framesPerTick = HostTime.nanosPerTick * 1e-9 * rate
        var cursor = 0
        var lastOffset = 0
        for index in 0..<count {
            let hit = pending[index]
            var offset = 0
            if hit.host != 0 {
                offset = min(frames - 1, max(lastOffset, Int((Double(hit.host) - windowStart) * framesPerTick)))
            }
            if offset > cursor {
                renderVoices(from: cursor, to: offset, left: left, right: right)
                cursor = offset
            }
            lastOffset = offset
            start(hit, rate: rate)
        }
        if cursor < frames {
            renderVoices(from: cursor, to: frames, left: left, right: right)
        }

        var inUse: UInt32 = 0
        for index in 0..<Self.voiceCount where voices[index].slot >= 0 {
            inUse |= 1 << UInt32(voices[index].slot)
        }
        state.pointee.report.cycle &+= 1
        state.pointee.report.inUse = inUse
        mailbox.publish(&state.pointee.report)
    }

    @inline(__always)
    private func start(_ hit: Hit, rate: Double) {
        guard hit.slot >= 0, hit.slot < Int32(Self.sampleSlots), views[Int(hit.slot)].frames > 0 else { return }
        let kill = 1 / Float(max(1, 0.005 * rate))
        var free = -1
        var oldest = -1
        var oldestAge = UInt64.max
        var padCount = 0
        var padOldest = -1
        var padOldestAge = UInt64.max
        for index in 0..<Self.voiceCount {
            let voice = voices[index]
            if voice.slot < 0 {
                if free < 0 { free = index }
                continue
            }
            if voice.age < oldestAge {
                oldestAge = voice.age
                oldest = index
            }
            if voice.pad == hit.pad, voice.fadeStep == 0 {
                padCount += 1
                if voice.age < padOldestAge {
                    padOldestAge = voice.age
                    padOldest = index
                }
            }
        }
        if padCount >= Self.maxPerPad, padOldest >= 0 {
            voices[padOldest].fadeStep = kill
        }
        let index = free >= 0 ? free : oldest
        guard index >= 0 else { return }
        state.pointee.age &+= 1
        voices[index] = Voice(slot: hit.slot, pad: hit.pad, position: 0, gain: hit.gain, send: hit.send, age: state.pointee.age)
    }

    @inline(__always)
    private func renderVoices(from start: Int, to end: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        for index in 0..<Self.voiceCount where voices[index].slot >= 0 {
            var voice = voices[index]
            let view = views[Int(voice.slot)]
            guard let sourceLeft = view.left, let sourceRight = view.right else {
                voices[index].slot = -1
                continue
            }
            let run = min(end - start, view.frames - voice.position)
            var frame = 0
            while frame < run {
                let position = voice.position + frame
                let level = voice.gain * voice.fade
                let l = sourceLeft[position] * level
                let r = sourceRight[position] * level
                left[start + frame] += l
                right[start + frame] += r
                sendLeft[start + frame] += l * voice.send
                sendRight[start + frame] += r * voice.send
                if voice.fadeStep > 0 {
                    voice.fade -= voice.fadeStep
                    if voice.fade <= 0 {
                        voice.fade = 0
                        break
                    }
                }
                frame += 1
            }
            voice.position += run
            if voice.position >= view.frames || voice.fade <= 0 {
                voice.slot = -1
            }
            voices[index] = voice
        }
    }
}
