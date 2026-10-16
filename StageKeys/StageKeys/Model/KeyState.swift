import Foundation

/// One SF2 layer.
struct KeySlot: Codable, Equatable {
    var fileID: String?
    var bank: Int = 0
    var program: Int = 0
    var enabled: Bool = true
    var volume: Double = 0.8
    /// Effect amounts: nil until the knob is first moved, so the sound plays as the SF2 made it.
    var cutoff: Double?
    var resonance: Double?
    var compressor: Double?
    var reverb: Double?
    var rotary: Int = 0
    /// Shelving EQ, 0.5 is flat.
    var low: Double?
    var high: Double?
    /// Send into Valhalla Supermassive.
    var space: Double?
    /// Octave shift of this layer, on top of the global transpose.
    var octave: Int = 0
    /// The mod wheel drives this layer's Cutoff knob.
    var modCutoff = false
    /// Off: this layer ignores the sustain pedal.
    var sustain = true
    var velocity = VelocityCurve.normal
    /// nil: the Keyboard inputs chosen in Audio settings play this layer.
    var inputID: Int32?
    /// MIDI channel 0–15; nil: every channel.
    var channel: Int?
    /// 0.5 is centre / in tune; Tune spans ±50 cents.
    var pan: Double?
    var tune: Double?
    /// Off: this layer ignores pitch bend.
    var bend = true

    static let slotCount = 4
    static let octaveRange = -3...3
}

/// The four layers and their transpose, saved on every change.
struct KeyState: Codable, Equatable {
    var keySlots: [KeySlot] = Array(repeating: KeySlot(), count: KeySlot.slotCount)
    /// Semitones applied to all four layers.
    var transpose: Int = 0
    /// Master fader, before the output limiter; 1 is unity gain.
    var master: Double = 1

    func normalized() -> KeyState {
        var copy = self
        if copy.keySlots.count < KeySlot.slotCount {
            copy.keySlots.append(contentsOf: Array(repeating: KeySlot(), count: KeySlot.slotCount - copy.keySlots.count))
        }
        copy.keySlots = Array(copy.keySlots.prefix(KeySlot.slotCount))
        copy.transpose = min(24, max(-24, copy.transpose))
        copy.master = min(1, max(0, copy.master))
        return copy
    }
}

extension KeySlot {
    enum CodingKeys: String, CodingKey {
        case fileID, bank, program, enabled, volume, cutoff, resonance, compressor, reverb, rotary, low, high, space, octave, modCutoff, sustain, velocity, inputID, channel, pan, tune, bend
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileID = try container.decodeIfPresent(String.self, forKey: .fileID)
        bank = try container.decodeIfPresent(Int.self, forKey: .bank) ?? 0
        program = try container.decodeIfPresent(Int.self, forKey: .program) ?? 0
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8
        func effect(_ key: CodingKeys, neutral: Double) throws -> Double? {
            guard let value = try container.decodeIfPresent(Double.self, forKey: key), abs(value - neutral) > 0.001 else { return nil }
            return value
        }
        cutoff = try effect(.cutoff, neutral: 1)
        resonance = try container.decodeIfPresent(Double.self, forKey: .resonance)
        compressor = try effect(.compressor, neutral: 0)
        reverb = try effect(.reverb, neutral: 0)
        rotary = try container.decodeIfPresent(Int.self, forKey: .rotary) ?? 0
        low = try effect(.low, neutral: 0.5)
        high = try effect(.high, neutral: 0.5)
        space = try effect(.space, neutral: 0)
        octave = try container.decodeIfPresent(Int.self, forKey: .octave) ?? 0
        modCutoff = try container.decodeIfPresent(Bool.self, forKey: .modCutoff) ?? false
        sustain = try container.decodeIfPresent(Bool.self, forKey: .sustain) ?? true
        velocity = (try? container.decodeIfPresent(VelocityCurve.self, forKey: .velocity)) ?? .normal
        inputID = try container.decodeIfPresent(Int32.self, forKey: .inputID)
        channel = try container.decodeIfPresent(Int.self, forKey: .channel).map { min(15, max(0, $0)) }
        pan = try effect(.pan, neutral: 0.5)
        tune = try effect(.tune, neutral: 0.5)
        bend = try container.decodeIfPresent(Bool.self, forKey: .bend) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fileID, forKey: .fileID)
        try container.encode(bank, forKey: .bank)
        try container.encode(program, forKey: .program)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(volume, forKey: .volume)
        try container.encodeIfPresent(cutoff, forKey: .cutoff)
        try container.encodeIfPresent(resonance, forKey: .resonance)
        try container.encodeIfPresent(compressor, forKey: .compressor)
        try container.encodeIfPresent(reverb, forKey: .reverb)
        try container.encode(rotary, forKey: .rotary)
        try container.encodeIfPresent(low, forKey: .low)
        try container.encodeIfPresent(high, forKey: .high)
        try container.encodeIfPresent(space, forKey: .space)
        try container.encode(octave, forKey: .octave)
        try container.encode(modCutoff, forKey: .modCutoff)
        try container.encode(sustain, forKey: .sustain)
        try container.encode(velocity, forKey: .velocity)
        try container.encodeIfPresent(inputID, forKey: .inputID)
        try container.encodeIfPresent(channel, forKey: .channel)
        try container.encodeIfPresent(pan, forKey: .pan)
        try container.encodeIfPresent(tune, forKey: .tune)
        try container.encode(bend, forKey: .bend)
    }
}

extension KeyState {
    enum CodingKeys: String, CodingKey {
        case keySlots, transpose, master
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keySlots = try container.decodeIfPresent([KeySlot].self, forKey: .keySlots) ?? []
        transpose = try container.decodeIfPresent(Int.self, forKey: .transpose) ?? 0
        master = try container.decodeIfPresent(Double.self, forKey: .master) ?? 1
    }
}
