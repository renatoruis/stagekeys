import Foundation

/// Audio engines, each with its own output route.
enum Motor: String, Codable, CaseIterable, Identifiable {
    case keys

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keys: "Keys"
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
    case keysVolume
    case keysToggle
    case keysPanic
    case keysCutoff
    case keysResonance
    case keysLow
    case keysHigh
    case keysCompressor
    case keysReverb
    case keysSpace
    case keysPan
    case keysTune
    case keysModToggle
    case keysRotaryToggle
    case keysBendToggle
    case keysOctaveDown
    case keysOctaveUp
    case transposeDown
    case transposeUp
    case masterVolume

    /// Continuous targets follow CC values; the rest fire on note-on, program change or CC >= 64.
    var continuous: Bool {
        switch self {
        case .keysVolume, .masterVolume: true
        default: isLayerKnob
        }
    }

    /// Per-layer effect knobs, which MIDI CC values drive directly.
    var isLayerKnob: Bool {
        switch self {
        case .keysCutoff, .keysResonance, .keysLow, .keysHigh, .keysCompressor, .keysReverb, .keysSpace, .keysPan, .keysTune: true
        default: false
        }
    }

    func title(index: Int) -> String {
        switch self {
        case .keysVolume: "Keys \(index + 1) volume"
        case .keysToggle: "Keys \(index + 1) on/off"
        case .keysPanic: "Keys panic"
        case .keysCutoff: "Keys \(index + 1) cutoff"
        case .keysResonance: "Keys \(index + 1) resonance"
        case .keysLow: "Keys \(index + 1) low EQ"
        case .keysHigh: "Keys \(index + 1) high EQ"
        case .keysCompressor: "Keys \(index + 1) compressor"
        case .keysReverb: "Keys \(index + 1) reverb"
        case .keysSpace: "Keys \(index + 1) space"
        case .keysPan: "Keys \(index + 1) pan"
        case .keysTune: "Keys \(index + 1) tune"
        case .keysModToggle: "Keys \(index + 1) mod wheel to cutoff"
        case .keysRotaryToggle: "Keys \(index + 1) rotary"
        case .keysBendToggle: "Keys \(index + 1) pitch bend"
        case .keysOctaveDown: "Keys \(index + 1) octave down"
        case .keysOctaveUp: "Keys \(index + 1) octave up"
        case .transposeDown: "Transpose down"
        case .transposeUp: "Transpose up"
        case .masterVolume: "Master volume"
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
    /// Inputs that play the SF2 keys. Empty: every enabled input plays them.
    var keyboardSourceIDs: [Int32] = []
    var bindings: [MIDIBinding] = []
    var liveMode = false

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
        case bindings, liveMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bufferFrames = try container.decodeIfPresent(Int.self, forKey: .bufferFrames) ?? 128
        routes = try container.decodeIfPresent([String: MotorRoute].self, forKey: .routes) ?? [:]
        routes = routes.filter { $0.key == Motor.keys.rawValue }
        enabledMIDISources = try container.decodeIfPresent([Int32].self, forKey: .enabledMIDISources) ?? []
        seenMIDISources = try container.decodeIfPresent([Int32].self, forKey: .seenMIDISources) ?? []
        midiSourcesKnown = try container.decodeIfPresent(Bool.self, forKey: .midiSourcesKnown) ?? false
        keyboardSourceIDs = try container.decodeIfPresent([Int32].self, forKey: .keyboardSourceIDs) ?? []
        let rawBindings = try container.decodeIfPresent([StoredBinding].self, forKey: .bindings) ?? []
        bindings = rawBindings.compactMap(\.binding)
        liveMode = try container.decodeIfPresent(Bool.self, forKey: .liveMode) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bufferFrames, forKey: .bufferFrames)
        try container.encode(routes, forKey: .routes)
        try container.encode(enabledMIDISources, forKey: .enabledMIDISources)
        try container.encode(seenMIDISources, forKey: .seenMIDISources)
        try container.encode(midiSourcesKnown, forKey: .midiSourcesKnown)
        try container.encode(keyboardSourceIDs, forKey: .keyboardSourceIDs)
        try container.encode(bindings, forKey: .bindings)
        try container.encode(liveMode, forKey: .liveMode)
    }
}

/// Bindings whose target no longer exists (pads, drums, click, songs) are dropped on load.
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
