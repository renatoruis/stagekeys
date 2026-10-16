import XCTest

final class SF2Tests: XCTestCase {
    private let rate = 48_000.0
    private let root = ProcessInfo.processInfo.environment["STAGEKEYS_SOUNDS"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Timbres sf2")

    private func sound(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            throw XCTSkip("\(name) not found in \(root.path); set STAGEKEYS_SOUNDS.")
        }
        return url
    }

    private func files() throws -> [URL] {
        if !FileManager.default.fileExists(atPath: root.path) {
            throw XCTSkip("No sound folder at \(root.path); set STAGEKEYS_SOUNDS.")
        }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sf2" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testEveryFileParses() throws {
        let urls = try files()
        XCTAssertFalse(urls.isEmpty)
        for url in urls {
            let file = try SF2File(url: url)
            XCTAssertFalse(file.playablePresets.isEmpty, url.lastPathComponent)
            for preset in file.playablePresets {
                XCTAssertFalse(file.regions(for: preset).isEmpty, "\(url.lastPathComponent) / \(preset.name)")
            }
        }
    }

    /// Adjacent keys must never play the same sample at the same pitch.
    func testConcertGrandKeyTracking() throws {
        let file = try SF2File(url: sound("Piano - Concert Grand.sf2"))
        let program = try SF2Program(file: file, preset: file.playablePresets[0])
        func pitches(_ key: Int) -> Set<[Int]> {
            Set(program.regions(key: key, velocity: 100).map { region in
                let cents = Float(key - Int(region.rootKey)) * region.scaleTuning + region.tuneCents
                return [region.sampleIndex, Int(cents.rounded())]
            })
        }
        var previous = pitches(21)
        for key in 22...108 {
            let current = pitches(key)
            XCTAssertFalse(current.isEmpty, "key \(key)")
            XCTAssertTrue(current.isDisjoint(with: previous), "key \(key)")
            previous = current
        }
    }

    func testShapeVelocity() {
        for velocity in [1, 64, 127] {
            XCTAssertEqual(SF2Part.shapeVelocity(velocity, .normal), velocity)
            XCTAssertEqual(SF2Part.shapeVelocity(velocity, .fixed), 100)
        }
        XCTAssertEqual(SF2Part.shapeVelocity(127, .soft), 127)
        XCTAssertEqual(SF2Part.shapeVelocity(127, .hard), 127)
        XCTAssertGreaterThan(SF2Part.shapeVelocity(64, .soft), 64)
        XCTAssertLessThan(SF2Part.shapeVelocity(64, .hard), 64)
        XCTAssertEqual(SF2Part.shapeVelocity(1, .hard), 1)
        var previous = 0
        for velocity in 1...127 {
            let shaped = SF2Part.shapeVelocity(velocity, .hard)
            XCTAssertGreaterThanOrEqual(shaped, previous)
            previous = shaped
        }
    }

    func testOfflinePitch() throws {
        // Collection packs hold chord pads recorded in one key and silent placeholder samples.
        for url in try files() where !url.lastPathComponent.hasPrefix("Collection - ") {
            let file = try SF2File(url: url)
            for preset in file.playablePresets {
                let program = try SF2Program(file: file, preset: preset)
                for note in [36, 60, 84] where !program.regions(key: note, velocity: 100).isEmpty {
                    let name = "\(url.deletingPathExtension().lastPathComponent) / \(preset.name) / \(note)"
                    let part = SF2Part()
                    part.update { $0.sampleRate = self.rate }
                    part.setProgram(program)
                    part.send(KeyEvent(kind: .noteOn, data1: UInt8(note), data2: 100))
                    let audio = render(part, seconds: 0.6)
                    XCTAssertGreaterThan(audio.map(abs).max() ?? 0, 1e-3, name)
                    let expected = 440 * pow(2, Double(note - 69) / 12)
                    let (hz, r) = pitch(audio, expected: expected)
                    if r > 0.9, hz > 0 {
                        XCTAssertLessThan(abs(1200 * log2(hz / expected)), 25, name)
                    }
                }
            }
        }
    }

    func testPanLeftSilencesRight() throws {
        let file = try SF2File(url: sound("Nord - Piano - GP Grand.sf2"))
        let program = try SF2Program(file: file, preset: file.playablePresets[0])
        let part = SF2Part()
        part.update {
            $0.sampleRate = self.rate
            $0.pan = -1
        }
        part.setProgram(program)
        part.send(KeyEvent(kind: .noteOn, data1: 60, data2: 100))
        let block = 128
        let left = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { left.deallocate(); right.deallocate() }
        var peakLeft: Float = 0
        var peakRight: Float = 0
        for _ in 0..<Int(0.3 * rate) / block {
            part.render(frames: block, left: left, right: right)
            for i in 0..<block {
                peakLeft = max(peakLeft, abs(left[i]))
                peakRight = max(peakRight, abs(right[i]))
            }
        }
        XCTAssertGreaterThan(peakLeft, 1e-3)
        XCTAssertEqual(peakRight, 0)
    }

    /// 4 parts x 40 sustained notes on 64-frame buffers.
    func testStress() throws {
        let file = try SF2File(url: sound("Nord - Piano - GP Grand.sf2"))
        let program = try SF2Program(file: file, preset: file.playablePresets[0])
        let parts = (0..<4).map { _ -> SF2Part in
            let part = SF2Part()
            part.update { $0.sampleRate = self.rate }
            part.setProgram(program)
            part.send(KeyEvent(kind: .control, data1: 64, data2: 127))
            for note in stride(from: 28, to: 108, by: 2) {
                part.send(KeyEvent(kind: .noteOn, data1: UInt8(note), data2: 90))
            }
            return part
        }
        let block = 64
        let left = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { left.deallocate(); right.deallocate() }
        var sum = 0.0
        let cycles = Int(2 * rate) / block
        for _ in 0..<cycles {
            let started = HostTime.now()
            for part in parts { part.render(frames: block, left: left, right: right) }
            sum += Double(HostTime.now() - started) * HostTime.nanosPerTick
        }
        let voices = parts.reduce(0) { $0 + Int($1.report.activeVoices) }
        let load = sum / Double(cycles) / (Double(block) / rate * 1e9)
        print(String(format: "stress voices=%d avg %.1f%% of a 64-frame buffer", voices, load * 100))
        XCTAssertGreaterThanOrEqual(voices, 160)
        XCTAssertLessThan(load, 0.3)
    }

    private func render(_ part: SF2Part, seconds: Double, block: Int = 128) -> [Float] {
        let total = Int(seconds * rate)
        var mono = [Float](repeating: 0, count: total)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { left.deallocate(); right.deallocate() }
        var done = 0
        while done < total {
            let n = min(block, total - done)
            part.render(frames: n, left: left, right: right)
            for i in 0..<n { mono[done + i] = left[i] + right[i] }
            done += n
        }
        return mono
    }

    /// Normalized autocorrelation around the expected period; returns (Hz, correlation).
    private func pitch(_ x: [Float], expected: Double) -> (Double, Float) {
        let start = Int(0.25 * rate)
        let n = 8192
        let lo = Int(rate / (expected * 1.45))
        let hi = Int(rate / (expected / 1.45))
        guard x.count > start + n + hi + 1 else { return (0, 0) }
        var best = 0
        var bestR: Float = -1
        var values = [Float](repeating: 0, count: hi + 2)
        for lag in max(2, lo - 1)...(hi + 1) {
            var s: Float = 0, a: Float = 0, b: Float = 0
            for i in start..<(start + n) {
                s += x[i] * x[i + lag]; a += x[i] * x[i]; b += x[i + lag] * x[i + lag]
            }
            let r = s / max(1e-12, (a * b).squareRoot())
            values[lag] = r
            if lag >= lo, lag <= hi, r > bestR { bestR = r; best = lag }
        }
        let y0 = values[best - 1], y1 = values[best], y2 = values[best + 1]
        let d = Double((y0 - y2) / (2 * (y0 - 2 * y1 + y2)))
        return (rate / (Double(best) + (d.isFinite ? d : 0)), bestR)
    }
}
