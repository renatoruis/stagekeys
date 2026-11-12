import XCTest
@testable import StageKeys

final class RigTests: XCTestCase {
    func testMergedKeepsBothBindings() {
        var keys = Rig()
        keys.bindings = [MIDIBinding(target: .keysVolume, index: 0, match: MIDIMatch(kind: .cc, number: 7, channel: 0))]
        var show = Rig()
        show.bindings = [MIDIBinding(target: .padVolume, index: 0, match: MIDIMatch(kind: .cc, number: 7, channel: 0))]
        let rig = Rig.merged(keys: keys, show: show)
        XCTAssertEqual(rig.bindings.count, 2)
    }

    func testMergedUnionsKeyboards() {
        var keys = Rig()
        keys.keyboardSourceIDs = [1, 2]
        var show = Rig()
        show.keyboardSourceIDs = [2, 3]
        XCTAssertEqual(Rig.merged(keys: keys, show: show).keyboardSourceIDs, [1, 2, 3])
    }

    func testMergedRoutes() {
        var keys = Rig()
        keys.routes["keys"] = MotorRoute(deviceUID: "keys-dev", pick: .left)
        keys.routes["pads"] = MotorRoute(deviceUID: "wrong", pick: .stereo)
        var show = Rig()
        show.routes["pads"] = MotorRoute(deviceUID: "pads-dev", pick: .right)
        show.routes["drums"] = MotorRoute(deviceUID: "drums-dev", pick: .stereo)
        show.routes["metronome"] = MotorRoute(deviceUID: "click-dev", pick: .stereo)
        let rig = Rig.merged(keys: keys, show: show)
        XCTAssertEqual(rig.route(for: .keys).deviceUID, "keys-dev")
        XCTAssertEqual(rig.route(for: .pads).deviceUID, "pads-dev")
        XCTAssertEqual(rig.route(for: .drums).deviceUID, "drums-dev")
        XCTAssertEqual(rig.route(for: .metronome).deviceUID, "click-dev")
    }

    func testUnknownTargetDropped() throws {
        let json = """
        {"bindings":[{"target":"timbresTab","index":0,"match":{"kind":"cc","number":1,"channel":0}},{"target":"keysVolume","index":0,"match":{"kind":"cc","number":7,"channel":0}}]}
        """.data(using: .utf8)!
        let rig = try JSONDecoder().decode(Rig.self, from: json)
        XCTAssertEqual(rig.bindings.map(\.target), [.keysVolume])
    }

    func testTimbresRouteDropped() throws {
        let json = """
        {"routes":{"timbres":{"deviceUID":"old","pick":{"kind":"stereo","channel":0}},"keys":{"deviceUID":"k","pick":{"kind":"stereo","channel":0}}}}
        """.data(using: .utf8)!
        let rig = try JSONDecoder().decode(Rig.self, from: json)
        XCTAssertNil(rig.routes["timbres"])
        XCTAssertEqual(rig.route(for: .keys).deviceUID, "k")
    }

    func testNoteOutsideDrumRangeIsOff() {
        var rig = Rig()
        rig.bindings = [
            MIDIBinding(target: .drumNote, index: 0, match: MIDIMatch(kind: .note, number: 4, channel: 9)),
            MIDIBinding(target: .drumNote, index: 1, match: MIDIMatch(kind: .note, number: 40, channel: 9)),
        ]
        XCTAssertEqual(rig.drumPadsOffLaunchkey([0, 1]), [0])
    }

    func testAnyChannelCountsAsOn() {
        var rig = Rig()
        rig.bindings = [
            MIDIBinding(target: .drumNote, index: 0, match: MIDIMatch(kind: .note, number: 40, channel: -1)),
            MIDIBinding(target: .drumNote, index: 1, match: MIDIMatch(kind: .note, number: 40, channel: 0)),
        ]
        XCTAssertEqual(rig.drumPadsOffLaunchkey([0, 1]), [1])
    }

    func testMissingBindingIsOff() {
        XCTAssertEqual(Rig().drumPadsOffLaunchkey([2]), [2])
    }

    func testMapLaunchkeyDrumsCoversEightPads() {
        var rig = Rig()
        _ = rig.mapLaunchkeyDrums()
        XCTAssertEqual(rig.drumPadsOffLaunchkey(Array(0..<8)), [])
        XCTAssertEqual(rig.binding(for: .drumNote, index: 4)?.match.number, 36)
    }

    func testMapLaunchkeyDrumsReturnsTakenBindings() {
        var rig = Rig()
        rig.bindings = [MIDIBinding(target: .padVolume, index: 0, match: MIDIMatch(kind: .note, number: 40, channel: 9))]
        let replaced = rig.mapLaunchkeyDrums()
        XCTAssertEqual(replaced.map(\.target), [.padVolume])
    }
}
