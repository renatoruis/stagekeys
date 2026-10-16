import Foundation

/// MIDI-derived state shared by all voices of one part, owned by the render thread.
struct SF2Channel {
    var bendCents: Float = 0
    var tuneCents: Float = 0
    var modWheel: Float = 0
    var volume: Float = 1
    var expression: Float = 1
    /// The physical pedal (CC64); `sustain` is the pedal when the layer follows it.
    var pedal = false
    var sustain = false
    /// Fader gain times channel volume and expression.
    var gain: Float = 0.64
}

/// SF2 envelope. Volume envelopes decay and release linearly in dB; modulation envelopes linearly in level.
struct SF2Envelope {
    enum Stage: Int32 {
        case delay, attack, hold, decay, sustain, release, finished
    }

    var stage: Stage = .finished
    var level: Float = 0
    var remaining: Int32 = 0
    var attackFrames: Int32 = 1
    var holdFrames: Int32 = 0
    var sustain: Float = 1
    var decay: Float = 0
    var decayChunk: Float = 0
    var release: Float = 0
    var releaseChunk: Float = 0
    var exponential = true

    static let silence: Float = 0.00001

    init() {}

    init(_ source: SF2Region.Envelope, key: Int, rate: Float, volume: Bool) {
        exponential = volume
        func frames(_ timecents: Float, minimum: Float = 0) -> Float {
            max(minimum, exp2f(min(8000, timecents) / 1200)) * rate
        }
        let keyOffset = Float(60 - key)
        let delayFrames = source.delay <= -12000 ? 0 : frames(source.delay)
        attackFrames = Int32(max(1, frames(source.attack)))
        holdFrames = source.hold <= -12000 ? 0 : Int32(frames(source.hold + source.keyToHold * keyOffset))
        let decayFrames = max(1, frames(source.decay + source.keyToDecay * keyOffset))
        let releaseFrames = max(1, frames(source.release, minimum: volume ? 0.006 : 0.001))
        if volume {
            sustain = powf(10, -source.sustain / 200)
            decay = powf(10, -5 / decayFrames)
            release = powf(10, -5 / releaseFrames)
            decayChunk = powf(decay, Float(SF2Voice.block))
            releaseChunk = powf(release, Float(SF2Voice.block))
        } else {
            sustain = 1 - source.sustain / 1000
            decay = 1 / decayFrames
            release = 1 / releaseFrames
            decayChunk = decay * Float(SF2Voice.block)
            releaseChunk = release * Float(SF2Voice.block)
        }
        level = 0
        if delayFrames >= 1 {
            stage = .delay
            remaining = Int32(delayFrames)
        } else {
            stage = .attack
            remaining = attackFrames
        }
    }

    @inline(__always)
    mutating func advance(_ frames: Int) {
        var left = Int32(frames)
        while left > 0 {
            switch stage {
            case .delay:
                let take = min(left, remaining)
                remaining -= take
                left -= take
                if remaining <= 0 {
                    stage = .attack
                    remaining = attackFrames
                }
            case .attack:
                let take = min(left, remaining)
                level += (1 - level) * Float(take) / Float(max(1, remaining))
                remaining -= take
                left -= take
                if remaining <= 0 {
                    level = 1
                    stage = .hold
                    remaining = holdFrames
                }
            case .hold:
                let take = min(left, remaining)
                remaining -= take
                left -= take
                if remaining <= 0 { stage = .decay }
            case .decay:
                if exponential {
                    level *= left == Int32(SF2Voice.block) ? decayChunk : powf(decay, Float(left))
                } else {
                    level -= left == Int32(SF2Voice.block) ? decayChunk : decay * Float(left)
                }
                left = 0
                if level <= sustain {
                    level = sustain
                    stage = .sustain
                }
            case .sustain:
                left = 0
                if exponential, level < Self.silence { stage = .finished }
            case .release:
                if exponential {
                    level *= left == Int32(SF2Voice.block) ? releaseChunk : powf(release, Float(left))
                    if level < Self.silence { stage = .finished }
                } else {
                    level -= left == Int32(SF2Voice.block) ? releaseChunk : release * Float(left)
                    if level <= 0 {
                        level = 0
                        stage = .finished
                    }
                }
                left = 0
            case .finished:
                left = 0
            }
        }
    }

    @inline(__always)
    mutating func noteOff() {
        guard stage != .finished, stage != .release else { return }
        if stage == .delay {
            stage = .finished
            level = 0
            return
        }
        stage = .release
    }
}

/// Triangle LFO with an initial delay, evaluated at control rate.
struct SF2LFO {
    var delay: Int32 = 0
    var phase: Float = 0
    var step: Float = 0
    var value: Float = 0

    init() {}

    init(delay timecents: Float, frequency cents: Float, rate: Float) {
        delay = timecents <= -12000 ? 0 : Int32(exp2f(min(5000, timecents) / 1200) * rate)
        step = 8.176 * exp2f(cents / 1200) / rate
    }

    @inline(__always)
    mutating func advance(_ frames: Int) {
        var left = Int32(frames)
        if delay > 0 {
            let take = min(left, delay)
            delay -= take
            left -= take
            if left == 0 { return }
        }
        phase += step * Float(left)
        phase -= floorf(phase)
        value = phase < 0.25 ? 4 * phase : (phase < 0.75 ? 2 - 4 * phase : 4 * phase - 4)
    }
}

struct SF2Voice {
    enum State: UInt8 {
        case free, playing, released, dying
    }

    /// Control-rate block: envelopes, LFOs, pitch and filter update every `block` frames.
    static let block = 16
    /// Velocity response: gain = (velocity / 127) ^ curve.
    static let velocityCurve: Float = 1.6

    var state: State = .free
    var noteKey: UInt8 = 0
    var sustained = false
    var exclusiveClass: UInt8 = 0
    var programSlot: UInt8 = 0
    var age: UInt64 = 0

    private var samples: UnsafePointer<Int16>?
    private var position: Double = 0
    private var end = 0
    private var loopStart = 0
    private var loopEnd = 0
    private var looping = false
    private var loopMode: UInt8 = 0
    private var sampleRatio: Double = 1
    private var baseCents: Float = 0

    private var baseGain: Float = 0
    private var panLeft: Float = 0.707
    private var panRight: Float = 0.707
    private var amp: Float = 0
    private var fade: Float = 1
    private var fadeStep: Float = 0

    private var volEnv = SF2Envelope()
    private var modEnv = SF2Envelope()
    private var modLfo = SF2LFO()
    private var vibLfo = SF2LFO()
    private var modEnvToPitch: Float = 0
    private var modEnvToFc: Float = 0
    private var modLfoToPitch: Float = 0
    private var modLfoToFc: Float = 0
    private var modLfoToVolume: Float = 0
    private var vibLfoToPitch: Float = 0

    private var filterOn = false
    private var filterCents: Float = 13500
    private var filterQ: Float = 0.7071
    private var lastFc: Float = -1
    private var b0: Float = 1
    private var b1: Float = 0
    private var b2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var z1: Float = 0
    private var z2: Float = 0

    /// Current output amplitude, used to pick the quietest voice to steal.
    var loudness: Float { amp }
    var isActive: Bool { state != .free }

    mutating func start(
        region: SF2Region,
        samples: UnsafePointer<Int16>,
        key: Int,
        noteKey: Int,
        velocity: Int,
        outputRate: Double,
        age: UInt64,
        slot: UInt8
    ) {
        let rate = Float(outputRate)
        state = .playing
        self.noteKey = UInt8(noteKey)
        sustained = false
        exclusiveClass = region.exclusiveClass
        programSlot = slot
        self.age = age
        self.samples = samples
        position = Double(region.start)
        end = region.end
        loopStart = region.loopStart
        loopEnd = region.loopEnd
        loopMode = region.loopMode
        looping = region.loopMode == 1 || region.loopMode == 3
        sampleRatio = Double(region.sampleRate) / outputRate
        baseCents = (Float(key) - Float(region.rootKey)) * region.scaleTuning + region.tuneCents

        let velocityGain = powf(Float(max(1, velocity)) / 127, Self.velocityCurve)
        baseGain = powf(10, -(region.attenuation * 0.4) / 200) * velocityGain / 32768
        let angle = (region.pan + 0.5) * Float.pi / 2
        panLeft = cosf(angle)
        panRight = sinf(angle)
        amp = 0
        fade = 1
        fadeStep = 0

        volEnv = SF2Envelope(region.volEnv, key: key, rate: rate, volume: true)
        modEnv = SF2Envelope(region.modEnv, key: key, rate: rate, volume: false)
        modLfo = SF2LFO(delay: region.modLfoDelay, frequency: region.modLfoFreq, rate: rate)
        vibLfo = SF2LFO(delay: region.vibLfoDelay, frequency: region.vibLfoFreq, rate: rate)
        modEnvToPitch = region.modEnvToPitch
        modEnvToFc = region.modEnvToFc
        modLfoToPitch = region.modLfoToPitch
        modLfoToFc = region.modLfoToFc
        modLfoToVolume = region.modLfoToVolume
        vibLfoToPitch = region.vibLfoToPitch

        filterCents = region.filterFc - 2400 * (1 - Float(velocity) / 127)
        let resonance = powf(10, region.filterQ / 200)
        filterQ = max(0.7071, 0.7071 * resonance)
        filterOn = filterCents < 13450 || modEnvToFc != 0 || modLfoToFc != 0
        lastFc = -1
        z1 = 0
        z2 = 0
    }

    @inline(__always)
    mutating func release() {
        guard state == .playing else { return }
        state = .released
        sustained = false
        volEnv.noteOff()
        modEnv.noteOff()
        if loopMode == 3 { looping = false }
    }

    /// Fades out over `seconds` and frees the voice; used for stealing, exclusive classes and panic.
    @inline(__always)
    mutating func kill(seconds: Float, rate: Double) {
        guard state != .free else { return }
        let step = 1 / max(1, seconds * Float(rate))
        if state == .dying, fadeStep >= step { return }
        state = .dying
        fadeStep = step
    }

    /// Adds `count` frames (at most `block`) into the outputs. Frees the voice when it ends.
    @inline(__always)
    mutating func render(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        count: Int,
        channel: SF2Channel,
        rate: Float
    ) {
        guard let samples, count > 0 else { return }
        volEnv.advance(count)
        modEnv.advance(count)
        modLfo.advance(count)
        vibLfo.advance(count)

        var target = baseGain * volEnv.level * channel.gain
        if modLfoToVolume != 0 {
            target *= powf(10, -(modLfo.value * modLfoToVolume) / 200)
        }
        var finishing = volEnv.stage == .finished
        if state == .dying {
            fade -= fadeStep * Float(count)
            if fade <= 0 {
                fade = 0
                finishing = true
            }
            target *= fade
        }
        if finishing { target = 0 }

        let cents = baseCents + channel.bendCents + channel.tuneCents + modEnv.level * modEnvToPitch
            + modLfo.value * modLfoToPitch + vibLfo.value * vibLfoToPitch
        let increment = sampleRatio * exp2(Double(cents) / 1200)

        if filterOn {
            let fc = filterCents + modEnv.level * modEnvToFc + modLfo.value * modLfoToFc
            if abs(fc - lastFc) > 2 {
                lastFc = fc
                updateFilter(cents: fc, rate: rate)
            }
        }

        let step = (target - amp) / Float(count)
        var gain = amp
        var pos = position
        let loopLength = Double(loopEnd - loopStart)
        let loopEndD = Double(loopEnd)
        let endD = Double(end)
        var ended = false
        var y1 = z1
        var y2 = z2
        for frame in 0..<count {
            let index = Int(pos)
            let fraction = Float(pos - Double(index))
            let xm1: Float
            let x0: Float
            let x1: Float
            let x2: Float
            if looping, index + 2 >= loopEnd {
                let length = loopEnd - loopStart
                @inline(__always) func wrap(_ i: Int) -> Int { i >= loopEnd ? i - length : i }
                xm1 = Float(samples[wrap(index - 1)])
                x0 = Float(samples[wrap(index)])
                x1 = Float(samples[wrap(index + 1)])
                x2 = Float(samples[wrap(index + 2)])
            } else {
                xm1 = Float(samples[index - 1])
                x0 = Float(samples[index])
                x1 = Float(samples[index + 1])
                x2 = Float(samples[index + 2])
            }
            let c1 = 0.5 * (x1 - xm1)
            let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
            let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
            var sample = ((c3 * fraction + c2) * fraction + c1) * fraction + x0
            if filterOn {
                let out = b0 * sample + y1
                y1 = b1 * sample - a1 * out + y2
                y2 = b2 * sample - a2 * out
                sample = out
            }
            gain += step
            sample *= gain
            left[frame] += sample * panLeft
            right[frame] += sample * panRight
            pos += increment
            if looping {
                while pos >= loopEndD { pos -= loopLength }
            } else if pos >= endD - 1 {
                ended = true
                break
            }
        }
        z1 = y1
        z2 = y2
        position = pos
        amp = target
        if ended || finishing {
            state = .free
            self.samples = nil
        }
    }

    private mutating func updateFilter(cents: Float, rate: Float) {
        let hz = min(rate * 0.45, max(20, 8.176 * exp2f(cents / 1200)))
        let w0 = 2 * Float.pi * hz / rate
        let cosw = cosf(w0)
        let alpha = sinf(w0) / (2 * filterQ)
        let a0 = 1 + alpha
        b0 = (1 - cosw) / 2 / a0
        b1 = (1 - cosw) / a0
        b2 = b0
        a1 = -2 * cosw / a0
        a2 = (1 - alpha) / a0
    }
}
