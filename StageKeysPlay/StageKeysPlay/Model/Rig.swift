import Foundation

/// Audio engines, each with its own output route.
enum Motor: String, Codable, CaseIterable, Identifiable {
    case pads
    case drums
    case metronome

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pads: "Pads"
        case .drums: "Drums"
        case .metronome: "Click"
        }
    }
}

struct ChannelPick: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case stereo
        case left
        case right
        case mono
        case pair
    }

    var kind: Kind
    var channel: Int

    static let stereo = ChannelPick(kind: .stereo, channel: 0)
    static let left = ChannelPick(kind: .left, channel: 0)
    static let right = ChannelPick(kind: .right, channel: 1)

    var storageKey: String {
        switch kind {
        case .stereo: "stereo"
        case .left: "left"
        case .right: "right"
        case .mono: "mono-\(channel)"
        case .pair: "pair-\(channel)"
        }
    }
}

struct MotorRoute: Codable, Equatable {
    var deviceUID: String?
    var pick: ChannelPick = .stereo
}

enum BindingTarget: String, Codable, CaseIterable {
    case padVolume
    case padToggle
    case drumNote
    case metroToggle
    case nextSong
    case previousSong
    case padsTransport
    case padCutoff
    case padMaster
    case countIn

    /// Continuous targets follow CC values; the rest fire on note-on, program change or CC >= 64.
    var continuous: Bool {
        switch self {
        case .padVolume, .padCutoff, .padMaster: true
        default: false
        }
    }

    func title(index: Int) -> String {
        switch self {
        case .padVolume: "Pad \(index + 1) volume"
        case .padToggle: "Pad \(index + 1) on/off"
        case .padCutoff: "Pad \(index + 1) cutoff"
        case .padsTransport: "Pads play/stop"
        case .padMaster: "Pads master"
        case .countIn: "Count-in"
        case .drumNote: "Drum pad \(index + 1)"
        case .metroToggle: "Click on/off"
        case .nextSong: "Next song"
        case .previousSong: "Previous song"
        }
    }
}

struct MIDIMatch: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case cc
        case note
        case program
    }

    var kind: Kind
    var number: Int
    var channel: Int

    func matches(kind: Kind, number: Int, channel: Int) -> Bool {
        self.kind == kind && self.number == number && (self.channel < 0 || self.channel == channel)
    }

    var label: String {
        let base: String
        switch kind {
        case .cc: base = "CC \(number)"
        case .note: base = "Note \(ResourceCatalog.noteName(number))"
        case .program: base = "PC \(number + 1)"
        }
        return channel >= 0 ? "\(base) · ch\(channel + 1)" : base
    }

    func sameControl(as other: MIDIMatch) -> Bool {
        kind == other.kind && number == other.number && (channel < 0 || other.channel < 0 || channel == other.channel)
    }
}

struct MIDIBinding: Codable, Equatable, Identifiable {
    var target: BindingTarget
    var index: Int
    var match: MIDIMatch

    var id: String { "\(target.rawValue)#\(index)" }
}

struct Rig: Equatable {
    var bufferFrames: Int = 128
    var routes: [String: MotorRoute] = [:]
    var enabledMIDISources: [Int32] = []
    var seenMIDISources: [Int32] = []
    var midiSourcesKnown: Bool = false
    /// Keyboard inputs: their notes never move the pad key.
    var keyboardSourceIDs: [Int32] = []
    var clockDestinationID: Int32?
    var bindings: [MIDIBinding] = []
    var currentSetID: UUID?
    var liveMode = false
    var setName = "Set 1"

    func route(for motor: Motor) -> MotorRoute {
        routes[motor.rawValue] ?? MotorRoute()
    }

    mutating func setRoute(_ route: MotorRoute, for motor: Motor) {
        routes[motor.rawValue] = route
    }

    func binding(for target: BindingTarget, index: Int) -> MIDIBinding? {
        bindings.first { $0.target == target && $0.index == index }
    }

    /// Stores the binding and returns the ones it replaced because they used the same control.
    @discardableResult
    mutating func setBinding(_ binding: MIDIBinding) -> [MIDIBinding] {
        let replaced = bindings.filter {
            !($0.target == binding.target && $0.index == binding.index) && $0.match.sameControl(as: binding.match)
        }
        bindings.removeAll { ($0.target == binding.target && $0.index == binding.index) || $0.match.sameControl(as: binding.match) }
        bindings.append(binding)
        return replaced
    }

    mutating func clearBinding(target: BindingTarget, index: Int) {
        bindings.removeAll { $0.target == target && $0.index == index }
    }
}

extension Rig: Codable {
    enum CodingKeys: String, CodingKey {
        case bufferFrames, routes, enabledMIDISources, seenMIDISources, midiSourcesKnown, keyboardSourceIDs
        case clockDestinationID, bindings, currentSetID, liveMode, setName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bufferFrames = try container.decodeIfPresent(Int.self, forKey: .bufferFrames) ?? 128
        routes = try container.decodeIfPresent([String: MotorRoute].self, forKey: .routes) ?? [:]
        routes.removeValue(forKey: "timbres")
        enabledMIDISources = try container.decodeIfPresent([Int32].self, forKey: .enabledMIDISources) ?? []
        seenMIDISources = try container.decodeIfPresent([Int32].self, forKey: .seenMIDISources) ?? []
        midiSourcesKnown = try container.decodeIfPresent(Bool.self, forKey: .midiSourcesKnown) ?? false
        keyboardSourceIDs = try container.decodeIfPresent([Int32].self, forKey: .keyboardSourceIDs) ?? []
        clockDestinationID = try container.decodeIfPresent(Int32.self, forKey: .clockDestinationID)
        let rawBindings = try container.decodeIfPresent([StoredBinding].self, forKey: .bindings) ?? []
        bindings = rawBindings.compactMap(\.binding)
        currentSetID = try container.decodeIfPresent(UUID.self, forKey: .currentSetID)
        liveMode = try container.decodeIfPresent(Bool.self, forKey: .liveMode) ?? false
        setName = try container.decodeIfPresent(String.self, forKey: .setName) ?? "Set 1"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bufferFrames, forKey: .bufferFrames)
        try container.encode(routes, forKey: .routes)
        try container.encode(enabledMIDISources, forKey: .enabledMIDISources)
        try container.encode(seenMIDISources, forKey: .seenMIDISources)
        try container.encode(midiSourcesKnown, forKey: .midiSourcesKnown)
        try container.encode(keyboardSourceIDs, forKey: .keyboardSourceIDs)
        try container.encodeIfPresent(clockDestinationID, forKey: .clockDestinationID)
        try container.encode(bindings, forKey: .bindings)
        try container.encodeIfPresent(currentSetID, forKey: .currentSetID)
        try container.encode(liveMode, forKey: .liveMode)
        try container.encode(setName, forKey: .setName)
    }
}

/// Bindings whose target no longer exists (for example the old per-engine tabs) are dropped on load.
private struct StoredBinding: Decodable {
    var target: String
    var index: Int
    var match: MIDIMatch

    var binding: MIDIBinding? {
        guard let target = BindingTarget(rawValue: target) else { return nil }
        return MIDIBinding(target: target, index: index, match: match)
    }
}

struct ArmedControl: Equatable {
    var target: BindingTarget
    var index: Int
}
