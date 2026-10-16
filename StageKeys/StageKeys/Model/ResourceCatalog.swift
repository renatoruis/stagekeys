import Foundation

struct SoundFontPreset: Identifiable, Equatable, Hashable {
    var bank: Int
    var program: Int
    var name: String

    var id: String { "\(bank):\(program)" }
}

struct SoundFont: Identifiable, Equatable {
    var id: String
    var name: String
    var category: String
    var subcategory: String?
    var url: URL
    var presets: [SoundFontPreset]

    func title(bank: Int, program: Int) -> String {
        guard presets.count > 1, let preset = presets.first(where: { $0.bank == bank && $0.program == program }) else { return name }
        return preset.name
    }
}

struct ResourceCatalog {
    var soundFonts: [SoundFont] = []
    var soundFontCategories: [String] = []

    private let soundsRoot: URL
    private let userRoot: URL

    init(userRoot: URL, soundsRoot: URL) {
        self.userRoot = userRoot
        self.soundsRoot = soundsRoot
        reload()
    }

    mutating func reload() {
        let fonts = loadSoundFonts()
        soundFonts = fonts.fonts
        soundFontCategories = fonts.categories
    }

    func url(for id: String) -> URL? {
        if id.hasPrefix("user/") {
            let relative = String(id.dropFirst("user/".count))
            let url = userRoot.appendingPathComponent(relative)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard id.hasPrefix("sf2/") else { return nil }
        let url = soundsRoot.appendingPathComponent(String(id.dropFirst("sf2/".count)))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func soundFont(_ id: String?) -> SoundFont? {
        guard let id else { return nil }
        return soundFonts.first { $0.id == id }
    }

    func importFile(from source: URL, kind: ImportKind) throws -> String {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let folder = userRoot.appendingPathComponent(kind.subpath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = uniqueDestination(folder: folder, name: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return "user/\(kind.subpath)/\(destination.lastPathComponent)"
    }

    /// Moves an imported file to the Trash; library sounds are removed through `SoundLibrary`.
    func removeImported(_ id: String) throws {
        guard id.hasPrefix("user/"), let url = url(for: id) else { return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    private func uniqueDestination(folder: URL, name: String) -> URL {
        let base = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: base.path) { return base }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = folder.appendingPathComponent("\(stem) \(index).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func loadSoundFonts() -> (fonts: [SoundFont], categories: [String]) {
        var fonts: [SoundFont] = []
        let library = files(in: soundsRoot, extensions: ["sf2"])
        let imported = files(in: userRoot.appendingPathComponent(ImportKind.soundFont.subpath), extensions: ["sf2"])
        for (url, prefix) in library.map({ ($0, "sf2") }) + imported.map({ ($0, "user/sf2") }) {
            let stem = url.deletingPathExtension().lastPathComponent
            let parsed = prefix == "sf2" ? Self.parseName(stem) : (category: Self.importedCategory, subcategory: nil, name: stem)
            let presets = SF2File.presetList(url: url)
                .filter { !Self.isHeading($0.name) }
                .map { SoundFontPreset(bank: $0.bank, program: $0.program, name: Self.cleanPresetName($0.name)) }
            guard !presets.isEmpty else { continue }
            fonts.append(SoundFont(
                id: "\(prefix)/\(url.lastPathComponent)", name: parsed.name, category: parsed.category,
                subcategory: parsed.subcategory, url: url, presets: presets
            ))
        }
        return (fonts, Self.orderedCategories(Set(fonts.map(\.category))))
    }

    /// `Categoria - Nome` or `Categoria - Subcategoria - Nome`; anything else lands in "Other".
    static func parseName(_ stem: String) -> (category: String, subcategory: String?, name: String) {
        let parts = stem.components(separatedBy: " - ")
        switch parts.count {
        case 1: return ("Other", nil, stem)
        case 2: return (parts[0], nil, parts[1])
        default: return (parts[0], parts[1], parts.dropFirst(2).joined(separator: " - "))
        }
    }

    static func orderedCategories(_ present: Set<String>) -> [String] {
        let preferred = ["Nord", "Piano", "Electric Piano", "Organ", "Pad", "Strings", "Synth", "Bell", "Vox", "Accordion", "FX", "Collection", importedCategory]
        return preferred.filter { present.contains($0) } + present.subtracting(preferred).sorted()
    }

    /// Sounds renamed into the Nord category; saved layers keep working.
    static let renamed: [String: String] = [
        "sf2/Piano - Blue Swede Upright.sf2": "sf2/Nord - Piano - Blue Swede Upright.sf2",
        "sf2/Piano - GP Grand.sf2": "sf2/Nord - Piano - GP Grand.sf2",
        "sf2/Piano - Custom Piano 1.sf2": "sf2/Nord - Piano - Stage Piano.sf2",
        "sf2/Piano - Grand Collection.sf2": "sf2/Nord - Piano - Grand Collection.sf2",
        "sf2/Pad - Custom Pad 1.sf2": "sf2/Nord - Pad - Pad 1.sf2",
        "sf2/Pad - Custom Pad 2.sf2": "sf2/Nord - Pad - Pad 2.sf2",
        "sf2/Synth - Custom Synth.sf2": "sf2/Nord - Synth - ALB.sf2",
    ]

    /// Author credits stored as presets in the Grand Collection bank.
    private static let creditPresets: Set<String> = ["Desenvolvido Por", "Arthyne Pereira"]

    /// Credits, separators (`____`) and `//` labels are silent menu entries, not sounds.
    static func isHeading(_ name: String) -> Bool {
        creditPresets.contains(name)
            || !name.contains(where: { $0.isLetter || $0.isNumber })
            || name.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// SF2 preset names are cut at 20 characters; drop a dangling " - No" style tail.
    static func cleanPresetName(_ raw: String) -> String {
        guard let range = raw.range(of: " - ", options: .backwards) else { return raw }
        let tail = raw[range.upperBound...]
        if tail.count <= 4 || tail == "Nord" { return String(raw[..<range.lowerBound]) }
        return raw
    }

    private func files(in folder: URL, extensions: [String]) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { extensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static let importedCategory = "Imported"

    static func noteName(_ note: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let clamped = min(127, max(0, note))
        return "\(names[clamped % 12])\(clamped / 12 - 1)"
    }
}

enum ImportKind {
    case soundFont

    var subpath: String { "sf2" }

    var allowedTypes: [String] { ["sf2"] }
}
