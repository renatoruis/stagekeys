import AVFoundation
import Foundation

final class MetronomeEngine {
    private let players: [AVAudioPlayerNode]
    private var playerCursor = 0
    private var normalBuffer: AVAudioPCMBuffer?
    private var accentBuffer: AVAudioPCMBuffer?
    private let voicePlayers: [AVAudioPlayerNode]
    private var voiceBuffers: [AVAudioPCMBuffer?] = Array(repeating: nil, count: 4)
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "stagekeys.metronome", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var epoch: UInt64 = 0
    private var nextClick = 0
    private var nextClock = 0
    private var slaveTicks = 0
    private var lastSlaveTick: UInt64?
    private var output: MotorOutput?

    private var bpm: Double = 120
    private var beatsPerBar = 4
    private var subdivision = 1
    private var countInBars = 0
    private var running = false
    private var clockMode: ClockMode = .off
    private var volume: Float = 0.8
    private var accentEnabled = true
    private var countVoice = false
    private var countSpaced = false
    /// Click index of the bar where the current count-in starts, and its length in bars.
    private var countStart = 0
    private var countBars = 0
    /// A count-in asked for on the fly always speaks, whatever the voice setting.
    private var countForcesVoice = false

    var sendClock: (() -> Void)?
    var sendStart: (() -> Void)?
    var sendStop: (() -> Void)?
    var onPulse: ((Int, Bool, Bool) -> Void)?
    var onRunning: ((Bool) -> Void)?
    var onBPM: ((Double) -> Void)?

    init() {
        players = (0..<6).map { _ in AVAudioPlayerNode() }
        voicePlayers = (0..<4).map { _ in AVAudioPlayerNode() }
    }

    var meterNodes: [AVAudioNode] { output.map { [$0.mixer] } ?? [] }

    func install(on output: MotorOutput) {
        self.output = output
        let format = AudioBuffers.clickFormat
        for player in players + voicePlayers {
            output.attach(player)
            output.connect(player, to: output.mixer, format: format)
            player.volume = 1
        }
        output.mixer.outputVolume = volume
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func apply(settings: MetronomeSettings) {
        lock.lock()
        bpm = min(300, max(40, settings.bpm))
        beatsPerBar = settings.beatsPerBar == 6 ? 6 : 4
        subdivision = [1, 2, 3, 4].contains(settings.subdivision) ? settings.subdivision : 1
        countInBars = min(2, max(0, settings.countInBars))
        let modeChanged = clockMode != settings.clockMode
        clockMode = settings.clockMode
        accentEnabled = settings.accentEnabled
        countVoice = settings.countVoice
        countSpaced = settings.countSpaced
        volume = Float(min(1, max(0, settings.volume)))
        let wasRunning = running
        lock.unlock()
        output?.mixer.outputVolume = volume
        if modeChanged && wasRunning {
            stop()
            start()
        }
    }

    func setVolume(_ value: Float) {
        volume = value
        output?.mixer.outputVolume = value
    }

    func loadStyle(normal: URL, accent: URL) {
        let format = AudioBuffers.clickFormat
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let normalFile = try? AudioBuffers.readFile(normal),
                  let accentFile = try? AudioBuffers.readFile(accent),
                  let normalBuffer = try? AudioBuffers.convert(AudioBuffers.trimClick(normalFile), to: format),
                  let accentBuffer = try? AudioBuffers.convert(AudioBuffers.trimClick(accentFile), to: format) else { return }
            self?.lock.lock()
            self?.normalBuffer = normalBuffer
            self?.accentBuffer = accentBuffer
            self?.lock.unlock()
        }
    }

    func loadCountVoices(_ urls: [URL]) {
        let format = AudioBuffers.clickFormat
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let buffers: [AVAudioPCMBuffer?] = (0..<4).map { index in
                guard urls.indices.contains(index),
                      let file = try? AudioBuffers.readFile(urls[index]),
                      let converted = try? AudioBuffers.convert(file, to: format) else { return nil }
                return converted
            }
            self?.lock.lock()
            self?.voiceBuffers = buffers
            self?.lock.unlock()
        }
    }

    /// Song change. Off/Master restart from beat 1 so the count-in plays. Slave only rearms.
    func beginSong() {
        lock.lock()
        let mode = clockMode
        let active = running
        lock.unlock()
        if mode == .slave {
            rearmSlave()
            return
        }
        if active { stop() }
        start()
    }

    func start() {
        lock.lock()
        startLocked(forcedCount: false)
        let mode = clockMode
        lock.unlock()
        resume(mode: mode)
    }

    /// While running (not as slave): counts in from the next bar. Stopped: starts with a count-in.
    func countIn() {
        lock.lock()
        guard clockMode != .slave else {
            lock.unlock()
            return
        }
        guard running else {
            startLocked(forcedCount: true)
            let mode = clockMode
            lock.unlock()
            resume(mode: mode)
            return
        }
        let clicksPerBar = max(1, beatsPerBar * max(1, subdivision))
        countStart = (nextClick + clicksPerBar - 1) / clicksPerBar * clicksPerBar
        countBars = countLength(forced: true)
        countForcesVoice = true
        lock.unlock()
    }

    private func startLocked(forcedCount: Bool) {
        running = true
        epoch = HostClock.nowNanos()
        countStart = 0
        countBars = countLength(forced: forcedCount)
        countForcesVoice = forcedCount
        nextClick = 0
        nextClock = 0
        slaveTicks = 0
        lastSlaveTick = nil
    }

    /// Bars to count in. A spaced voice needs two bars to reach "4". Call with `lock` held.
    private func countLength(forced: Bool) -> Int {
        let bars = forced ? max(1, countInBars) : countInBars
        let spoken = countVoice || forced
        return bars > 0 && spoken && countSpaced ? max(2, bars) : bars
    }

    private func resume(mode: ClockMode) {
        for player in players + voicePlayers where !player.isPlaying {
            player.play()
        }
        if mode == .master { sendStart?() }
        onRunning?(true)
    }

    private func rearmSlave() {
        lock.lock()
        running = true
        epoch = HostClock.nowNanos()
        nextClick = 0
        nextClock = 0
        slaveTicks = 0
        lastSlaveTick = nil
        lock.unlock()
        for player in players + voicePlayers where !player.isPlaying {
            player.play()
        }
        onRunning?(true)
    }

    func stop() {
        lock.lock()
        let mode = clockMode
        running = false
        lock.unlock()
        if mode == .master { sendStop?() }
        for player in players + voicePlayers {
            player.stop()
        }
        onRunning?(false)
    }

    func toggle() {
        lock.lock()
        let active = running
        lock.unlock()
        if active { stop() } else { start() }
    }

    func tap() {
        queue.async { [weak self] in
            self?.registerTap()
        }
    }

    func handleClock(_ event: MIDIEvent) {
        lock.lock()
        guard clockMode == .slave else {
            lock.unlock()
            return
        }
        switch event.kind {
        case .start, .resume:
            running = true
            slaveTicks = 0
            lastSlaveTick = nil
            lock.unlock()
            for player in players where !player.isPlaying { player.play() }
            onRunning?(true)
        case .stop:
            running = false
            lock.unlock()
            onRunning?(false)
        case .clock:
            guard running else {
                lock.unlock()
                return
            }
            let now = HostClock.nowNanos()
            if let previous = lastSlaveTick, now > previous {
                let instant = 60_000_000_000 / (Double(now - previous) * 24)
                if instant.isFinite, instant > 20, instant < 400 {
                    bpm = min(300, max(40, bpm * 0.85 + instant * 0.15))
                    let published = bpm
                    lock.unlock()
                    onBPM?(published)
                    lock.lock()
                }
            }
            lastSlaveTick = now
            let sub = max(1, subdivision)
            let ticksPerClick = max(1, 24 / sub)
            let clicksPerBar = max(1, beatsPerBar * sub)
            let clickIndex = slaveTicks / ticksPerClick
            let shouldClick = slaveTicks % ticksPerClick == 0
            let position = clickIndex % clicksPerBar
            let accent = position == 0
            let playAccent = accent && accentEnabled
            let beat = position / sub + 1
            slaveTicks += 1
            lock.unlock()
            if shouldClick {
                schedule(accent: playAccent, hostTime: mach_absolute_time())
                onPulse?(beat, accent, false)
            }
        default:
            lock.unlock()
        }
    }

    private func registerTap() {
        struct Holder { static var taps: [UInt64] = [] }
        let now = HostClock.nowNanos()
        if let last = Holder.taps.last, now > last + 2_000_000_000 {
            Holder.taps.removeAll()
        }
        Holder.taps.append(now)
        if Holder.taps.count > 6 { Holder.taps.removeFirst() }
        guard Holder.taps.count >= 2 else { return }
        let intervals = zip(Holder.taps, Holder.taps.dropFirst()).map { Double($1 - $0) }
        let average = intervals.reduce(0, +) / Double(intervals.count)
        guard average > 0 else { return }
        let next = min(300, max(40, 60_000_000_000 / average))
        lock.lock()
        bpm = next
        lock.unlock()
        onBPM?(next)
    }

    private func tick() {
        lock.lock()
        let active = running
        let mode = clockMode
        let tempo = bpm
        let bar = beatsPerBar
        let sub = subdivision
        let countFrom = countStart
        let countLength = countBars
        let accentsOn = accentEnabled
        let voiceOn = countVoice || countForcesVoice
        let spaced = countSpaced
        let origin = epoch
        var clickIndex = nextClick
        var clockIndex = nextClock
        lock.unlock()
        guard active, mode != .slave else { return }

        let now = HostClock.nowNanos()
        let quarter = 60_000_000_000 / tempo
        let clickPeriod = quarter / Double(max(1, sub))
        let clockPeriod = quarter / 24
        let lookahead: UInt64 = 120_000_000

        if mode == .master {
            while HostClock.offset(origin, index: clockIndex, period: clockPeriod) + 20_000_000 < now {
                clockIndex += 1
            }
            while HostClock.offset(origin, index: clockIndex, period: clockPeriod) <= now + lookahead {
                sendClock?()
                clockIndex += 1
            }
        }

        while HostClock.offset(origin, index: clickIndex, period: clickPeriod) + 20_000_000 < now {
            clickIndex += 1
        }
        let clicksPerBar = max(1, bar * max(1, sub))
        let countInClicks = countLength * clicksPerBar
        while HostClock.offset(origin, index: clickIndex, period: clickPeriod) <= now + lookahead {
            let when = HostClock.offset(origin, index: clickIndex, period: clickPeriod)
            let position = clickIndex % clicksPerBar
            let accent = position == 0
            let beat = position / max(1, sub) + 1
            let counting = clickIndex >= countFrom && clickIndex < countFrom + countInClicks
            let hostTime = HostClock.host(fromNanos: when)
            schedule(accent: accent && accentsOn, hostTime: hostTime)
            if voiceOn, counting, position % max(1, sub) == 0 {
                // 4/4 groups beats in pairs, 6/8 in threes: "1 2 3 1 2 3" per beat, or one count per group when spaced.
                let group = bar == 6 ? 3 : 2
                let pulse = beat - 1
                if !spaced {
                    scheduleVoice(beat: bar == 6 ? pulse % 3 + 1 : beat, hostTime: hostTime)
                } else if pulse % group == 0 {
                    let barIndex = (clickIndex - countFrom) / clicksPerBar
                    scheduleVoice(beat: barIndex * (bar / group) + pulse / group + 1, hostTime: hostTime)
                }
            }
            onPulse?(beat, accent, counting)
            clickIndex += 1
        }

        lock.lock()
        if epoch == origin {
            nextClick = clickIndex
            nextClock = clockIndex
        }
        lock.unlock()
    }

    private func schedule(accent: Bool, hostTime: UInt64) {
        lock.lock()
        let buffer = accent ? (accentBuffer ?? normalBuffer) : normalBuffer
        lock.unlock()
        guard let buffer else { return }
        let player = players[playerCursor % players.count]
        playerCursor += 1
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: AVAudioTime(hostTime: hostTime), options: [], completionHandler: nil)
    }

    private func scheduleVoice(beat: Int, hostTime: UInt64) {
        guard (1...4).contains(beat) else { return }
        lock.lock()
        let buffer = voiceBuffers[beat - 1]
        lock.unlock()
        guard let buffer else { return }
        let player = voicePlayers[beat - 1]
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: AVAudioTime(hostTime: hostTime), options: [], completionHandler: nil)
    }
}

enum HostClock {
    private static let info: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    static func nowNanos() -> UInt64 {
        nanos(fromHost: mach_absolute_time())
    }

    static func nanos(fromHost host: UInt64) -> UInt64 {
        UInt64(Double(host) * Double(info.numer) / Double(info.denom))
    }

    static func host(fromNanos nanos: UInt64) -> UInt64 {
        UInt64(Double(nanos) * Double(info.denom) / Double(info.numer))
    }

    static func offset(_ epoch: UInt64, index: Int, period: Double) -> UInt64 {
        epoch + UInt64(max(0, Double(index) * period))
    }
}
