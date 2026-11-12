import XCTest
@testable import StageKeys

final class KeyStateTests: XCTestCase {
    func testMasterAtZero() {
        var state = KeyState()
        state.master = 0
        XCTAssertEqual(KeyState.silentReason(state), "Keys master at 0")
    }

    func testOneActiveLayerIsNotSilent() {
        var state = KeyState()
        state.keySlots[0].fileID = "sf2/a.sf2"
        state.keySlots[0].volume = 1
        for index in 1..<KeySlot.slotCount {
            state.keySlots[index].fileID = "sf2/b.sf2"
            state.keySlots[index].volume = 0
        }
        XCTAssertNil(KeyState.silentReason(state))
    }

    func testAllActiveLayersAtZero() {
        var state = KeyState()
        for index in 0..<KeySlot.slotCount {
            state.keySlots[index].fileID = "sf2/a.sf2"
            state.keySlots[index].volume = 0
        }
        XCTAssertEqual(KeyState.silentReason(state), "All Keys layers at 0")
    }

    func testDisabledOrEmptyLayerDoesNotCount() {
        var state = KeyState()
        state.keySlots[0].fileID = "sf2/a.sf2"
        state.keySlots[0].volume = 1
        state.keySlots[1].fileID = "sf2/b.sf2"
        state.keySlots[1].enabled = false
        state.keySlots[1].volume = 0
        state.keySlots[2].volume = 0
        XCTAssertNil(KeyState.silentReason(state))
    }

    func testNoLoadedLayer() {
        XCTAssertNil(KeyState.silentReason(KeyState()))
    }
}
