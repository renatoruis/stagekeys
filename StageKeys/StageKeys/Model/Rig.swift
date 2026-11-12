import Foundation

/// Audio engines, each with its own output route.
enum Motor: String, Codable, CaseIterable, Identifiable {
    case keys
    case pads
    case drums
    case metronome

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keys: "Keys"
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

enum BindingTarget: String, Codable, CaseIterable, Hashable {
    case keysVolume
    case keysToggle
    case keysPanic
    case keysCutoff
    case keysResonance
    case keysLow
    case keysHigh
    case keysCompressor
    case keysReverb
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
    case showTab
    case keysTab

    /// Continuous targets follow CC values; the rest fire on note-on, program change or CC >= 64.
    var continuous: Bool {
        switch self {
        case .keysVolume, .masterVolume, .padVolume, .padCutoff, .padMaster: true
        default: isLayerKnob
        }
    }

    /// Per-layer effect knobs, which MIDI CC values drive directly.
    var isLayerKnob: Bool {
        switch self {
        case .keysCutoff, .keysResonance, .keysLow, .keysHigh, .keysCompressor, .keysReverb, .keysPan, .keysTune: true
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
        case .keysPan: "Keys \(index + 1) pan"
        case .keysTune: "Keys \(index + 1) tune"
        case .keysModToggle: "Keys \(index + 1) mod wheel to cutoff"
        case .keysRotaryToggle: "Keys \(index + 1) rotary"
        case .keysBendToggle: "Keys \(index + 1) pitch bend"
        case .keysOctaveDown: "Keys \(index + 1) octave down"
        case .keysOctaveUp: "Keys \(index + 1) octave up"
        case .transposeDown: "Transpose down"
        case .transposeUp: "Transpose up"
        case .masterVolume: "Keys master"
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
        case .showTab: "Show tab"
        case .keysTab: "Keys tab"
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
        case .note: base = "Note \(MIDINote.name(number))"
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
    /// Inputs that play the SF2 keys. Empty: every enabled input plays them and moves the pad key.
    var keyboardSourceIDs: [Int32] = []
    var clockDestinationID: Int32?
    var bindings: [MIDIBinding] = []
    var currentSetID: UUID?
    var liveMode = false
    var setName = "Set 1"
    /// Lights the Launchkey drum pads from the pad colors.
    var padLights = true

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

    /// Notes the eight left pads send once the Launchkey is in DAW drum mode, pads 1–4 then 5–8.
    static let launchkeyDrumNotes = [40, 41, 42, 43, 36, 37, 38, 39]
    static let launchkeyDrumChannel = 9

    /// Pads whose mapping will not light a Launchkey drum pad.
    func drumPadsOffLaunchkey(_ pads: [Int]) -> [Int] {
        pads.filter { index in
            guard let binding = binding(for: .drumNote, index: index), binding.match.kind == .note else { return true }
            let channel = binding.match.channel
            let onDrumChannel = channel == Self.launchkeyDrumChannel || channel == -1
            return !(36...51).contains(binding.match.number) || !onDrumChannel
        }
    }

    /// Maps drum pads 1–8 to the eight left Launchkey pads. Returns bindings it took from other targets.
    @discardableResult
    mutating func mapLaunchkeyDrums() -> [MIDIBinding] {
        var replaced: [MIDIBinding] = []
        for (index, note) in Self.launchkeyDrumNotes.enumerated() {
            let binding = MIDIBinding(
                target: .drumNote,
                index: index,
                match: MIDIMatch(kind: .note, number: note, channel: Self.launchkeyDrumChannel)
            )
            replaced.append(contentsOf: setBinding(binding))
        }
        return replaced
    }

    /// First launch of the single app: keeps both rigs. A control mapped in both keeps firing both.
    static func merged(keys: Rig?, show: Rig?) -> Rig {
        var rig = Rig()
        rig.bufferFrames = keys?.bufferFrames ?? show?.bufferFrames ?? 128
        if let route = keys?.routes[Motor.keys.rawValue] {
            rig.routes[Motor.keys.rawValue] = route
        }
        for motor in [Motor.pads, .drums, .metronome] {
            if let route = show?.routes[motor.rawValue] {
                rig.routes[motor.rawValue] = route
            }
        }
        rig.enabledMIDISources = Self.unionIDs(keys?.enabledMIDISources, show?.enabledMIDISources)
        rig.seenMIDISources = Self.unionIDs(keys?.seenMIDISources, show?.seenMIDISources)
        rig.keyboardSourceIDs = Self.unionIDs(keys?.keyboardSourceIDs, show?.keyboardSourceIDs)
        rig.midiSourcesKnown = (keys?.midiSourcesKnown ?? false) || (show?.midiSourcesKnown ?? false)
        rig.liveMode = (keys?.liveMode ?? false) || (show?.liveMode ?? false)
        rig.clockDestinationID = show?.clockDestinationID
        rig.currentSetID = show?.currentSetID
        rig.setName = show?.setName ?? "Set 1"
        var bindings: [MIDIBinding] = []
        for binding in (keys?.bindings ?? []) + (show?.bindings ?? []) where !bindings.contains(binding) {
            bindings.append(binding)
        }
        rig.bindings = bindings
        return rig
    }

    private static func unionIDs(_ first: [Int32]?, _ second: [Int32]?) -> [Int32] {
        var out: [Int32] = []
        var seen = Set<Int32>()
        for id in (first ?? []) + (second ?? []) where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }
}

extension Rig: Codable {
    enum CodingKeys: String, CodingKey {
        case bufferFrames, routes, enabledMIDISources, seenMIDISources, midiSourcesKnown, keyboardSourceIDs
        case clockDestinationID, bindings, currentSetID, liveMode, setName, padLights
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bufferFrames = try container.decodeIfPresent(Int.self, forKey: .bufferFrames) ?? 128
        routes = try container.decodeIfPresent([String: MotorRoute].self, forKey: .routes) ?? [:]
        let allowed = Set(Motor.allCases.map(\.rawValue))
        routes = routes.filter { allowed.contains($0.key) }
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
        padLights = try container.decodeIfPresent(Bool.self, forKey: .padLights) ?? true
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
        try container.encode(padLights, forKey: .padLights)
    }
}

/// Bindings whose target no longer exists are dropped on load.
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
