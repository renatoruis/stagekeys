import Foundation

struct LibrarySound: Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var url: URL
}

struct PadFamily: Identifiable, Equatable {
    var id: String
    var name: String
    var pitches: [String: String]

    func assetID(for pitch: String) -> String? {
        pitches[pitch]
    }

    var isImported: Bool { pitches.values.contains { $0.hasPrefix("user/") } }
}

struct ClickStyle: Identifiable, Equatable {
    var id: String
    var name: String
    var normalID: String
    var accentID: String
}

struct DrumSample: Identifiable, Equatable {
    var id: String
    var name: String
    var category: String
}

/// Old asset IDs from before the library rename, mapped to the current ones.
struct LegacyNames: Decodable {
    var assets: [String: String] = [:]
    var padFamilies: [String: String] = [:]
    var clickStyles: [String: String] = [:]

    func migrate(_ set: PerformanceSet) -> PerformanceSet {
        var next = set
        for index in next.drumPads.indices {
            if let id = next.drumPads[index].assetID, let renamed = assets[id] {
                next.drumPads[index].assetID = renamed
            }
        }
        for index in next.padLayers.indices {
            if let id = next.padLayers[index].familyID, let renamed = padFamilies[id] {
                next.padLayers[index].familyID = renamed
            }
        }
        if let renamed = clickStyles[next.metronome.styleID] {
            next.metronome.styleID = renamed
        }
        return next
    }
}

struct ResourceCatalog {
    var padFamilies: [PadFamily] = []
    var clickStyles: [ClickStyle] = []
    var drumSamples: [DrumSample] = []
    var drumCategories: [String] = []

    static let pitchTokens = ["C", "Cs", "D", "Ds", "E", "F", "Fs", "G", "Gs", "A", "As", "B"]
    static let pitchLabels = ["C": "C", "Cs": "C#", "D": "D", "Ds": "D#", "E": "E", "F": "F", "Fs": "F#", "G": "G", "Gs": "G#", "A": "A", "As": "A#", "B": "B"]
    static let audioExtensions = ["m4a", "wav", "aiff", "aif"]

    private let bundleRoot: URL?
    private let userRoot: URL

    init(userRoot: URL) {
        self.userRoot = userRoot
        bundleRoot = Self.locateBundleRoot()
        reload()
    }

    mutating func reload() {
        padFamilies = loadPadFamilies()
        clickStyles = loadClicks()
        let drums = loadDrums()
        drumSamples = drums.samples
        drumCategories = drums.categories
    }

    func url(for id: String) -> URL? {
        if id.hasPrefix("user/") {
            let relative = String(id.dropFirst("user/".count))
            let url = userRoot.appendingPathComponent(relative)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard let bundleRoot, let slash = id.firstIndex(of: "/") else { return nil }
        let head = String(id[..<slash])
        let tail = String(id[id.index(after: slash)...])
        let folder: String
        switch head {
        case "pads": folder = "Pads"
        case "metronome": folder = "Metronome"
        case "drumkits": folder = "DrumKits"
        case "voiceguide": folder = "VoiceGuide"
        default: folder = head
        }
        let url = bundleRoot.appendingPathComponent(folder).appendingPathComponent(tail)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func legacyNames() -> LegacyNames {
        guard let bundleRoot,
              let data = try? Data(contentsOf: bundleRoot.appendingPathComponent("renames.json")),
              let names = try? JSONDecoder().decode(LegacyNames.self, from: data) else { return LegacyNames() }
        return names
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

    private func loadSounds(folder: String, idPrefix: String, extensions: [String]) -> [LibrarySound] {
        guard let bundleRoot else { return [] }
        return files(in: bundleRoot.appendingPathComponent(folder), extensions: extensions).map { url in
            let name = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            return LibrarySound(id: "\(idPrefix)/\(url.lastPathComponent)", name: name, url: url)
        }
    }

    private func loadUserSounds(subpath: String, idPrefix: String, extensions: [String]) -> [LibrarySound] {
        files(in: userRoot.appendingPathComponent(subpath), extensions: extensions).map { url in
            let name = url.deletingPathExtension().lastPathComponent
            return LibrarySound(id: "\(idPrefix)/\(url.lastPathComponent)", name: name, url: url)
        }
    }

    private func loadPadFamilies() -> [PadFamily] {
        var grouped: [String: [String: String]] = [:]
        let bundled = loadSounds(folder: "Pads", idPrefix: "pads", extensions: Self.audioExtensions)
        let imported = loadUserSounds(subpath: "pads", idPrefix: "user/pads", extensions: Self.audioExtensions)
        for sound in bundled + imported {
            let stem = sound.url.deletingPathExtension().lastPathComponent
            if let split = Self.splitPad(stem: stem) {
                grouped[split.family, default: [:]][split.pitch] = sound.id
            } else {
                grouped[stem, default: [:]]["C"] = sound.id
            }
        }
        return grouped.keys.sorted().map { name in
            PadFamily(id: name, name: name, pitches: grouped[name] ?? [:])
        }
    }

    private func loadClicks() -> [ClickStyle] {
        guard let bundleRoot else { return [] }
        let urls = files(in: bundleRoot.appendingPathComponent("Metronome"), extensions: Self.audioExtensions)
        var normal: [String: String] = [:]
        var accent: [String: String] = [:]
        for url in urls {
            let stem = url.deletingPathExtension().lastPathComponent
            let id = "metronome/\(url.lastPathComponent)"
            if stem.lowercased().hasSuffix("_accent") {
                accent[String(stem.dropLast("_accent".count))] = id
            } else {
                normal[stem] = id
            }
        }
        return normal.keys.sorted().compactMap { key in
            guard let normalID = normal[key], let accentID = accent[key] else { return nil }
            return ClickStyle(id: key, name: key, normalID: normalID, accentID: accentID)
        }
    }

    private func loadDrums() -> (samples: [DrumSample], categories: [String]) {
        var samples: [DrumSample] = []
        if let bundleRoot {
            let root = bundleRoot.appendingPathComponent("DrumKits")
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let category = folder.lastPathComponent
                for url in files(in: folder, extensions: Self.audioExtensions) {
                    let name = url.deletingPathExtension().lastPathComponent
                    samples.append(DrumSample(id: "drumkits/\(category)/\(url.lastPathComponent)", name: name, category: category))
                }
            }
        }
        for url in files(in: userRoot.appendingPathComponent("drums"), extensions: Self.audioExtensions) {
            let name = url.deletingPathExtension().lastPathComponent
            samples.append(DrumSample(id: "user/drums/\(url.lastPathComponent)", name: name, category: Self.importedCategory))
        }
        let preferred = ["Kicks", "Snares", "Claps", "Snaps", "HiHats", "Shakers", "Tambourines", "Woods", "Percussion", "Subs", "FX", "Loops", Self.importedCategory]
        let present = Set(samples.map(\.category))
        let categories = preferred.filter { present.contains($0) } + present.subtracting(preferred).sorted()
        return (samples, categories)
    }

    private func files(in folder: URL, extensions: [String]) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { extensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static let importedCategory = "Imported"

    static func splitPad(stem: String) -> (family: String, pitch: String)? {
        let tokens = ["As", "Cs", "Ds", "Fs", "Gs", "A", "B", "C", "D", "E", "F", "G"]
        for token in tokens where stem.hasSuffix("_\(token)") {
            let family = String(stem.dropLast(token.count + 1))
            if !family.isEmpty { return (family, token) }
        }
        return nil
    }

    static func pitchToken(forMIDINote note: Int) -> String {
        pitchTokens[note % 12]
    }

    static func label(for pitch: String) -> String {
        pitchLabels[pitch] ?? pitch
    }

    static func categoryTitle(_ category: String) -> String {
        switch category {
        case "HiHats": "Hi-Hats"
        default: category
        }
    }

    static func noteName(_ note: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let clamped = min(127, max(0, note))
        return "\(names[clamped % 12])\(clamped / 12 - 1)"
    }

    private static func locateBundleRoot() -> URL? {
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("StageLibrary"),
            ProcessInfo.processInfo.environment["STAGEKEYS_RESOURCES"].map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources"),
        ]
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.appendingPathComponent("Pads").path) {
            return url
        }
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

enum ImportKind {
    case pad
    case drum

    var subpath: String {
        switch self {
        case .pad: "pads"
        case .drum: "drums"
        }
    }

    var allowedTypes: [String] {
        ["m4a", "wav", "aiff", "aif", "mp3", "caf"]
    }
}
