import Foundation

struct RigStore {
    let url: URL
    private let keysRoot: URL
    private let showRoot: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        keysRoot = support.appendingPathComponent("StageKeys", isDirectory: true)
        showRoot = support.appendingPathComponent("StageKeysPlay", isDirectory: true)
        url = keysRoot.appendingPathComponent("stage-rig.json")
        try? FileManager.default.createDirectory(at: keysRoot, withIntermediateDirectories: true)
    }

    /// Reads the unified rig, or builds it once from the two old apps and saves that.
    func load() -> Rig {
        if let rig = read(url) {
            return rig
        }
        let keysURL = FileManager.default.fileExists(atPath: keysRoot.appendingPathComponent("keys-rig.json").path)
            ? keysRoot.appendingPathComponent("keys-rig.json")
            : keysRoot.appendingPathComponent("rig.json")
        let rig = Rig.merged(keys: read(keysURL), show: read(showRoot.appendingPathComponent("rig.json")))
        save(rig)
        return rig
    }

    func save(_ rig: Rig) {
        write(rig, to: url)
    }

    private func read(_ url: URL) -> Rig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Rig.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
