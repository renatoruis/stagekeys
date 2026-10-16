import Foundation

struct SetStore {
    let root: URL
    let setsFolder: URL
    let libraryFolder: URL
    private let rigURL: URL
    private let orderURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("StageKeysPlay", isDirectory: true)
        Self.migrate(from: support.appendingPathComponent("StageKeys", isDirectory: true), to: base)
        root = base
        setsFolder = base.appendingPathComponent("Sets", isDirectory: true)
        libraryFolder = base.appendingPathComponent("Library", isDirectory: true)
        rigURL = base.appendingPathComponent("rig.json")
        orderURL = base.appendingPathComponent("sets-order.json")
        try? FileManager.default.createDirectory(at: setsFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
    }

    /// First launch after the split: copies songs, rig, imported pads/drums and pad Space settings from the combined app.
    /// The old folder is left untouched (StageKeys still reads it).
    private static func migrate(from old: URL, to base: URL) {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: base.path), manager.fileExists(atPath: old.path) else { return }
        try? manager.createDirectory(at: base.appendingPathComponent("Library", isDirectory: true), withIntermediateDirectories: true)
        for item in ["Sets", "sets-order.json", "rig.json", "Supermassive-Pads.plist", "Library/pads", "Library/drums"] {
            let source = old.appendingPathComponent(item)
            guard manager.fileExists(atPath: source.path) else { continue }
            try? manager.copyItem(at: source, to: base.appendingPathComponent(item))
        }
    }

    func loadRig() -> Rig {
        guard let data = try? Data(contentsOf: rigURL),
              let rig = try? JSONDecoder().decode(Rig.self, from: data) else { return Rig() }
        return rig
    }

    func saveRig(_ rig: Rig) {
        write(rig, to: rigURL)
    }

    func loadSets() -> [PerformanceSet] {
        let files = (try? FileManager.default.contentsOfDirectory(at: setsFolder, includingPropertiesForKeys: nil)) ?? []
        var byID: [UUID: PerformanceSet] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let set = try? JSONDecoder().decode(PerformanceSet.self, from: data) else { continue }
            byID[set.id] = set.normalized()
        }
        let order = loadOrder().filter { byID[$0] != nil }
        let missing = byID.keys.filter { !order.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        return (order + missing).compactMap { byID[$0] }
    }

    func save(_ set: PerformanceSet) {
        write(set.normalized(), to: setsFolder.appendingPathComponent("\(set.id.uuidString).json"))
    }

    func delete(id: UUID) {
        let url = setsFolder.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    func saveOrder(_ ids: [UUID]) {
        write(ids, to: orderURL)
    }

    private func loadOrder() -> [UUID] {
        guard let data = try? Data(contentsOf: orderURL),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return ids
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
