import CoreGraphics
import XCTest
@testable import MonitorMirrorCore

/// Exercises `DisplayPowerController` against the displays actually attached to this Mac.
///
/// Skipped unless `MM_HARDWARE_TESTS=1`, because it physically switches a monitor off and
/// on again. Every path restores the original arrangement, including on failure.
///
///     MM_HARDWARE_TESTS=1 swift test --filter HardwareIntegrationTests
///
final class HardwareIntegrationTests: XCTestCase {

    private let provider = SystemDisplayProvider()

    private func requireHardware() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MM_HARDWARE_TESTS"] == "1",
            "set MM_HARDWARE_TESTS=1 to run tests that switch real displays"
        )
        // macOS refuses every display reconfiguration while the login window is up, and
        // each attempt stalls for ten seconds before reporting an undocumented error.
        try XCTSkipIf(
            provider.sessionIsLocked(),
            "the screen is locked — unlock it to run display tests"
        )
    }

    /// Puts everything back, however the test ended. Tries the display's own path first,
    /// then falls back to asking macOS to restore the arrangement it has on file.
    private func restore(_ displayID: CGDirectDisplayID, controller: DisplayPowerController) {
        for attempt in 1...3 {
            if DisplayPowerController.isOn(displayID, in: provider.snapshot()) { return }
            if attempt == 1 {
                _ = try? controller.setOn(true, displayID: displayID)
            } else {
                _ = controller.restore(displayIDs: [displayID])
            }
        }
        XCTAssertTrue(
            DisplayPowerController.isOn(displayID, in: provider.snapshot()),
            "COULD NOT RESTORE DISPLAY \(displayID) — turn it back on in System Settings › Displays"
        )
    }

    func testSwitchesARealDisplayOffAndBackOn() throws {
        try requireHardware()

        let before = provider.snapshot()
        try XCTSkipUnless(before.filter(\.isOn).count >= 2, "needs at least two lit displays")

        // Never the main display or a built-in panel: the least disruptive target, and the
        // one a user would reach for first.
        let target = try XCTUnwrap(
            before.filter { $0.isOn && !$0.isMain && !$0.isBuiltIn }.max { $0.originX < $1.originX },
            "no external secondary display to test with"
        )
        print("[hardware] target: \(target.localizedName ?? "?") id=\(target.displayID) originX=\(target.originX)")

        let controller = DisplayPowerController(provider: provider)
        defer { restore(target.displayID, controller: controller) }

        // Off
        let strategy = try controller.setOn(false, displayID: target.displayID)
        print("[hardware] off via \(strategy.rawValue)")
        XCTAssertTrue(
            DisplayPowerController.isOff(target.displayID, in: provider.snapshot()),
            "display reported as switched off but is still drawing"
        )
        XCTAssertEqual(
            provider.snapshot().filter(\.isOn).count,
            before.filter(\.isOn).count - 1,
            "exactly one display should have gone dark"
        )

        // On
        let backOn = try controller.setOn(true, displayID: target.displayID)
        print("[hardware] on via \(backOn.rawValue)")
        XCTAssertTrue(
            DisplayPowerController.isOn(target.displayID, in: provider.snapshot()),
            "display did not come back"
        )

        // The arrangement has to survive, or every window on that desk lands somewhere new.
        let after = provider.snapshot()
        XCTAssertEqual(after.count, before.count, "display count changed")
        let restored = try XCTUnwrap(after.first { $0.displayID == target.displayID })
        XCTAssertEqual(restored.originX, target.originX, "display came back in a different position")
        XCTAssertEqual(
            Set(after.filter(\.isOn).map(\.key)),
            Set(before.filter(\.isOn).map(\.key)),
            "the set of lit displays should match the starting state"
        )
    }

    /// The whole popover flow against real hardware: click to switch a display off, and
    /// confirm its cell survives so it can be clicked again to switch it back on.
    @MainActor
    func testTheCellSurvivesARealSwitchOffAndCanSwitchItBackOn() throws {
        try requireHardware()

        let before = provider.snapshot()
        try XCTSkipUnless(before.filter(\.isOn).count >= 2, "needs at least two lit displays")
        let target = try XCTUnwrap(
            before.filter { $0.isOn && !$0.isMain && !$0.isBuiltIn }.max { $0.originX < $1.originX }
        )

        let controller = DisplayPowerController(provider: provider)
        defer { restore(target.displayID, controller: controller) }

        let manager = DisplayManager(
            provider: provider,
            controller: controller,
            store: InMemoryDisplayStore()
        )
        let cell = try XCTUnwrap(manager.displays.first { $0.key == target.key })
        let totalBefore = manager.totalCount

        manager.toggle(cell)
        try waitUntilIdle(manager)

        print("[hardware] still listed by the window server while off: "
            + "\(provider.snapshot().contains { $0.displayID == target.displayID })")

        let offCell = try XCTUnwrap(
            manager.displays.first { $0.key == target.key },
            "the cell disappeared — there would be no way to switch the display back on"
        )
        XCTAssertFalse(offCell.isOn)
        XCTAssertEqual(manager.totalCount, totalBefore, "the display should still be counted")
        XCTAssertEqual(manager.activeCount, totalBefore - 1)
        XCTAssertNil(manager.lastError)

        manager.toggle(offCell)
        try waitUntilIdle(manager)

        XCTAssertEqual(manager.activeCount, totalBefore)
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(manager.displays.first { $0.key == target.key }?.isOn, true)
    }

    /// Spins the run loop until no toggle is in flight; the manager applies changes on a
    /// detached task.
    @MainActor
    private func waitUntilIdle(_ manager: DisplayManager, timeout: TimeInterval = 15) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while manager.isBusy {
            guard Date() < deadline else { return XCTFail("toggle did not finish in time") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        // Let the trailing main-actor hop that publishes the refresh land.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    func testReassignsTheMainDisplayAndRestoresIt() throws {
        try requireHardware()

        let before = provider.snapshot()
        try XCTSkipUnless(before.count >= 2, "needs at least two displays")
        let originalMain = try XCTUnwrap(before.first(where: { $0.isMain }))
        let target = try XCTUnwrap(
            before.first { $0.isOn && !$0.isMain },
            "no other lit display to hand the menu bar to"
        )
        print("[hardware] main \(originalMain.displayID) → \(target.displayID)")

        let controller = DisplayPowerController(provider: provider)
        // Always hand the menu bar back to where it started, however this ends.
        defer {
            if !DisplayPowerController.isOn(originalMain.displayID, in: provider.snapshot())
                || provider.snapshot().first(where: { $0.isMain })?.displayID != originalMain.displayID {
                try? controller.setMain(displayID: originalMain.displayID)
            }
        }

        try controller.setMain(displayID: target.displayID)
        let mid = provider.snapshot()
        XCTAssertEqual(mid.first(where: { $0.isMain })?.displayID, target.displayID, "target should own the menu bar")
        XCTAssertEqual(mid.filter(\.isMain).count, 1)
        XCTAssertEqual(mid.count, before.count, "no display should have dropped")

        try controller.setMain(displayID: originalMain.displayID)
        let after = provider.snapshot()
        XCTAssertEqual(after.first(where: { $0.isMain })?.displayID, originalMain.displayID)
        // The whole arrangement should be back exactly where it started.
        for original in before {
            let now = try XCTUnwrap(after.first { $0.displayID == original.displayID })
            XCTAssertEqual(now.originX, original.originX, "display \(original.displayID) X moved")
            XCTAssertEqual(now.originY, original.originY, "display \(original.displayID) Y moved")
        }
    }

    func testRefusesToSwitchOffTheLastLitDisplay() throws {
        try requireHardware()

        let snapshot = provider.snapshot()
        let lit = snapshot.filter(\.isOn)
        try XCTSkipUnless(lit.count == 1, "only meaningful with a single lit display")

        let controller = DisplayPowerController(provider: provider)
        XCTAssertThrowsError(try controller.setOn(false, displayID: lit[0].displayID)) { error in
            XCTAssertEqual(error as? DisplayControlError, .wouldLeaveNoActiveDisplay)
        }
    }

    func testRejectsADisplayThatIsNotAttached() throws {
        try requireHardware()

        let controller = DisplayPowerController(provider: provider)
        XCTAssertThrowsError(try controller.setOn(false, displayID: 0xDEAD_BEEF)) { error in
            XCTAssertEqual(error as? DisplayControlError, .unknownDisplay)
        }
    }
}
