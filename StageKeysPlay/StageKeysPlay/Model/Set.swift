import Foundation

enum ClockMode: String, Codable, CaseIterable, Identifiable {
    case off
    case master
    case slave

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .master: "Master"
        case .slave: "Slave"
        }
    }
}

struct MetronomeSettings: Codable, Equatable {
    var bpm: Double = 120
    var beatsPerBar: Int = 4
    var subdivision: Int = 1
    var countInBars: Int = 0
    var volume: Double = 0.8
    var styleID: String = "Classic"
    var clockMode: ClockMode = .off
    var accentEnabled: Bool = true
    var countVoice: Bool = false
    /// Voice on every other beat (4/4) or every dotted quarter (6/8), counting across the count-in.
    var countSpaced: Bool = false
}

struct PadLayer: Codable, Equatable {
    var familyID: String?
    var pitch: String = "C"
    var volume: Double = 0.7
    var playing: Bool = false
    var enabled: Bool = false
    var followMIDI: Bool = true
    /// Effect amounts: nil until the knob is first moved, so the loop plays untouched.
    var cutoff: Double?
    /// Send into the user-installed Valhalla Supermassive.
    var space: Double?
}

enum DrumColor: String, Codable, CaseIterable, Identifiable {
    case stone
    case blue
    case green
    case amber
    case pink
    case violet
    case red
    case white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stone: "Stone"
        case .blue: "Blue"
        case .green: "Green"
        case .amber: "Amber"
        case .pink: "Pink"
        case .violet: "Violet"
        case .red: "Red"
        case .white: "White"
        }
    }
}

struct DrumPad: Codable, Equatable {
    var assetID: String?
    var gain: Double = 0.9
    /// nil until the knob is first moved.
    var reverb: Double?
    var color: String = DrumColor.stone.rawValue
}

struct PerformanceScene: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
}

struct MacroControl: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
}

struct PerformanceSet: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var metronome: MetronomeSettings
    var padPitch: String = "C"
    var padsRunning = false
    /// Level of all four pads together, after their own faders.
    var padMaster: Double = 1
    var padLayers: [PadLayer]
    var drumLayout: Int = 8
    var drumPads: [DrumPad]
    var scenes: [PerformanceScene] = []
    var macros: [MacroControl] = []

    static func make(name: String) -> PerformanceSet {
        PerformanceSet(
            id: UUID(),
            name: name,
            metronome: MetronomeSettings(),
            padLayers: Array(repeating: PadLayer(), count: PadEngine.layerCount),
            drumPads: Array(repeating: DrumPad(), count: DrumEngine.padCount)
        )
    }

    func normalized() -> PerformanceSet {
        var copy = self
        copy.padLayers = normalize(copy.padLayers, count: PadEngine.layerCount, fill: PadLayer())
        copy.drumPads = normalize(copy.drumPads, count: DrumEngine.padCount, fill: DrumPad())
        copy.metronome.bpm = ((min(300, max(40, copy.metronome.bpm)) * 2).rounded()) / 2
        copy.metronome.beatsPerBar = copy.metronome.beatsPerBar == 6 ? 6 : 4
        if ![1, 2, 3, 4].contains(copy.metronome.subdivision) {
            copy.metronome.subdivision = 1
        }
        copy.metronome.countInBars = min(2, max(0, copy.metronome.countInBars))
        if copy.padPitch.isEmpty {
            copy.padPitch = copy.padLayers.first?.pitch ?? "C"
        }
        if ![4, 6, 8].contains(copy.drumLayout) {
            copy.drumLayout = 8
        }
        return copy
    }

    private func normalize<T>(_ values: [T], count: Int, fill: T) -> [T] {
        var result = values
        if result.count < count {
            result.append(contentsOf: Array(repeating: fill, count: count - result.count))
        }
        return Array(result.prefix(count))
    }
}

struct SetListItem: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
}

extension MetronomeSettings {
    enum CodingKeys: String, CodingKey {
        case bpm, beatsPerBar, subdivision, countInBars, volume, styleID, clockMode, accentEnabled, countVoice, countSpaced
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bpm = try container.decodeIfPresent(Double.self, forKey: .bpm) ?? 120
        beatsPerBar = try container.decodeIfPresent(Int.self, forKey: .beatsPerBar) ?? 4
        subdivision = try container.decodeIfPresent(Int.self, forKey: .subdivision) ?? 1
        countInBars = try container.decodeIfPresent(Int.self, forKey: .countInBars) ?? 0
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8
        styleID = try container.decodeIfPresent(String.self, forKey: .styleID) ?? "Classic"
        clockMode = try container.decodeIfPresent(ClockMode.self, forKey: .clockMode) ?? .off
        accentEnabled = try container.decodeIfPresent(Bool.self, forKey: .accentEnabled) ?? true
        countVoice = try container.decodeIfPresent(Bool.self, forKey: .countVoice) ?? false
        countSpaced = try container.decodeIfPresent(Bool.self, forKey: .countSpaced) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bpm, forKey: .bpm)
        try container.encode(beatsPerBar, forKey: .beatsPerBar)
        try container.encode(subdivision, forKey: .subdivision)
        try container.encode(countInBars, forKey: .countInBars)
        try container.encode(volume, forKey: .volume)
        try container.encode(styleID, forKey: .styleID)
        try container.encode(clockMode, forKey: .clockMode)
        try container.encode(accentEnabled, forKey: .accentEnabled)
        try container.encode(countVoice, forKey: .countVoice)
        try container.encode(countSpaced, forKey: .countSpaced)
    }
}

extension PadLayer {
    enum CodingKeys: String, CodingKey {
        case familyID, pitch, volume, playing, enabled, followMIDI, cutoff, space
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        familyID = try container.decodeIfPresent(String.self, forKey: .familyID)
        pitch = try container.decodeIfPresent(String.self, forKey: .pitch) ?? "C"
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.7
        playing = try container.decodeIfPresent(Bool.self, forKey: .playing) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? playing
        followMIDI = try container.decodeIfPresent(Bool.self, forKey: .followMIDI) ?? true
        cutoff = try container.decodeEffect(.cutoff, neutral: 1)
        space = try container.decodeEffect(.space, neutral: 0)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(familyID, forKey: .familyID)
        try container.encode(pitch, forKey: .pitch)
        try container.encode(volume, forKey: .volume)
        try container.encode(playing, forKey: .playing)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(followMIDI, forKey: .followMIDI)
        try container.encodeIfPresent(cutoff, forKey: .cutoff)
        try container.encodeIfPresent(space, forKey: .space)
    }
}

extension DrumPad {
    enum CodingKeys: String, CodingKey {
        case assetID, gain, reverb, color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetID = try container.decodeIfPresent(String.self, forKey: .assetID)
        gain = try container.decodeIfPresent(Double.self, forKey: .gain) ?? 0.9
        reverb = try container.decodeEffect(.reverb, neutral: 0)
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? DrumColor.stone.rawValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(assetID, forKey: .assetID)
        try container.encode(gain, forKey: .gain)
        try container.encodeIfPresent(reverb, forKey: .reverb)
        try container.encode(color, forKey: .color)
    }
}

extension PerformanceSet {
    enum CodingKeys: String, CodingKey {
        case id, name, metronome, padPitch, padsRunning, padMaster, padLayers, drumLayout, drumPads, scenes, macros
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        metronome = try container.decodeIfPresent(MetronomeSettings.self, forKey: .metronome) ?? MetronomeSettings()
        padLayers = try container.decodeIfPresent([PadLayer].self, forKey: .padLayers) ?? []
        padPitch = try container.decodeIfPresent(String.self, forKey: .padPitch) ?? padLayers.first?.pitch ?? "C"
        padsRunning = try container.decodeIfPresent(Bool.self, forKey: .padsRunning) ?? padLayers.contains(where: \.playing)
        padMaster = try container.decodeIfPresent(Double.self, forKey: .padMaster) ?? 1
        drumLayout = try container.decodeIfPresent(Int.self, forKey: .drumLayout) ?? 8
        drumPads = try container.decodeIfPresent([DrumPad].self, forKey: .drumPads) ?? []
        scenes = try container.decodeIfPresent([PerformanceScene].self, forKey: .scenes) ?? []
        macros = try container.decodeIfPresent([MacroControl].self, forKey: .macros) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(metronome, forKey: .metronome)
        try container.encode(padPitch, forKey: .padPitch)
        try container.encode(padsRunning, forKey: .padsRunning)
        try container.encode(padMaster, forKey: .padMaster)
        try container.encode(padLayers, forKey: .padLayers)
        try container.encode(drumLayout, forKey: .drumLayout)
        try container.encode(drumPads, forKey: .drumPads)
        try container.encode(scenes, forKey: .scenes)
        try container.encode(macros, forKey: .macros)
    }
}

extension KeyedDecodingContainer {
    /// A saved effect at its neutral value reads as off.
    func decodeEffect(_ key: Key, neutral: Double) throws -> Double? {
        guard let value = try decodeIfPresent(Double.self, forKey: key), abs(value - neutral) > 0.001 else { return nil }
        return value
    }
}
