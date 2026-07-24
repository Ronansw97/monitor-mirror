import CoreGraphics
import XCTest
@testable import MonitorMirrorCore

final class DisplayReducerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func system(
        id: CGDirectDisplayID,
        uuid: String,
        name: String,
        originX: Double = 0,
        mirrors: CGDirectDisplayID = 0,
        main: Bool = false,
        builtIn: Bool = false
    ) -> SystemDisplay {
        SystemDisplay(
            displayID: id,
            uuid: uuid,
            localizedName: name,
            pixelWidth: 2560,
            pixelHeight: 1440,
            refreshHz: 60,
            isBuiltIn: builtIn,
            isMain: main,
            mirrorsDisplay: mirrors,
            originX: originX
        )
    }

    private func remembered(
        key: String,
        id: CGDirectDisplayID = 9,
        name: String = "GHOST",
        wantsOff: Bool,
        originX: Double = 0,
        lastSeen: Date? = nil
    ) -> RememberedDisplay {
        RememberedDisplay(
            key: key,
            displayID: id,
            name: name,
            spec: "QHD · 60HZ",
            originX: originX,
            isBuiltIn: false,
            wantsOff: wantsOff,
            lastSeen: lastSeen ?? now
        )
    }

    // MARK: - Basic merge

    func testOnlineDisplaysBecomeCells() {
        let output = DisplayReducer.reconcile(
            online: [system(id: 2, uuid: "A", name: "M32UC", main: true)],
            remembered: [],
            now: now
        )
        XCTAssertEqual(output.displays.count, 1)
        XCTAssertEqual(output.displays[0].name, "M32UC")
        XCTAssertEqual(output.displays[0].spec, "QHD · 60HZ")
        XCTAssertTrue(output.displays[0].isOn)
        XCTAssertTrue(output.displays[0].isOnline)
        XCTAssertTrue(output.displays[0].isMain)
    }

    func testMirroredDisplayReadsAsOff() {
        let output = DisplayReducer.reconcile(
            online: [
                system(id: 1, uuid: "A", name: "MAIN", main: true),
                system(id: 2, uuid: "B", name: "SIDE", mirrors: 1),
            ],
            remembered: [],
            now: now
        )
        XCTAssertEqual(output.displays.first { $0.key == "B" }?.isOn, false)
    }

    func testAnExternallyMirroredDisplayIsNotClaimedAsOurOwnOffIntent() {
        // Someone mirrors a display in System Settings; we never touched it. It must not be
        // retained as an "off" cell once unplugged, so its intent stays false.
        let output = DisplayReducer.reconcile(
            online: [
                system(id: 1, uuid: "A", name: "MAIN", main: true),
                system(id: 2, uuid: "B", name: "SIDE", mirrors: 1),
            ],
            remembered: [],
            now: now
        )
        XCTAssertEqual(output.remembered.first { $0.key == "B" }?.wantsOff, false)
    }

    func testOurOwnOffIntentIsPreservedWhileTheDisplayStaysMirrored() {
        // The manager records wantsOff before toggling; a later reconcile (display still
        // online but mirrored) must keep that intent, not reset it.
        let output = DisplayReducer.reconcile(
            online: [
                system(id: 1, uuid: "A", name: "MAIN", main: true),
                system(id: 2, uuid: "B", name: "SIDE", mirrors: 1),
            ],
            remembered: [remembered(key: "B", id: 2, wantsOff: true, originX: 2560)],
            now: now
        )
        XCTAssertEqual(output.remembered.first { $0.key == "B" }?.wantsOff, true)
    }

    func testCellsAreOrderedLeftToRight() {
        let output = DisplayReducer.reconcile(
            online: [
                system(id: 2, uuid: "MID", name: "MID", originX: 0, main: true),
                system(id: 1, uuid: "LEFT", name: "LEFT", originX: -2560),
                system(id: 3, uuid: "RIGHT", name: "RIGHT", originX: 2560),
            ],
            remembered: [],
            now: now
        )
        XCTAssertEqual(output.displays.map(\.name), ["LEFT", "MID", "RIGHT"])
    }

    func testOrderIsStableWhenTwoDisplaysShareAnOrigin() {
        // Mirrored displays all report the master's origin, so ties are common.
        let displays = [
            system(id: 1, uuid: "B", name: "BEE", originX: 0),
            system(id: 2, uuid: "A", name: "AYE", originX: 0, main: true),
        ]
        let first = DisplayReducer.reconcile(online: displays, remembered: [], now: now)
        let second = DisplayReducer.reconcile(online: displays.reversed(), remembered: [], now: now)
        XCTAssertEqual(first.displays.map(\.key), second.displays.map(\.key))
    }

    func testIdenticalPanelsGetDistinctLabels() {
        // macOS normally disambiguates these itself, but not when it reports bare names.
        let output = DisplayReducer.reconcile(
            online: [
                system(id: 1, uuid: "A", name: "H27T27", originX: 0, main: true),
                system(id: 2, uuid: "B", name: "H27T27", originX: 2560),
            ],
            remembered: [],
            now: now
        )
        XCTAssertEqual(output.displays.map(\.name), ["H27T27", "H27T27·2"])
    }

    // MARK: - Displays that vanish

    func testDisplayWeSwitchedOffKeepsItsCellWhenItLeavesTheBus() throws {
        let output = DisplayReducer.reconcile(
            online: [system(id: 1, uuid: "A", name: "MAIN", main: true)],
            remembered: [remembered(key: "B", id: 7, name: "LG", wantsOff: true)],
            now: now
        )
        XCTAssertEqual(output.displays.count, 2)
        let ghost = try XCTUnwrap(output.displays.first { $0.key == "B" })
        XCTAssertFalse(ghost.isOn)
        XCTAssertFalse(ghost.isOnline)
        // The remembered display ID is what re-enabling has to use.
        XCTAssertEqual(ghost.displayID, 7)
    }

    func testUnpluggedDisplayIsForgotten() {
        // wantsOff == false means the user pulled the cable; there is nothing to switch on.
        let output = DisplayReducer.reconcile(
            online: [system(id: 1, uuid: "A", name: "MAIN", main: true)],
            remembered: [remembered(key: "B", wantsOff: false)],
            now: now
        )
        XCTAssertEqual(output.displays.map(\.key), ["A"])
        XCTAssertEqual(output.remembered.map(\.key), ["A"])
    }

    func testOffDisplayIsForgottenAfterTheRetentionWindow() {
        let stale = now.addingTimeInterval(-DisplayReducer.retention - 1)
        let output = DisplayReducer.reconcile(
            online: [system(id: 1, uuid: "A", name: "MAIN", main: true)],
            remembered: [remembered(key: "B", wantsOff: true, lastSeen: stale)],
            now: now
        )
        XCTAssertEqual(output.displays.map(\.key), ["A"])
    }

    func testOffDisplayIsKeptRightUpToTheRetentionWindow() {
        let old = now.addingTimeInterval(-DisplayReducer.retention + 1)
        let output = DisplayReducer.reconcile(
            online: [system(id: 1, uuid: "A", name: "MAIN", main: true)],
            remembered: [remembered(key: "B", wantsOff: true, lastSeen: old)],
            now: now
        )
        XCTAssertEqual(Set(output.displays.map(\.key)), ["A", "B"])
    }

    func testDisplayComingBackOnClearsTheOffIntent() {
        let output = DisplayReducer.reconcile(
            online: [
                system(id: 1, uuid: "A", name: "MAIN", main: true),
                system(id: 7, uuid: "B", name: "LG", originX: 2560),
            ],
            remembered: [remembered(key: "B", id: 7, wantsOff: true)],
            now: now
        )
        XCTAssertEqual(output.displays.first { $0.key == "B" }?.isOn, true)
        XCTAssertEqual(output.remembered.first { $0.key == "B" }?.wantsOff, false)
    }

    func testMirroredDisplayKeepsItsLastStandalonePosition() {
        // A mirrored display reports the master's origin; using it would collapse the
        // ordering onto one column.
        let output = DisplayReducer.reconcile(
            online: [
                system(id: 1, uuid: "A", name: "MAIN", originX: 0, main: true),
                system(id: 2, uuid: "B", name: "SIDE", originX: 0, mirrors: 1),
            ],
            remembered: [remembered(key: "B", id: 2, wantsOff: true, originX: 2560)],
            now: now
        )
        XCTAssertEqual(output.remembered.first { $0.key == "B" }?.originX, 2560)
        XCTAssertEqual(output.displays.map(\.key), ["A", "B"])
    }

    func testFallsBackToVendorKeyWhenThereIsNoUUID() {
        let display = SystemDisplay(displayID: 4, uuid: nil, vendor: 1, model: 2, serial: 3, unitNumber: 4)
        XCTAssertEqual(display.key, "vms:1-2-3-4")
        let output = DisplayReducer.reconcile(online: [display], remembered: [], now: now)
        XCTAssertEqual(output.displays.map(\.key), ["vms:1-2-3-4"])
    }

    func testNoDisplaysProducesNoCells() {
        let output = DisplayReducer.reconcile(online: [], remembered: [], now: now)
        XCTAssertTrue(output.displays.isEmpty)
        XCTAssertTrue(output.remembered.isEmpty)
    }

    // MARK: - Safety

    func testCannotSwitchOffTheLastLitDisplay() {
        let displays = [
            ManagedDisplay(key: "A", displayID: 1, name: "A", spec: "", isOn: true, isOnline: true),
            ManagedDisplay(key: "B", displayID: 2, name: "B", spec: "", isOn: false, isOnline: true),
        ]
        XCTAssertEqual(
            DisplayReducer.rejectionReason(toggling: displays[0], to: false, in: displays),
            .wouldLeaveNoActiveDisplay
        )
    }

    func testSwitchingOffIsAllowedWhileAnotherStaysLit() {
        let displays = [
            ManagedDisplay(key: "A", displayID: 1, name: "A", spec: "", isOn: true, isOnline: true),
            ManagedDisplay(key: "B", displayID: 2, name: "B", spec: "", isOn: true, isOnline: true),
        ]
        XCTAssertNil(DisplayReducer.rejectionReason(toggling: displays[0], to: false, in: displays))
    }

    func testSwitchingOnIsAlwaysAllowed() {
        let displays = [
            ManagedDisplay(key: "A", displayID: 1, name: "A", spec: "", isOn: true, isOnline: true),
            ManagedDisplay(key: "B", displayID: 2, name: "B", spec: "", isOn: false, isOnline: false),
        ]
        XCTAssertNil(DisplayReducer.rejectionReason(toggling: displays[1], to: true, in: displays))
    }

    func testUnknownDisplayIsRejected() {
        let stale = ManagedDisplay(key: "GONE", displayID: 9, name: "X", spec: "", isOn: true, isOnline: true)
        XCTAssertEqual(DisplayReducer.rejectionReason(toggling: stale, to: false, in: []), .unknownDisplay)
    }
}
