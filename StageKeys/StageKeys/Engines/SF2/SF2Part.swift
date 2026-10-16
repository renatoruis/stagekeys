import Foundation

struct KeyEvent {
    enum Kind: UInt8 {
        case none, noteOn, noteOff, control, pitchBend, allNotesOff, panic
    }

    var kind: Kind = .none
    var data1: UInt8 = 0
    var data2: UInt8 = 0
    /// mach host ticks when the message arrived; 0 plays at the start of the next buffer.
    var host: UInt64 = 0
}

enum VelocityCurve: String, Codable, CaseIterable {
    case normal, soft, hard, fixed

    var title: String { rawValue.capitalized }
}

/// One of the four Keys slots: a voice pool playing one program.
/// MIDI threads push `KeyEvent`s, the main thread posts `Control` and program slots, the render thread owns everything else.
final class SF2Part {
    static let polyphony = 160
    static let voiceCapacity = polyphony + 32
    static let programSlots = 8
    static let eventCapacity = 1024

    struct Control {
        var slot: Int32 = -1
        var enabled = true
        var gain: Float = 0.64
        var transpose: Int32 = 0
        var octave: Int32 = 0
        var followsSustain = true
        var velocityCurve = VelocityCurve.normal
        var followsBend = true
        var tuneCents: Float = 0
        /// -1 (left) … 1 (right).
        var pan: Float = 0
        var sampleRate: Double = 48000
    }

    struct Report {
        var seenVersion = 0
        var inUseMask: UInt32 = 0
        var activeVoices: Int32 = 0
        var keysLow: UInt64 = 0
        var keysHigh: UInt64 = 0
        var sustain = false
        /// -1…1.
        var bend: Float = 0
        var modWheel: Float = 0
        var renderNanos: Double = 0
        var bufferNanos: Double = 0
    }

    private struct State {
        var control = Control()
        var seen = 0
        var view = SF2ProgramView.empty
        var channel = SF2Channel()
        var age: UInt64 = 0
        var report = Report()
    }

    let events = EventRing<KeyEvent>(capacity: eventCapacity, empty: KeyEvent())
    let mailbox = RTMailbox<Control, Report>(control: Control(), report: Report())

    private let state: UnsafeMutablePointer<State>
    private let voices: UnsafeMutablePointer<SF2Voice>
    private let pending: UnsafeMutablePointer<KeyEvent>
    private let views: UnsafeMutablePointer<SF2ProgramView>
    private var programs: [SF2Program?] = Array(repeating: nil, count: programSlots)
    private var waiting: SF2Program?
    private var hasWaiting = false

    init() {
        state = .allocate(capacity: 1)
        state.initialize(to: State())
        voices = .allocate(capacity: Self.voiceCapacity)
        voices.initialize(repeating: SF2Voice(), count: Self.voiceCapacity)
        pending = .allocate(capacity: Self.eventCapacity)
        pending.initialize(repeating: KeyEvent(), count: Self.eventCapacity)
        views = .allocate(capacity: Self.programSlots)
        views.initialize(repeating: .empty, count: Self.programSlots)
    }

    deinit {
        state.deinitialize(count: 1)
        state.deallocate()
        voices.deinitialize(count: Self.voiceCapacity)
        voices.deallocate()
        pending.deinitialize(count: Self.eventCapacity)
        pending.deallocate()
        views.deinitialize(count: Self.programSlots)
        views.deallocate()
    }

    // MARK: Main thread

    /// The program currently assigned (it may still be waiting for a free slot).
    private(set) var program: SF2Program?

    func setProgram(_ next: SF2Program?) {
        guard next !== program else { return }
        program = next
        collect()
        guard let next else {
            hasWaiting = false
            waiting = nil
            mailbox.post { $0.slot = -1 }
            return
        }
        guard let free = programs.firstIndex(where: { $0 == nil }) else {
            waiting = next
            hasWaiting = true
            return
        }
        hasWaiting = false
        waiting = nil
        programs[free] = next
        views[free] = next.view
        mailbox.post { $0.slot = Int32(free) }
    }

    func update(_ body: (inout Control) -> Void) {
        mailbox.post(body)
    }

    /// Releases programs the render thread no longer reads. Call periodically on the main thread.
    /// `renderStopped` is only valid while the engine is stopped: voices are dropped and nothing is in use.
    func collect(renderStopped: Bool = false) {
        let snapshot = mailbox.read()
        if renderStopped {
            for index in 0..<Self.voiceCapacity { voices[index] = SF2Voice() }
        } else if snapshot.report.seenVersion != snapshot.version {
            return
        }
        let mask = renderStopped ? 0 : snapshot.report.inUseMask
        for index in programs.indices where programs[index] != nil {
            let busy = mask & (1 << UInt32(index)) != 0
            if Int32(index) != snapshot.control.slot, !busy {
                views[index] = .empty
                programs[index] = nil
            }
        }
        if hasWaiting, let free = programs.firstIndex(where: { $0 == nil }), let next = waiting {
            hasWaiting = false
            waiting = nil
            programs[free] = next
            views[free] = next.view
            mailbox.post { $0.slot = Int32(free) }
        }
    }

    var report: Report { mailbox.read().report }

    // MARK: Any thread

    func send(_ event: KeyEvent) {
        events.push(event)
    }

    // MARK: Render thread

    /// Renders `frames` into two (non-interleaved) channels, overwriting them. Returns false when silent.
    @discardableResult
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        let started = HostTime.now()
        let s = state
        if mailbox.fetch(into: &s.pointee.control, seen: &s.pointee.seen) {
            applyControl()
        }
        let rate = s.pointee.control.sampleRate
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)

        let count = events.drain(into: pending, limit: Self.eventCapacity)
        let bufferTicks = Double(frames) / rate * 1e9 / HostTime.nanosPerTick
        let windowStart = Double(started) - bufferTicks
        let framesPerTick = HostTime.nanosPerTick * 1e-9 * rate

        var cursor = 0
        var lastOffset = 0
        for index in 0..<count {
            let event = pending[index]
            var offset = 0
            if event.host != 0 {
                offset = Int((Double(event.host) - windowStart) * framesPerTick)
                offset = min(frames - 1, max(lastOffset, offset))
            }
            if offset > cursor {
                renderVoices(from: cursor, to: offset, left: left, right: right)
                cursor = offset
            }
            lastOffset = offset
            handle(event)
        }
        if cursor < frames {
            renderVoices(from: cursor, to: frames, left: left, right: right)
        }
        let pan = s.pointee.control.pan
        if pan != 0 {
            let side = pan > 0 ? left : right
            let gain = 1 - abs(pan)
            for frame in 0..<frames { side[frame] *= gain }
        }

        var active: Int32 = 0
        var mask: UInt32 = 0
        var low: UInt64 = 0
        var high: UInt64 = 0
        let slot = s.pointee.control.slot
        if slot >= 0 { mask |= 1 << UInt32(slot) }
        for index in 0..<Self.voiceCapacity where voices[index].isActive {
            let voice = voices[index]
            active += 1
            mask |= 1 << UInt32(voice.programSlot)
            if voice.state == .playing && !voice.sustained {
                let key = voice.noteKey
                if key < 64 { low |= 1 << UInt64(key) } else { high |= 1 << UInt64(key - 64) }
            }
        }
        s.pointee.report.seenVersion = s.pointee.seen
        s.pointee.report.inUseMask = mask
        s.pointee.report.activeVoices = active
        s.pointee.report.keysLow = low
        s.pointee.report.keysHigh = high
        s.pointee.report.sustain = s.pointee.channel.pedal
        s.pointee.report.bend = s.pointee.channel.bendCents / 200
        s.pointee.report.modWheel = s.pointee.channel.modWheel
        s.pointee.report.renderNanos = Double(HostTime.now() - started) * HostTime.nanosPerTick
        s.pointee.report.bufferNanos = Double(frames) / rate * 1e9
        mailbox.publish(&s.pointee.report)
        return active > 0
    }

    @inline(__always)
    private func applyControl() {
        let s = state
        let control = s.pointee.control
        let slot = Int(control.slot)
        s.pointee.view = slot >= 0 && slot < Self.programSlots ? views[slot] : .empty
        updateGain()
        if !control.enabled {
            for index in 0..<Self.voiceCapacity where voices[index].state == .playing {
                voices[index].release()
            }
        }
        setSustain(s.pointee.channel.pedal && control.followsSustain)
        s.pointee.channel.tuneCents = control.tuneCents
        if !control.followsBend { s.pointee.channel.bendCents = 0 }
    }

    @inline(__always)
    private func setSustain(_ on: Bool) {
        state.pointee.channel.sustain = on
        guard !on else { return }
        for index in 0..<Self.voiceCapacity where voices[index].sustained {
            voices[index].release()
        }
    }

    /// Applied before region selection, so velocity layers follow the curve too.
    static func shapeVelocity(_ velocity: Int, _ curve: VelocityCurve) -> Int {
        let exponent: Double
        switch curve {
        case .normal: return velocity
        case .fixed: return 100
        case .soft: exponent = 0.6
        case .hard: exponent = 1.6
        }
        let shaped = 127 * pow(Double(velocity) / 127, exponent)
        return min(127, max(1, Int(shaped.rounded())))
    }

    @inline(__always)
    private func updateGain() {
        let s = state
        let channel = s.pointee.channel
        s.pointee.channel.gain = s.pointee.control.gain * channel.volume * channel.expression
    }

    @inline(__always)
    private func renderVoices(from start: Int, to end: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let channel = state.pointee.channel
        let rate = Float(state.pointee.control.sampleRate)
        var frame = start
        while frame < end {
            let count = min(SF2Voice.block, end - frame)
            for index in 0..<Self.voiceCapacity where voices[index].isActive {
                voices[index].render(left: left + frame, right: right + frame, count: count, channel: channel, rate: rate)
            }
            frame += count
        }
    }

    @inline(__always)
    private func handle(_ event: KeyEvent) {
        switch event.kind {
        case .noteOn:
            if event.data2 == 0 { noteOff(Int(event.data1)) } else { noteOn(Int(event.data1), velocity: Int(event.data2)) }
        case .noteOff:
            noteOff(Int(event.data1))
        case .control:
            control(Int(event.data1), Int(event.data2))
        case .pitchBend:
            guard state.pointee.control.followsBend else { return }
            let value = (Int(event.data2) << 7 | Int(event.data1)) - 8192
            state.pointee.channel.bendCents = Float(value) / 8192 * 200
        case .allNotesOff:
            allNotesOff()
        case .panic:
            killAll(seconds: 0.005)
            state.pointee.channel.pedal = false
            state.pointee.channel.sustain = false
        case .none:
            break
        }
    }

    @inline(__always)
    private func noteOn(_ key: Int, velocity raw: Int) {
        let s = state
        let control = s.pointee.control
        guard control.enabled else { return }
        let velocity = Self.shapeVelocity(raw, control.velocityCurve)
        let view = s.pointee.view
        guard let regions = view.regions, let keyStart = view.keyStart, let keyCount = view.keyCount,
              let keyRegions = view.keyRegions, let samples = view.samples else { return }
        let played = key + Int(control.transpose) + 12 * Int(control.octave)
        guard played >= 0, played <= 127 else { return }
        let rate = control.sampleRate

        for index in 0..<Self.voiceCapacity where voices[index].isActive && Int(voices[index].noteKey) == key {
            if voices[index].state == .released || voices[index].sustained {
                voices[index].kill(seconds: 0.15, rate: rate)
            }
        }

        let first = Int(keyStart[played])
        let total = Int(keyCount[played])
        for position in first..<first + total {
            let region = regions[Int(keyRegions[position])]
            guard velocity >= Int(region.velLo), velocity <= Int(region.velHi) else { continue }
            if region.exclusiveClass != 0 {
                for index in 0..<Self.voiceCapacity where voices[index].isActive && voices[index].exclusiveClass == region.exclusiveClass {
                    voices[index].kill(seconds: 0.005, rate: rate)
                }
            }
            let index = allocateVoice(rate: rate)
            s.pointee.age &+= 1
            voices[index].start(
                region: region,
                samples: samples,
                key: played,
                noteKey: key,
                velocity: velocity,
                outputRate: rate,
                age: s.pointee.age,
                slot: UInt8(control.slot)
            )
        }
    }

    /// A free voice; otherwise steals the quietest released voice or the oldest one (it fades out in 5 ms elsewhere).
    @inline(__always)
    private func allocateVoice(rate: Double) -> Int {
        var sounding = 0
        var free = -1
        var released = -1
        var releasedLevel = Float.greatestFiniteMagnitude
        var oldest = -1
        var oldestAge = UInt64.max
        for index in 0..<Self.voiceCapacity {
            let voice = voices[index]
            switch voice.state {
            case .free:
                if free < 0 { free = index }
            case .released:
                sounding += 1
                if voice.loudness < releasedLevel {
                    releasedLevel = voice.loudness
                    released = index
                }
            case .playing:
                sounding += 1
                if voice.age < oldestAge {
                    oldestAge = voice.age
                    oldest = index
                }
            case .dying:
                break
            }
        }
        if sounding >= Self.polyphony {
            let victim = released >= 0 ? released : oldest
            if victim >= 0 { voices[victim].kill(seconds: 0.005, rate: rate) }
        }
        if free >= 0 { return free }
        // Pool exhausted (spare voices all fading): reuse the quietest candidate outright.
        return released >= 0 ? released : (oldest >= 0 ? oldest : 0)
    }

    @inline(__always)
    private func noteOff(_ key: Int) {
        let sustain = state.pointee.channel.sustain
        for index in 0..<Self.voiceCapacity where voices[index].state == .playing && Int(voices[index].noteKey) == key && !voices[index].sustained {
            if sustain { voices[index].sustained = true } else { voices[index].release() }
        }
    }

    @inline(__always)
    private func allNotesOff() {
        state.pointee.channel.sustain = false
        for index in 0..<Self.voiceCapacity where voices[index].state == .playing {
            voices[index].release()
        }
    }

    @inline(__always)
    private func killAll(seconds: Float) {
        let rate = state.pointee.control.sampleRate
        for index in 0..<Self.voiceCapacity where voices[index].isActive {
            voices[index].kill(seconds: seconds, rate: rate)
        }
    }

    @inline(__always)
    private func control(_ number: Int, _ value: Int) {
        let s = state
        switch number {
        case 1:
            s.pointee.channel.modWheel = Float(value) / 127
        case 7:
            let level = Float(value) / 127
            s.pointee.channel.volume = level * level
            updateGain()
        case 11:
            let level = Float(value) / 127
            s.pointee.channel.expression = level * level
            updateGain()
        case 64:
            s.pointee.channel.pedal = value >= 64
            setSustain(s.pointee.channel.pedal && s.pointee.control.followsSustain)
        case 120:
            killAll(seconds: 0.01)
        case 121:
            s.pointee.channel.modWheel = 0
            s.pointee.channel.bendCents = 0
            s.pointee.channel.expression = 1
            s.pointee.channel.pedal = false
            s.pointee.channel.sustain = false
            updateGain()
            for index in 0..<Self.voiceCapacity where voices[index].sustained {
                voices[index].release()
            }
        case 123:
            allNotesOff()
        default:
            break
        }
    }
}
