import Foundation

/// Raw pointers into an `SF2Program`. Copying this struct never touches ARC, so the render thread can hold it.
struct SF2ProgramView {
    var regions: UnsafePointer<SF2Region>?
    var keyStart: UnsafePointer<Int32>?
    var keyCount: UnsafePointer<Int32>?
    var keyRegions: UnsafePointer<Int32>?
    var samples: UnsafePointer<Int16>?

    static let empty = SF2ProgramView()
}

/// A preset ready to play: regions indexed by key, with every sample it uses copied into resident memory.
/// Samples stay 16-bit (no float copy), so a 280 MB piano costs about 280 MB.
final class SF2Program {
    static let padding = 4

    let name: String
    let byteSize: Int

    private let regions: UnsafeMutableBufferPointer<SF2Region>
    private let keyStart: UnsafeMutablePointer<Int32>
    private let keyCount: UnsafeMutablePointer<Int32>
    private let keyRegions: UnsafeMutableBufferPointer<Int32>
    private let samples: UnsafeMutableBufferPointer<Int16>

    var regionCount: Int { regions.count }

    var view: SF2ProgramView {
        SF2ProgramView(
            regions: UnsafePointer(regions.baseAddress),
            keyStart: UnsafePointer(keyStart),
            keyCount: UnsafePointer(keyCount),
            keyRegions: UnsafePointer(keyRegions.baseAddress),
            samples: UnsafePointer(samples.baseAddress)
        )
    }

    init(file: SF2File, preset: SF2File.PresetHeader) throws {
        name = preset.name
        var flat = file.regions(for: preset)
        guard !flat.isEmpty else { throw SF2Error.presetNotFound }

        // One contiguous segment per sample header, spanning every region that reads it.
        var spans: [Int: (start: Int, end: Int)] = [:]
        for region in flat {
            let span = spans[region.sampleIndex] ?? (region.start, region.end)
            spans[region.sampleIndex] = (min(span.start, region.start), max(span.end, region.end))
        }
        let order = spans.keys.sorted()
        var base: [Int: Int] = [:]
        var total = 0
        for index in order {
            let span = spans[index]!
            base[index] = total + Self.padding
            total += span.end - span.start + Self.padding * 2
        }

        let samples = UnsafeMutableBufferPointer<Int16>.allocate(capacity: max(total, 1))
        samples.initialize(repeating: 0)
        file.data.withUnsafeBytes { raw in
            guard let source = raw.baseAddress?.advanced(by: file.sampleByteOffset) else { return }
            for index in order {
                let span = spans[index]!
                let count = span.end - span.start
                guard count > 0, let destination = samples.baseAddress?.advanced(by: base[index]!) else { continue }
                memcpy(destination, source.advanced(by: span.start * 2), count * 2)
            }
        }

        for position in flat.indices {
            let offset = base[flat[position].sampleIndex]! - spans[flat[position].sampleIndex]!.start
            flat[position].start += offset
            flat[position].end += offset
            flat[position].loopStart += offset
            flat[position].loopEnd += offset
        }

        let regions = UnsafeMutableBufferPointer<SF2Region>.allocate(capacity: flat.count)
        _ = regions.initialize(from: flat)

        var lists = Array(repeating: [Int32](), count: 128)
        for (position, region) in flat.enumerated() {
            for key in Int(region.keyLo)...Int(min(127, region.keyHi)) {
                lists[key].append(Int32(position))
            }
        }
        let keyStart = UnsafeMutablePointer<Int32>.allocate(capacity: 128)
        let keyCount = UnsafeMutablePointer<Int32>.allocate(capacity: 128)
        let indexTotal = lists.reduce(0) { $0 + $1.count }
        let keyRegions = UnsafeMutableBufferPointer<Int32>.allocate(capacity: max(indexTotal, 1))
        keyRegions.initialize(repeating: 0)
        var cursor = 0
        for key in 0..<128 {
            keyStart[key] = Int32(cursor)
            keyCount[key] = Int32(lists[key].count)
            for value in lists[key] {
                keyRegions[cursor] = value
                cursor += 1
            }
        }

        self.samples = samples
        self.regions = regions
        self.keyStart = keyStart
        self.keyCount = keyCount
        self.keyRegions = keyRegions
        byteSize = total * 2 + flat.count * MemoryLayout<SF2Region>.stride
    }

    deinit {
        samples.deallocate()
        regions.deinitialize()
        regions.deallocate()
        keyStart.deallocate()
        keyCount.deallocate()
        keyRegions.deallocate()
    }

    /// Regions a key/velocity pair starts. Off the render path: used by tests and diagnostics.
    func regions(key: Int, velocity: Int) -> [SF2Region] {
        let start = Int(keyStart[key])
        return (start..<start + Int(keyCount[key])).map { regions[Int(keyRegions[$0])] }
            .filter { velocity >= Int($0.velLo) && velocity <= Int($0.velHi) }
    }
}
