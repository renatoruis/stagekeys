import Accelerate
import AVFoundation
import Foundation
import os
import SoundpipeAudioKit

final class PadEngine {
    static let layerCount = 4

    private struct LayerState {
        var family: String?
        var pitch = "C"
        var volume: Float = 0.7
        var playing = false
        var followMIDI = true
        var urls: [String: URL] = [:]
    }

    /// Reads the sample in a circle inside the render callback, so the loop has no player ramp.
    /// The tail is crossfaded into the head past the file's own fade-in, so the turn is seamless.
    /// Starting, stopping and changing pitch fade with an equal-power curve; the outgoing pitch keeps looping while it fades.
    private final class LoopVoice {
        static let fadeSeconds: Float = 1.5
        private static let maxFrames = 4096
        private static let deckCount = 3

        private struct Shape {
            var loopStart = 0
            var crossfade = 0
            var fadeOut: [Float] = []
            var fadeIn: [Float] = []
        }

        private struct Deck {
            var buffer: AVAudioPCMBuffer?
            var frames = 0
            var cursor = 0
            var shape = Shape()
            var level: Float = 0
            var target: Float = 0
            var active = false
        }

        private struct State {
            var decks = [Deck](repeating: Deck(), count: LoopVoice.deckCount)
            var current = -1
            var gain: Float = 0.7
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        private let ramp = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)

        deinit {
            scratch.deallocate()
            ramp.deallocate()
        }

        /// Fades `buffer` in. The same buffer keeps its position; a different one crossfades from its start.
        func play(_ buffer: AVAudioPCMBuffer, gain: Float) {
            let playing = state.withLock { s in
                s.current >= 0 && s.decks[s.current].active && s.decks[s.current].buffer === buffer
            }
            let shape = playing ? Shape() : Self.analyze(buffer)
            let frames = Int(buffer.frameLength)
            guard buffer.floatChannelData != nil, frames > 0 else { return }
            state.withLock { s in
                s.gain = gain
                if s.current >= 0, s.decks[s.current].active, s.decks[s.current].buffer === buffer {
                    s.decks[s.current].target = 1
                    return
                }
                if s.current >= 0 { s.decks[s.current].target = 0 }
                let slot = s.decks.indices.first { !s.decks[$0].active }
                    ?? s.decks.indices.min { s.decks[$0].level < s.decks[$1].level }!
                s.decks[slot] = Deck(buffer: buffer, frames: frames, shape: shape, target: 1, active: true)
                s.current = slot
            }
        }

        /// Fades out; the buffer is kept until the next `play`, so nothing is released on the render thread.
        func stop() {
            state.withLock { s in
                if s.current >= 0 { s.decks[s.current].target = 0 }
            }
        }

        func setGain(_ gain: Float) {
            state.withLock { $0.gain = gain }
        }

        func render(_ list: UnsafeMutablePointer<AudioBufferList>, frames frameCount: AVAudioFrameCount) -> OSStatus {
            let outputs = UnsafeMutableAudioBufferListPointer(list)
            Self.clear(outputs)
            let total = Int(frameCount)
            state.withLock { s in
                let gain = s.gain
                var offset = 0
                while offset < total {
                    let count = min(Self.maxFrames, total - offset)
                    for index in s.decks.indices where s.decks[index].active {
                        mix(&s.decks[index], into: outputs, offset: offset, count: count, gain: gain)
                    }
                    offset += count
                }
            }
            return noErr
        }

        private func mix(_ deck: inout Deck, into outputs: UnsafeMutableAudioBufferListPointer, offset: Int, count: Int, gain: Float) {
            guard let buffer = deck.buffer, let data = buffer.floatChannelData else {
                deck.active = false
                return
            }
            let channels = Int(buffer.format.channelCount)
            let samples = vDSP_Length(count)
            if deck.level == deck.target {
                var value = gain * deck.level
                vDSP_vfill(&value, ramp, 1, samples)
            } else {
                let delta = 1 / (Float(buffer.format.sampleRate) * Self.fadeSeconds)
                var start = deck.level
                var step = deck.target > deck.level ? delta : -delta
                vDSP_vramp(&start, &step, ramp, 1, samples)
                var low: Float = 0
                var high: Float = 1
                vDSP_vclip(ramp, 1, &low, &high, ramp, 1, samples)
                deck.level = min(1, max(0, deck.level + step * Float(count)))
                if (step > 0 && deck.level >= deck.target) || (step < 0 && deck.level <= deck.target) {
                    deck.level = deck.target
                }
                var quarter = Float.pi / 2
                vDSP_vsmul(ramp, 1, &quarter, ramp, 1, samples)
                var n = Int32(count)
                vvsinf(ramp, ramp, &n)
                var g = gain
                vDSP_vsmul(ramp, 1, &g, ramp, 1, samples)
            }
            var cursor = deck.cursor
            for output in outputs.enumerated() {
                guard let destination = output.element.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let source = data[min(output.offset, channels - 1)]
                cursor = Self.read(source, shape: deck.shape, length: deck.frames, cursor: deck.cursor, count: count, into: scratch)
                let out = destination.advanced(by: offset)
                vDSP_vma(scratch, 1, ramp, 1, out, 1, out, 1, samples)
            }
            deck.cursor = cursor
            if deck.target == 0, deck.level == 0 { deck.active = false }
        }

        /// Copies `count` looped frames starting at `cursor`; returns the next cursor.
        private static func read(_ source: UnsafeMutablePointer<Float>, shape: Shape, length: Int, cursor start: Int, count: Int, into out: UnsafeMutablePointer<Float>) -> Int {
            var cursor = start
            let zoneStart = length - shape.crossfade
            var written = 0
            while written < count {
                let inZone = shape.crossfade > 0 && cursor >= zoneStart
                let limit = inZone ? length : zoneStart
                let run = min(count - written, limit - cursor)
                guard run > 0 else {
                    cursor = 0
                    continue
                }
                let samples = vDSP_Length(run)
                let destination = out.advanced(by: written)
                if inZone {
                    let t = cursor - zoneStart
                    shape.fadeOut.withUnsafeBufferPointer { fadeOut in
                        shape.fadeIn.withUnsafeBufferPointer { fadeIn in
                            vDSP_vmul(source.advanced(by: cursor), 1, fadeOut.baseAddress!.advanced(by: t), 1, destination, 1, samples)
                            vDSP_vma(source.advanced(by: shape.loopStart + t), 1, fadeIn.baseAddress!.advanced(by: t), 1, destination, 1, destination, 1, samples)
                        }
                    }
                } else {
                    destination.update(from: source.advanced(by: cursor), count: run)
                }
                written += run
                cursor += run
                if cursor >= length {
                    cursor = shape.crossfade > 0 ? shape.loopStart + shape.crossfade : 0
                    if cursor >= length { cursor = 0 }
                }
            }
            return cursor
        }

        /// Finds where the file reaches steady level, then sizes an equal-power crossfade from the tail into it.
        private static func analyze(_ buffer: AVAudioPCMBuffer) -> Shape {
            let frames = Int(buffer.frameLength)
            guard let data = buffer.floatChannelData, frames > 0 else { return Shape() }
            let channels = Int(buffer.format.channelCount)
            let rate = buffer.format.sampleRate
            let window = max(1, Int(rate * 0.05))
            var levels: [Float] = []
            var start = 0
            while start < frames {
                let run = min(window, frames - start)
                var sum: Float = 0
                for channel in 0..<channels {
                    var value: Float = 0
                    vDSP_rmsqv(data[channel].advanced(by: start), 1, &value, vDSP_Length(run))
                    sum += value
                }
                levels.append(sum / Float(channels))
                start += run
            }
            guard levels.count > 2 else { return Shape() }
            let sorted = levels.sorted()
            let median = sorted[sorted.count / 2]
            let threshold = median * 0.5
            var loopStart = 0
            if let index = levels.firstIndex(where: { $0 >= threshold }) {
                loopStart = min(index * window, frames - 1)
            }
            let remaining = frames - loopStart
            var crossfade = min(Int(rate * 4), remaining / 4)
            if loopStart + crossfade >= frames { crossfade = 0 }
            guard crossfade > 0 else { return Shape(loopStart: 0, crossfade: 0) }
            var fadeOut = [Float](repeating: 0, count: crossfade)
            var fadeIn = [Float](repeating: 0, count: crossfade)
            let step = Float.pi / 2 / Float(crossfade)
            for index in 0..<crossfade {
                let angle = Float(index) * step
                fadeOut[index] = cos(angle)
                fadeIn[index] = sin(angle)
            }
            return Shape(loopStart: loopStart, crossfade: crossfade, fadeOut: fadeOut, fadeIn: fadeIn)
        }

        private static func clear(_ outputs: UnsafeMutableAudioBufferListPointer) {
            for output in outputs {
                guard let data = output.mData else { continue }
                memset(data, 0, Int(output.mDataByteSize))
            }
        }
    }

    private var layers = Array(repeating: LayerState(), count: layerCount)
    private var voices: [LoopVoice] = []
    private var sources: [AVAudioSourceNode] = []
    private var strips: [AVAudioMixerNode] = []
    private var filters: [MoogLadder] = []
    private let space = SendBus(node: Supermassive.makeNode(), count: layerCount)
    var spaceNode: AVAudioUnit? { space.node }
    private let cache: AudioBufferCache
    private var generation = Array(repeating: 0, count: layerCount)
    private var graphRate = 44_100.0
    private var graphFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private let lock = NSLock()
    private var output: MotorOutput?
    var onPitchChange: ((Int, String) -> Void)?

    init(cache: AudioBufferCache) {
        self.cache = cache
    }

    var sampleRate: Double { graphRate }

    func install(on output: MotorOutput, sampleRate: Double) {
        self.output = output
        applyGraphRate(sampleRate)
        let format = graphFormat
        space.install(on: output, to: output.mixer, format: format)
        for index in 0..<Self.layerCount {
            let voice = LoopVoice()
            let source = makeSource(voice, format: format)
            let strip = AVAudioMixerNode()
            let filter = EffectChain.makeFilter()
            output.attach(source)
            output.attach(strip)
            output.attach(filter.avAudioNode)
            output.connect(filter.avAudioNode, to: output.mixer, format: format)
            output.connect(strip, to: filter.avAudioNode, format: format)
            voices.append(voice)
            sources.append(source)
            strips.append(strip)
            filters.append(filter)
            connectSource(index, format: format)
        }
    }

    func setSpace(index: Int, amount: Double) {
        space.setLevel(index, amount, source: sources.indices.contains(index) ? sources[index] : nil)
    }

    /// Source → strip, plus a post-fader send into the shared space.
    private func connectSource(_ index: Int, format: AVAudioFormat) {
        guard let output else { return }
        let points = [AVAudioConnectionPoint(node: strips[index], bus: 0)] + space.points(index)
        output.engine.connect(sources[index], to: points, fromBus: 0, format: format)
        space.apply(index, source: sources[index])
    }

    /// Reconnects the chain when the output device rate changes. Loops are decoded again at the new rate.
    @discardableResult
    func setGraphRate(_ rate: Double) -> Bool {
        guard sources.count == Self.layerCount, let output else { return false }
        let next = rate > 0 ? rate : 44_100
        guard abs(next - graphRate) > 0.5 else { return false }
        applyGraphRate(next)
        let format = graphFormat
        space.rewire(on: output, to: output.mixer, format: format)
        for index in 0..<Self.layerCount {
            generation[index] += 1
            halt(index)
            output.engine.disconnectNodeOutput(sources[index])
            output.engine.detach(sources[index])
            let source = makeSource(voices[index], format: format)
            sources[index] = source
            output.attach(source)
            output.reconnect(filters[index].avAudioNode, to: output.mixer, format: format)
            output.reconnect(strips[index], to: filters[index].avAudioNode, format: format)
            connectSource(index, format: format)
        }
        return true
    }

    var meterNodes: [AVAudioNode] { filters.map(\.avAudioNode) }

    /// All pads and their shared space.
    func setMaster(_ value: Float) {
        output?.mixer.outputVolume = value
    }

    func setCutoff(index: Int, cutoff: Double) {
        guard filters.indices.contains(index) else { return }
        EffectChain.applyCutoff(filters[index], cutoff)
    }

    func configure(index: Int, family: String?, pitch: String, volume: Float, playing: Bool, followMIDI: Bool, urls: [String: URL]) {
        lock.lock()
        let previousFamily = layers[index].family
        let previousPitch = layers[index].pitch
        let wasPlaying = layers[index].playing
        layers[index].family = family
        layers[index].pitch = pitch
        layers[index].volume = volume
        layers[index].playing = playing
        layers[index].followMIDI = followMIDI
        layers[index].urls = urls
        lock.unlock()
        voices[index].setGain(volume)
        if previousFamily != family {
            preload(index: index)
        } else if previousPitch != pitch || (playing && !wasPlaying) {
            restartIfNeeded(index)
        } else if playing {
            restartIfNeeded(index)
        } else {
            halt(index)
        }
    }

    func setVolume(index: Int, volume: Float) {
        lock.lock()
        layers[index].volume = volume
        lock.unlock()
        voices[index].setGain(volume)
    }

    func setPlaying(index: Int, playing: Bool) {
        lock.lock()
        layers[index].playing = playing
        lock.unlock()
        if playing {
            restartIfNeeded(index)
        } else {
            halt(index)
        }
    }

    func toggle(index: Int) -> Bool {
        lock.lock()
        layers[index].playing.toggle()
        let playing = layers[index].playing
        lock.unlock()
        setPlaying(index: index, playing: playing)
        return playing
    }

    func setPitch(_ pitch: String) {
        for index in 0..<Self.layerCount {
            lock.lock()
            let current = layers[index].pitch
            layers[index].pitch = pitch
            lock.unlock()
            if current != pitch {
                restartIfNeeded(index)
            }
        }
    }

    func setFollow(index: Int, follow: Bool) {
        lock.lock()
        layers[index].followMIDI = follow
        lock.unlock()
    }

    func follow(note: Int) {
        if Thread.isMainThread {
            applyFollow(note)
        } else {
            DispatchQueue.main.async { [weak self] in self?.applyFollow(note) }
        }
    }

    private func makeSource(_ voice: LoopVoice, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            voice.render(audioBufferList, frames: frameCount)
        }
    }

    private func applyGraphRate(_ rate: Double) {
        let next = rate > 0 ? rate : 44_100
        graphRate = next
        if let format = AVAudioFormat(standardFormatWithSampleRate: next, channels: 2) {
            graphFormat = format
        }
    }

    private func applyFollow(_ note: Int) {
        let token = ResourceCatalog.pitchToken(forMIDINote: note)
        for index in 0..<Self.layerCount {
            lock.lock()
            let follows = layers[index].followMIDI && layers[index].family != nil
            let current = layers[index].pitch
            if follows, current != token {
                layers[index].pitch = token
            }
            lock.unlock()
            guard follows, current != token else { continue }
            onPitchChange?(index, token)
            restartIfNeeded(index)
        }
    }

    /// New family: the current pitch is decoded first, the other eleven follow so MIDI follow switches instantly.
    private func preload(index: Int) {
        generation[index] += 1
        lock.lock()
        let urls = layers[index].urls
        let pitch = layers[index].pitch
        lock.unlock()
        halt(index)
        restartIfNeeded(index)
        for (key, url) in urls where key != pitch {
            cache.load(url, rate: graphRate)
        }
    }

    private func restartIfNeeded(_ index: Int) {
        lock.lock()
        let playing = layers[index].playing
        let pitch = layers[index].pitch
        let url = layers[index].urls[pitch]
        lock.unlock()
        guard playing else {
            halt(index)
            return
        }
        guard let url else { return }
        if let cached = cache.cached(url, rate: graphRate) {
            play(index, buffer: cached)
            return
        }
        let token = generation[index]
        cache.load(url, rate: graphRate) { [weak self] buffer in
            guard let self, let buffer, self.generation[index] == token else { return }
            self.lock.lock()
            let still = self.layers[index].playing && self.layers[index].urls[self.layers[index].pitch] == url
            self.lock.unlock()
            if still { self.play(index, buffer: buffer) }
        }
    }

    private func play(_ index: Int, buffer: AVAudioPCMBuffer) {
        lock.lock()
        let gain = layers[index].volume
        lock.unlock()
        voices[index].play(buffer, gain: gain)
    }

    private func halt(_ index: Int) {
        voices[index].stop()
    }
}
