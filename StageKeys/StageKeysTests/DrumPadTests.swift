import XCTest
@testable import StageKeys

final class DrumPadTests: XCTestCase {
    func testDefaultGainIsForty() {
        XCTAssertEqual(DrumPad().gain, 0.4)
    }

    func testMissingGainDecodesAsForty() throws {
        let pad = try JSONDecoder().decode(DrumPad.self, from: Data("{}".utf8))
        XCTAssertEqual(pad.gain, 0.4)
    }
}
