import Foundation

/// SoundFont 2.04 file: preset/instrument/sample tables plus the memory-mapped `smpl` chunk.
final class SF2File {
    struct PresetHeader: Equatable, Hashable {
        var name: String
        var program: Int
        var bank: Int
        fileprivate var bagStart: Int
        fileprivate var bagEnd: Int
    }

    struct SampleHeader {
        var name: String
        var start: Int
        var end: Int
        var loopStart: Int
        var loopEnd: Int
        var sampleRate: Int
        var originalPitch: Int
        var pitchCorrection: Int
        var type: Int
    }

    fileprivate struct Instrument {
        var bagStart: Int
        var bagEnd: Int
    }

    fileprivate struct Bag {
        var genStart: Int
        var genEnd: Int
    }

    fileprivate struct Generator {
        var oper: Int
        var amount: Int16
        var lo: UInt8
        var hi: UInt8
    }

    let url: URL
    let presets: [PresetHeader]
    let samples: [SampleHeader]
    /// Memory-mapped file. Sample frames are read from here only on the loader thread.
    let data: Data
    let sampleByteOffset: Int
    let sampleFrameCount: Int

    private let instruments: [Instrument]
    private let presetBags: [Bag]
    private let instrumentBags: [Bag]
    private let presetGens: [Generator]
    private let instrumentGens: [Generator]

    init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        self.data = data
        let reader = Reader(data: data)
        guard reader.fourCC(at: 0) == "RIFF", reader.fourCC(at: 8) == "sfbk" else { throw SF2Error.notSoundFont }
        var smplOffset = 0
        var smplSize = 0
        var tables: [String: (offset: Int, size: Int)] = [:]
        try reader.walk(from: 12, to: min(data.count, 8 + Int(reader.u32(at: 4)))) { id, offset, size in
            guard id == "LIST" else { return }
            let kind = reader.fourCC(at: offset)
            try reader.walk(from: offset + 4, to: offset + size) { sub, subOffset, subSize in
                if kind == "sdta", sub == "smpl" {
                    smplOffset = subOffset
                    smplSize = subSize
                } else if kind == "pdta" {
                    tables[sub] = (subOffset, subSize)
                }
            }
        }
        guard smplSize > 0 else { throw SF2Error.missingChunk("smpl") }
        sampleByteOffset = smplOffset
        sampleFrameCount = smplSize / 2

        func table(_ id: String, _ record: Int) throws -> (offset: Int, count: Int) {
            guard let entry = tables[id], entry.size >= record else { throw SF2Error.missingChunk(id) }
            return (entry.offset, entry.size / record)
        }

        let phdr = try table("phdr", 38)
        var presets: [PresetHeader] = []
        for index in 0..<max(0, phdr.count - 1) {
            let base = phdr.offset + index * 38
            let next = base + 38
            presets.append(PresetHeader(
                name: reader.name(at: base),
                program: Int(reader.u16(at: base + 20)),
                bank: Int(reader.u16(at: base + 22)),
                bagStart: Int(reader.u16(at: base + 24)),
                bagEnd: Int(reader.u16(at: next + 24))
            ))
        }

        func bags(_ id: String) throws -> [Bag] {
            let info = try table(id, 4)
            var out: [Bag] = []
            out.reserveCapacity(max(0, info.count - 1))
            for index in 0..<max(0, info.count - 1) {
                let base = info.offset + index * 4
                out.append(Bag(genStart: Int(reader.u16(at: base)), genEnd: Int(reader.u16(at: base + 4))))
            }
            return out
        }

        func gens(_ id: String) throws -> [Generator] {
            let info = try table(id, 4)
            var out: [Generator] = []
            out.reserveCapacity(info.count)
            for index in 0..<info.count {
                let base = info.offset + index * 4
                out.append(Generator(
                    oper: Int(reader.u16(at: base)),
                    amount: Int16(bitPattern: reader.u16(at: base + 2)),
                    lo: reader.u8(at: base + 2),
                    hi: reader.u8(at: base + 3)
                ))
            }
            return out
        }

        let inst = try table("inst", 22)
        var instruments: [Instrument] = []
        for index in 0..<max(0, inst.count - 1) {
            let base = inst.offset + index * 22
            instruments.append(Instrument(bagStart: Int(reader.u16(at: base + 20)), bagEnd: Int(reader.u16(at: base + 22 + 20))))
        }

        let shdr = try table("shdr", 46)
        var samples: [SampleHeader] = []
        for index in 0..<max(0, shdr.count - 1) {
            let base = shdr.offset + index * 46
            samples.append(SampleHeader(
                name: reader.name(at: base),
                start: Int(reader.u32(at: base + 20)),
                end: Int(reader.u32(at: base + 24)),
                loopStart: Int(reader.u32(at: base + 28)),
                loopEnd: Int(reader.u32(at: base + 32)),
                sampleRate: Int(reader.u32(at: base + 36)),
                originalPitch: Int(reader.u8(at: base + 40)),
                pitchCorrection: Int(Int8(bitPattern: reader.u8(at: base + 41))),
                type: Int(reader.u16(at: base + 44))
            ))
        }

        self.presets = presets
        self.instruments = instruments
        self.samples = samples
        presetBags = try bags("pbag")
        instrumentBags = try bags("ibag")
        presetGens = try gens("pgen")
        instrumentGens = try gens("igen")
    }

    /// Presets that span a playable range (credit-only presets map a single key), sorted by bank then program.
    var playablePresets: [PresetHeader] {
        presets.filter { preset in
            var keys = Set<Int>()
            for region in regions(for: preset) {
                keys.formUnion(Int(region.keyLo)...Int(region.keyHi))
                if keys.count >= 12 { return true }
            }
            return false
        }
        .sorted { ($0.bank, $0.program) < ($1.bank, $1.program) }
    }

    func preset(bank: Int, program: Int) -> PresetHeader? {
        presets.first { $0.bank == bank && $0.program == program }
    }

    /// Flattens preset and instrument zones into playable regions (SoundFont 2.04 §9.4).
    func regions(for preset: PresetHeader) -> [SF2Region] {
        var result: [SF2Region] = []
        var presetGlobal = GenTable.empty
        for bagIndex in preset.bagStart..<min(preset.bagEnd, presetBags.count) {
            var zone = presetGlobal
            let bag = presetBags[bagIndex]
            var instrument: Int?
            for gen in presetGens[safe: bag.genStart..<bag.genEnd] {
                if gen.oper == Gen.instrument {
                    instrument = Int(UInt16(bitPattern: gen.amount))
                    break
                }
                zone.set(gen)
            }
            guard let instrument else {
                if bagIndex == preset.bagStart { presetGlobal = zone }
                continue
            }
            guard instruments.indices.contains(instrument) else { continue }
            appendInstrument(instrument, presetZone: zone, into: &result)
        }
        return result
    }

    private func appendInstrument(_ index: Int, presetZone: GenTable, into result: inout [SF2Region]) {
        let instrument = instruments[index]
        var global = GenTable.defaults
        for bagIndex in instrument.bagStart..<min(instrument.bagEnd, instrumentBags.count) {
            var zone = global
            let bag = instrumentBags[bagIndex]
            var sampleID: Int?
            for gen in instrumentGens[safe: bag.genStart..<bag.genEnd] {
                if gen.oper == Gen.sampleID {
                    sampleID = Int(UInt16(bitPattern: gen.amount))
                    break
                }
                zone.set(gen)
            }
            guard let sampleID else {
                if bagIndex == instrument.bagStart { global = zone }
                continue
            }
            guard samples.indices.contains(sampleID), samples[sampleID].type & 0x8000 == 0 else { continue }
            if let region = makeRegion(instrument: zone, preset: presetZone, sample: samples[sampleID], sampleIndex: sampleID) {
                result.append(region)
            }
        }
    }

    private func makeRegion(instrument: GenTable, preset: GenTable, sample: SampleHeader, sampleIndex: Int) -> SF2Region? {
        let keyLo = max(instrument.lo(Gen.keyRange), preset.lo(Gen.keyRange))
        let keyHi = min(instrument.hi(Gen.keyRange), preset.hi(Gen.keyRange))
        let velLo = max(instrument.lo(Gen.velRange), preset.lo(Gen.velRange))
        let velHi = min(instrument.hi(Gen.velRange), preset.hi(Gen.velRange))
        guard keyLo <= keyHi, velLo <= velHi else { return nil }

        func sum(_ gen: Int) -> Int { Int(instrument[gen]) + Int(preset[gen]) }

        let start = sample.start + Int(instrument[Gen.startAddrsOffset]) + Int(instrument[Gen.startAddrsCoarseOffset]) * 32768
        let end = sample.end + Int(instrument[Gen.endAddrsOffset]) + Int(instrument[Gen.endAddrsCoarseOffset]) * 32768
        let loopStart = sample.loopStart + Int(instrument[Gen.startloopAddrsOffset]) + Int(instrument[Gen.startloopAddrsCoarseOffset]) * 32768
        let loopEnd = sample.loopEnd + Int(instrument[Gen.endloopAddrsOffset]) + Int(instrument[Gen.endloopAddrsCoarseOffset]) * 32768
        let clampedStart = min(max(0, start), sampleFrameCount)
        let clampedEnd = min(max(clampedStart, end), sampleFrameCount)
        guard clampedEnd - clampedStart > 1 else { return nil }

        var mode = Int(instrument[Gen.sampleModes]) & 3
        if mode == 2 { mode = 0 }
        var ls = min(max(clampedStart, loopStart), clampedEnd)
        var le = min(max(ls, loopEnd), clampedEnd)
        if le - ls < 2 {
            mode = 0
            ls = clampedStart
            le = clampedEnd
        }

        let overridingRoot = Int(instrument[Gen.overridingRootKey])
        let root = overridingRoot >= 0 ? overridingRoot : (sample.originalPitch <= 127 ? sample.originalPitch : 60)

        var region = SF2Region()
        region.keyLo = UInt8(clamping: keyLo)
        region.keyHi = UInt8(clamping: keyHi)
        region.velLo = UInt8(clamping: velLo)
        region.velHi = UInt8(clamping: velHi)
        region.sampleIndex = sampleIndex
        region.start = clampedStart
        region.end = clampedEnd
        region.loopStart = ls
        region.loopEnd = le
        region.loopMode = UInt8(mode)
        region.sampleRate = Float(max(400, sample.sampleRate))
        region.rootKey = Int16(root)
        region.tuneCents = Float(sum(Gen.coarseTune) * 100 + sum(Gen.fineTune) + sample.pitchCorrection)
        region.scaleTuning = Float(sum(Gen.scaleTuning))
        region.attenuation = Float(max(0, sum(Gen.initialAttenuation)))
        region.pan = Float(min(500, max(-500, sum(Gen.pan)))) / 1000
        region.filterFc = Float(min(13500, max(1500, sum(Gen.initialFilterFc))))
        region.filterQ = Float(min(960, max(0, sum(Gen.initialFilterQ))))
        region.exclusiveClass = UInt8(clamping: Int(instrument[Gen.exclusiveClass]))
        region.volEnv = SF2Region.Envelope(
            delay: Float(sum(Gen.delayVolEnv)),
            attack: Float(sum(Gen.attackVolEnv)),
            hold: Float(sum(Gen.holdVolEnv)),
            decay: Float(sum(Gen.decayVolEnv)),
            sustain: Float(min(1440, max(0, sum(Gen.sustainVolEnv)))),
            release: Float(sum(Gen.releaseVolEnv)),
            keyToHold: Float(sum(Gen.keynumToVolEnvHold)),
            keyToDecay: Float(sum(Gen.keynumToVolEnvDecay))
        )
        region.modEnv = SF2Region.Envelope(
            delay: Float(sum(Gen.delayModEnv)),
            attack: Float(sum(Gen.attackModEnv)),
            hold: Float(sum(Gen.holdModEnv)),
            decay: Float(sum(Gen.decayModEnv)),
            sustain: Float(min(1000, max(0, sum(Gen.sustainModEnv)))),
            release: Float(sum(Gen.releaseModEnv)),
            keyToHold: Float(sum(Gen.keynumToModEnvHold)),
            keyToDecay: Float(sum(Gen.keynumToModEnvDecay))
        )
        region.modEnvToPitch = Float(sum(Gen.modEnvToPitch))
        region.modEnvToFc = Float(sum(Gen.modEnvToFilterFc))
        region.modLfoDelay = Float(sum(Gen.delayModLFO))
        region.modLfoFreq = Float(sum(Gen.freqModLFO))
        region.modLfoToPitch = Float(sum(Gen.modLfoToPitch))
        region.modLfoToFc = Float(sum(Gen.modLfoToFilterFc))
        region.modLfoToVolume = Float(sum(Gen.modLfoToVolume))
        region.vibLfoDelay = Float(sum(Gen.delayVibLFO))
        region.vibLfoFreq = Float(sum(Gen.freqVibLFO))
        region.vibLfoToPitch = Float(sum(Gen.vibLfoToPitch))
        return region
    }

    /// Reads preset names without building regions: used by the catalog.
    static func presetList(url: URL) -> [PresetHeader] {
        (try? SF2File(url: url))?.playablePresets ?? []
    }
}

/// One playable zone: key/velocity window, sample slice and synthesis parameters (SF2 units).
struct SF2Region {
    struct Envelope {
        var delay: Float = -12000
        var attack: Float = -12000
        var hold: Float = -12000
        var decay: Float = -12000
        var sustain: Float = 0
        var release: Float = -12000
        var keyToHold: Float = 0
        var keyToDecay: Float = 0
    }

    var keyLo: UInt8 = 0
    var keyHi: UInt8 = 127
    var velLo: UInt8 = 0
    var velHi: UInt8 = 127
    var sampleIndex = 0
    var start = 0
    var end = 0
    var loopStart = 0
    var loopEnd = 0
    /// 0 no loop, 1 continuous, 3 loop until release.
    var loopMode: UInt8 = 0
    var sampleRate: Float = 44_100
    var rootKey: Int16 = 60
    var tuneCents: Float = 0
    var scaleTuning: Float = 100
    var attenuation: Float = 0
    var pan: Float = 0
    var filterFc: Float = 13500
    var filterQ: Float = 0
    var exclusiveClass: UInt8 = 0
    var volEnv = Envelope()
    var modEnv = Envelope()
    var modEnvToPitch: Float = 0
    var modEnvToFc: Float = 0
    var modLfoDelay: Float = -12000
    var modLfoFreq: Float = 0
    var modLfoToPitch: Float = 0
    var modLfoToFc: Float = 0
    var modLfoToVolume: Float = 0
    var vibLfoDelay: Float = -12000
    var vibLfoFreq: Float = 0
    var vibLfoToPitch: Float = 0
}

enum SF2Error: Error {
    case notSoundFont
    case missingChunk(String)
    case truncated
    case presetNotFound
}

enum Gen {
    static let startAddrsOffset = 0
    static let endAddrsOffset = 1
    static let startloopAddrsOffset = 2
    static let endloopAddrsOffset = 3
    static let startAddrsCoarseOffset = 4
    static let modLfoToPitch = 5
    static let vibLfoToPitch = 6
    static let modEnvToPitch = 7
    static let initialFilterFc = 8
    static let initialFilterQ = 9
    static let modLfoToFilterFc = 10
    static let modEnvToFilterFc = 11
    static let endAddrsCoarseOffset = 12
    static let modLfoToVolume = 13
    static let pan = 17
    static let delayModLFO = 21
    static let freqModLFO = 22
    static let delayVibLFO = 23
    static let freqVibLFO = 24
    static let delayModEnv = 25
    static let attackModEnv = 26
    static let holdModEnv = 27
    static let decayModEnv = 28
    static let sustainModEnv = 29
    static let releaseModEnv = 30
    static let keynumToModEnvHold = 31
    static let keynumToModEnvDecay = 32
    static let delayVolEnv = 33
    static let attackVolEnv = 34
    static let holdVolEnv = 35
    static let decayVolEnv = 36
    static let sustainVolEnv = 37
    static let releaseVolEnv = 38
    static let keynumToVolEnvHold = 39
    static let keynumToVolEnvDecay = 40
    static let instrument = 41
    static let keyRange = 43
    static let velRange = 44
    static let startloopAddrsCoarseOffset = 45
    static let initialAttenuation = 48
    static let endloopAddrsCoarseOffset = 50
    static let coarseTune = 51
    static let fineTune = 52
    static let sampleID = 53
    static let sampleModes = 54
    static let scaleTuning = 56
    static let exclusiveClass = 57
    static let overridingRootKey = 58
    static let count = 61

    /// Generators that are only valid at instrument level (§8.1.3).
    static let instrumentOnly: Set<Int> = [0, 1, 2, 3, 4, 12, 45, 50, 54, 57, 58, 46, 47]
}

private struct GenTable {
    private var values: [Int16]
    private var ranges: [Int: (lo: UInt8, hi: UInt8)] = [:]
    private let isPreset: Bool

    static var empty: GenTable { GenTable(values: Array(repeating: 0, count: Gen.count), isPreset: true) }

    static var defaults: GenTable {
        var table = GenTable(values: Array(repeating: 0, count: Gen.count), isPreset: false)
        table.values[Gen.initialFilterFc] = 13500
        for gen in [Gen.delayModLFO, Gen.delayVibLFO, Gen.delayModEnv, Gen.attackModEnv, Gen.holdModEnv,
                    Gen.decayModEnv, Gen.releaseModEnv, Gen.delayVolEnv, Gen.attackVolEnv, Gen.holdVolEnv,
                    Gen.decayVolEnv, Gen.releaseVolEnv] {
            table.values[gen] = -12000
        }
        table.values[Gen.scaleTuning] = 100
        table.values[Gen.overridingRootKey] = -1
        return table
    }

    private init(values: [Int16], isPreset: Bool) {
        self.values = values
        self.isPreset = isPreset
    }

    subscript(_ gen: Int) -> Int16 { values[gen] }

    func lo(_ gen: Int) -> Int { Int(ranges[gen]?.lo ?? 0) }
    func hi(_ gen: Int) -> Int { Int(ranges[gen]?.hi ?? 127) }

    fileprivate mutating func set(_ gen: SF2File.Generator) {
        guard gen.oper < Gen.count else { return }
        if isPreset, Gen.instrumentOnly.contains(gen.oper) { return }
        if gen.oper == Gen.keyRange || gen.oper == Gen.velRange {
            ranges[gen.oper] = (gen.lo, gen.hi)
        } else {
            values[gen.oper] = gen.amount
        }
    }
}

private struct Reader {
    let data: Data

    func u8(at offset: Int) -> UInt8 {
        guard offset >= 0, offset < data.count else { return 0 }
        return data[data.startIndex + offset]
    }

    func u16(at offset: Int) -> UInt16 {
        UInt16(u8(at: offset)) | UInt16(u8(at: offset + 1)) << 8
    }

    func u32(at offset: Int) -> UInt32 {
        UInt32(u16(at: offset)) | UInt32(u16(at: offset + 2)) << 16
    }

    func fourCC(at offset: Int) -> String {
        String(bytes: (0..<4).map { u8(at: offset + $0) }, encoding: .ascii) ?? ""
    }

    func name(at offset: Int) -> String {
        let bytes = (0..<20).map { u8(at: offset + $0) }.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    func walk(from start: Int, to end: Int, _ body: (String, Int, Int) throws -> Void) throws {
        var offset = start
        while offset + 8 <= end {
            let id = fourCC(at: offset)
            let size = Int(u32(at: offset + 4))
            let payload = offset + 8
            guard payload + size <= data.count else { throw SF2Error.truncated }
            try body(id, payload, size)
            offset = payload + size + (size & 1)
        }
    }
}

private extension Array {
    subscript(safe range: Range<Int>) -> ArraySlice<Element> {
        let lower = Swift.max(0, Swift.min(range.lowerBound, count))
        let upper = Swift.max(lower, Swift.min(range.upperBound, count))
        return self[lower..<upper]
    }
}
