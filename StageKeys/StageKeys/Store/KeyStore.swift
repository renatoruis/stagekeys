import Foundation

struct KeyStore {
    let root: URL
    let libraryFolder: URL
    private let stateURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StageKeys", isDirectory: true)
        root = base
        libraryFolder = base.appendingPathComponent("Library", isDirectory: true)
        stateURL = base.appendingPathComponent("keys.json")
        try? FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
    }

    func loadState() -> KeyState {
        guard let data = try? Data(contentsOf: stateURL),
              var state = try? JSONDecoder().decode(KeyState.self, from: data) else { return KeyState() }
        for index in state.keySlots.indices {
            if let id = state.keySlots[index].fileID, let renamed = SF2Catalog.renamed[id] {
                state.keySlots[index].fileID = renamed
            }
        }
        return state.normalized()
    }

    func saveState(_ state: KeyState) {
        write(state.normalized(), to: stateURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
