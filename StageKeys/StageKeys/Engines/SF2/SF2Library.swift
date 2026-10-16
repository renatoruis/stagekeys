import Foundation

/// Loads SF2 programs off the main thread and keeps them resident.
/// Pinned programs (previous, current and next song) are never evicted; the rest are kept LRU within `budget`.
final class SF2Library {
    struct Key: Hashable {
        var url: URL
        var bank: Int
        var program: Int
    }

    enum LoadState {
        case idle, loading, ready, failed
    }

    /// Bytes kept for programs outside the pinned set.
    var budget = 1_500_000_000
    var onChange: (() -> Void)?

    private var programs: [Key: SF2Program] = [:]
    private var lastUse: [Key: UInt64] = [:]
    private var clock: UInt64 = 0
    private var loading: Set<Key> = []
    private var failed: Set<Key> = []
    private var waiters: [Key: [(SF2Program?) -> Void]] = [:]
    private var pinned: Set<Key> = []
    private let queue = DispatchQueue(label: "stagekeys.sf2.loader", qos: .userInitiated)
    private var files: [URL: SF2File] = [:]

    // MARK: Main thread

    func program(_ key: Key) -> SF2Program? {
        guard let program = programs[key] else { return nil }
        touch(key)
        return program
    }

    func state(_ key: Key) -> LoadState {
        if programs[key] != nil { return .ready }
        if loading.contains(key) { return .loading }
        if failed.contains(key) { return .failed }
        return .idle
    }

    var residentBytes: Int { programs.values.reduce(0) { $0 + $1.byteSize } }

    /// Calls back on the main thread with the program, or nil when it cannot be loaded.
    func load(_ key: Key, completion: ((SF2Program?) -> Void)? = nil) {
        if let program = programs[key] {
            touch(key)
            completion?(program)
            return
        }
        if failed.contains(key) {
            completion?(nil)
            return
        }
        if let completion { waiters[key, default: []].append(completion) }
        guard !loading.contains(key) else { return }
        loading.insert(key)
        onChange?()
        queue.async { [weak self] in
            guard let self else { return }
            let program = self.build(key)
            DispatchQueue.main.async {
                self.finish(key, program: program)
            }
        }
    }

    /// Replaces the pinned set (in priority order) and starts loading what is missing.
    func pin(_ keys: [Key]) {
        pinned = Set(keys)
        for key in keys { load(key) }
        evict()
    }

    func forgetFailures() {
        failed.removeAll()
    }

    private func finish(_ key: Key, program: SF2Program?) {
        loading.remove(key)
        if let program {
            programs[key] = program
            touch(key)
        } else {
            failed.insert(key)
        }
        let callbacks = waiters.removeValue(forKey: key) ?? []
        for callback in callbacks { callback(program) }
        evict()
        onChange?()
    }

    private func touch(_ key: Key) {
        clock &+= 1
        lastUse[key] = clock
    }

    private func evict() {
        var loose = programs.filter { !pinned.contains($0.key) }
        var bytes = loose.values.reduce(0) { $0 + $1.byteSize }
        while bytes > budget, let oldest = loose.min(by: { (lastUse[$0.key] ?? 0) < (lastUse[$1.key] ?? 0) }) {
            bytes -= oldest.value.byteSize
            loose.removeValue(forKey: oldest.key)
            programs.removeValue(forKey: oldest.key)
            lastUse.removeValue(forKey: oldest.key)
        }
    }

    // MARK: Loader queue

    private func build(_ key: Key) -> SF2Program? {
        let file: SF2File
        if let cached = files[key.url] {
            file = cached
        } else {
            guard let opened = try? SF2File(url: key.url) else { return nil }
            files[key.url] = opened
            file = opened
        }
        guard let preset = file.preset(bank: key.bank, program: key.program) else { return nil }
        return try? SF2Program(file: file, preset: preset)
    }
}
