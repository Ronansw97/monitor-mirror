import CoreGraphics
import XCTest
@testable import MonitorMirrorCore

final class RememberedDisplayStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "monitor-mirror-tests"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func entry(_ key: String) -> RememberedDisplay {
        RememberedDisplay(
            key: key,
            displayID: 3,
            name: "LG",
            spec: "QHD · 144HZ",
            originX: 2560,
            isBuiltIn: false,
            wantsOff: true,
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testRoundTrip() {
        let store = UserDefaultsDisplayStore(defaults: defaults)
        store.save([entry("A"), entry("B")])
        XCTAssertEqual(UserDefaultsDisplayStore(defaults: defaults).load(), [entry("A"), entry("B")])
    }

    func testEmptyOnFirstRun() {
        XCTAssertEqual(UserDefaultsDisplayStore(defaults: defaults).load(), [])
    }

    func testCorruptDataDoesNotThrow() {
        // A registry written by a future version must not stop the app from launching.
        defaults.set(Data("not json".utf8), forKey: "remembered-displays.v1")
        XCTAssertEqual(UserDefaultsDisplayStore(defaults: defaults).load(), [])
    }
}

final class DisplayPowerControllerStateTests: XCTestCase {

    private func display(_ id: CGDirectDisplayID, mirrors: CGDirectDisplayID = 0) -> SystemDisplay {
        SystemDisplay(displayID: id, uuid: "\(id)", mirrorsDisplay: mirrors)
    }

    func testADisplayMissingFromTheSnapshotCountsAsOff() {
        // A hard power-off drops the display off the bus entirely.
        XCTAssertTrue(DisplayPowerController.isOff(9, in: [display(1)]))
        XCTAssertFalse(DisplayPowerController.isOn(9, in: [display(1)]))
    }

    func testAMirroredDisplayCountsAsOff() {
        let snapshot = [display(1), display(2, mirrors: 1)]
        XCTAssertTrue(DisplayPowerController.isOff(2, in: snapshot))
        XCTAssertFalse(DisplayPowerController.isOn(2, in: snapshot))
    }

    func testAStandaloneDisplayCountsAsOn() {
        let snapshot = [display(1), display(2)]
        XCTAssertTrue(DisplayPowerController.isOn(2, in: snapshot))
        XCTAssertFalse(DisplayPowerController.isOff(2, in: snapshot))
    }

    func testEveryErrorHasAMessageWorthShowing() {
        let errors: [DisplayControlError] = [
            .unknownDisplay, .wouldLeaveNoActiveDisplay, .noMainDisplay,
            .didNotTakeEffect, .displayUnavailable, .configurationFailed(-1),
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty, "\(error) has no message")
        }
    }
}

final class SkyLightBridgeTests: XCTestCase {

    func testResolvesTheDisplayEnableSymbolOnThisSystem() {
        // If this ever fails, the app still works — it falls back to mirroring — but the
        // hard power-off path is gone and we want to know about it.
        XCTAssertTrue(SkyLightBridge().isAvailable)
    }

    func testMissingFrameworkDegradesInsteadOfCrashing() {
        let bridge = SkyLightBridge(frameworkPath: "/nonexistent/Nope.framework/Nope")
        XCTAssertFalse(bridge.isAvailable)
        XCTAssertNil(bridge.setDisplayEnabled(false, display: 1, config: nil))
    }
}
