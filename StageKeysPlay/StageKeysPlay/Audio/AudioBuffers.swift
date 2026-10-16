import AVFoundation

enum AudioBuffers {
    static func readFile(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let capacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioBufferError.unreadable
        }
        try file.read(into: buffer)
        return buffer
    }

    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw AudioBufferError.unreadable
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioBufferError.unreadable
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return output
    }

    static func trimClick(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let channels = buffer.floatChannelData else { return buffer }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return buffer }
        var peak: Float = 0
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                peak = max(peak, abs(channels[channel][frame]))
            }
        }
        let threshold = max(peak * 0.02, 0.001)
        var last = 0
        for frame in 0..<frameCount {
            for channel in 0..<channelCount where abs(channels[channel][frame]) >= threshold {
                last = frame
            }
        }
        let tail = Int(buffer.format.sampleRate * 0.02)
        let keep = min(frameCount, max(last + tail + 1, Int(buffer.format.sampleRate * 0.01)))
        guard keep < frameCount,
              let trimmed = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(keep)) else { return buffer }
        for channel in 0..<channelCount {
            trimmed.floatChannelData?[channel].update(from: channels[channel], count: keep)
        }
        trimmed.frameLength = AVAudioFrameCount(keep)
        return trimmed
    }

    static let clickFormat: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    /// Decodes into non-interleaved stereo float at `rate`. Mono files are copied to both channels.
    static func readStereo(_ url: URL, rate: Double) throws -> AVAudioPCMBuffer {
        let raw = try readFile(url)
        let channels = min(2, max(1, raw.format.channelCount))
        guard let target = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels) else {
            throw AudioBufferError.unreadable
        }
        let fitted = try convert(raw, to: target)
        guard channels == 1 else { return fitted }
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let output = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: fitted.frameLength),
              let source = fitted.floatChannelData, let destination = output.floatChannelData else {
            throw AudioBufferError.unreadable
        }
        let frames = Int(fitted.frameLength)
        destination[0].update(from: source[0], count: frames)
        destination[1].update(from: source[0], count: frames)
        output.frameLength = fitted.frameLength
        return output
    }
}

/// Decoded audio shared by the pad and drum engines. Pinned files stay resident; the rest are LRU within `budget`.
/// Completions run on the main thread.
final class AudioBufferCache {
    private struct Key: Hashable {
        var path: String
        var rate: Int
    }

    var budget = 1_200_000_000

    private let lock = NSLock()
    private var buffers: [Key: AVAudioPCMBuffer] = [:]
    private var lastUse: [Key: UInt64] = [:]
    private var clock: UInt64 = 0
    private var groups: [String: Set<Key>] = [:]
    private var waiters: [Key: [(AVAudioPCMBuffer?) -> Void]] = [:]
    private var failed: Set<Key> = []
    private let demand = DispatchQueue(label: "stagekeys.buffers.demand", qos: .userInitiated, attributes: .concurrent)
    private let prefetch = DispatchQueue(label: "stagekeys.buffers.prefetch", qos: .utility)

    /// Any thread.
    func cached(_ url: URL, rate: Double) -> AVAudioPCMBuffer? {
        let key = Key(path: url.path, rate: Int(rate.rounded()))
        lock.lock()
        defer { lock.unlock() }
        guard let buffer = buffers[key] else { return nil }
        clock &+= 1
        lastUse[key] = clock
        return buffer
    }

    /// Main thread.
    func load(_ url: URL, rate: Double, completion: ((AVAudioPCMBuffer?) -> Void)? = nil) {
        request(url, rate: rate, queue: demand, completion: completion)
    }

    /// Main thread. Replaces the pinned files of `group` and decodes the missing ones in the background, in order.
    func pin(_ urls: [URL], rate: Double, group: String) {
        let keys = urls.map { Key(path: $0.path, rate: Int(rate.rounded())) }
        lock.lock()
        groups[group] = Set(keys)
        lock.unlock()
        for url in urls {
            request(url, rate: rate, queue: prefetch, completion: nil)
        }
        evict()
    }

    private func request(_ url: URL, rate: Double, queue: DispatchQueue, completion: ((AVAudioPCMBuffer?) -> Void)?) {
        let key = Key(path: url.path, rate: Int(rate.rounded()))
        lock.lock()
        if let buffer = buffers[key] {
            clock &+= 1
            lastUse[key] = clock
            lock.unlock()
            completion?(buffer)
            return
        }
        if failed.contains(key) {
            lock.unlock()
            completion?(nil)
            return
        }
        let started = waiters[key] != nil
        waiters[key, default: []].append(completion ?? { _ in })
        lock.unlock()
        guard !started else { return }
        queue.async { [weak self] in
            let buffer = try? AudioBuffers.readStereo(url, rate: rate)
            DispatchQueue.main.async {
                self?.finish(key, buffer: buffer)
            }
        }
    }

    private func finish(_ key: Key, buffer: AVAudioPCMBuffer?) {
        lock.lock()
        if let buffer {
            buffers[key] = buffer
            clock &+= 1
            lastUse[key] = clock
        } else {
            failed.insert(key)
        }
        let callbacks = waiters.removeValue(forKey: key) ?? []
        lock.unlock()
        for callback in callbacks { callback(buffer) }
        evict()
    }

    private func evict() {
        lock.lock()
        defer { lock.unlock() }
        let pinned = groups.values.reduce(into: Set<Key>()) { $0.formUnion($1) }
        var loose = buffers.keys.filter { !pinned.contains($0) }
        var bytes = loose.reduce(0) { $0 + Self.size(buffers[$1]) }
        guard bytes > budget else { return }
        loose.sort { (lastUse[$0] ?? 0) < (lastUse[$1] ?? 0) }
        for key in loose where bytes > budget {
            bytes -= Self.size(buffers[key])
            buffers.removeValue(forKey: key)
            lastUse.removeValue(forKey: key)
        }
    }

    private static func size(_ buffer: AVAudioPCMBuffer?) -> Int {
        guard let buffer else { return 0 }
        return Int(buffer.frameLength) * Int(buffer.format.channelCount) * MemoryLayout<Float>.size
    }
}

enum AudioBufferError: Error {
    case unreadable
}
