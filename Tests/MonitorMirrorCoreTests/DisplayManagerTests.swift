import Combine
import CoreGraphics
import XCTest
@testable import MonitorMirrorCore

@MainActor
final class DisplayManagerTests: XCTestCase {

    private func makeDisplay(
        id: CGDirectDisplayID,
        uuid: String,
        name: String,
        originX: Double,
        main: Bool = false
    ) -> SystemDisplay {
        SystemDisplay(
            displayID: id,
            uuid: uuid,
            localizedName: name,
            pixelWidth: 2560,
            pixelHeight: 1440,
            refreshHz: 60,
            isMain: main,
            originX: originX
        )
    }

    private func makeManager(
        behaviour: FakeDisplayController.Behaviour = .hardOff
    ) -> (DisplayManager, FakeDisplayProvider, FakeDisplayController) {
        let provider = FakeDisplayProvider([
            makeDisplay(id: 1, uuid: "A", name: "ALPHA", originX: 0, main: true),
            makeDisplay(id: 2, uuid: "B", name: "BRAVO", originX: 2560),
        ])
        let controller = FakeDisplayController(provider: provider, behaviour: behaviour)
        let manager = DisplayManager(
            provider: provider,
            controller: controller,
            store: InMemoryDisplayStore()
        )
        return (manager, provider, controller)
    }

    /// Toggles run on a detached task; wait for the in-flight set to drain.
    private func waitUntilIdle(_ manager: DisplayManager, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while manager.isBusy {
            if Date() > deadline { XCTFail("toggle did not finish in time"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Reading

    func testPublishesAttachedDisplays() {
        let (manager, _, _) = makeManager()
        XCTAssertEqual(manager.displays.map(\.name), ["ALPHA", "BRAVO"])
        XCTAssertEqual(manager.activeCount, 2)
        XCTAssertEqual(manager.totalCount, 2)
        XCTAssertTrue(manager.anyOn)
    }

    func testRefreshPicksUpADisplayAttachedBehindOurBack() {
        let (manager, provider, _) = makeManager()
        provider.mutate { $0.append(makeDisplay(id: 3, uuid: "C", name: "CHARLIE", originX: 5120)) }
        manager.refresh()
        XCTAssertEqual(manager.displays.map(\.name), ["ALPHA", "BRAVO", "CHARLIE"])
    }

    // MARK: - Toggling

    func testSwitchingOffKeepsTheCellAfterTheDisplayLeavesTheBus() async throws {
        let (manager, provider, controller) = makeManager(behaviour: .hardOff)
        let bravo = try XCTUnwrap(manager.displays.first { $0.key == "B" })

        manager.toggle(bravo)
        // The cell flips immediately so the .25s animation starts on the click.
        XCTAssertEqual(manager.displays.first { $0.key == "B" }?.isOn, false)

        try await waitUntilIdle(manager)

        XCTAssertEqual(controller.recordedCalls.map(\.on), [false])
        XCTAssertEqual(controller.recordedCalls.map(\.id), [2])
        XCTAssertFalse(provider.snapshot().contains { $0.displayID == 2 }, "display really left the bus")

        // The cell must survive, otherwise there is no way to switch it back on.
        let cell = try XCTUnwrap(manager.displays.first { $0.key == "B" })
        XCTAssertFalse(cell.isOn)
        XCTAssertFalse(cell.isOnline)
        XCTAssertEqual(manager.activeCount, 1)
        XCTAssertEqual(manager.totalCount, 2)
        XCTAssertNil(manager.lastError)
    }

    func testSwitchingBackOnUsesTheRememberedDisplayID() async throws {
        let (manager, _, controller) = makeManager(behaviour: .hardOff)
        let bravo = try XCTUnwrap(manager.displays.first { $0.key == "B" })

        manager.toggle(bravo)
        try await waitUntilIdle(manager)

        let offCell = try XCTUnwrap(manager.displays.first { $0.key == "B" })
        manager.toggle(offCell)
        try await waitUntilIdle(manager)

        XCTAssertEqual(controller.recordedCalls.map(\.on), [false, true])
        XCTAssertEqual(controller.recordedCalls.last?.id, 2, "must reuse the last known display ID")
        XCTAssertEqual(manager.activeCount, 2)
    }

    func testMirrorBackendReadsAsOffWithoutLeavingTheBus() async throws {
        let (manager, provider, _) = makeManager(behaviour: .mirror)
        let bravo = try XCTUnwrap(manager.displays.first { $0.key == "B" })

        manager.toggle(bravo)
        try await waitUntilIdle(manager)

        XCTAssertEqual(provider.snapshot().first { $0.displayID == 2 }?.mirrorsDisplay, 1)
        let cell = try XCTUnwrap(manager.displays.first { $0.key == "B" })
        XCTAssertFalse(cell.isOn)
        XCTAssertTrue(cell.isOnline)
    }

    func testAFailedToggleRollsTheCellBackAndReportsWhy() async throws {
        let (manager, _, _) = makeManager(behaviour: .fail(.didNotTakeEffect))
        let bravo = try XCTUnwrap(manager.displays.first { $0.key == "B" })

        manager.toggle(bravo)
        try await waitUntilIdle(manager)

        XCTAssertEqual(manager.displays.first { $0.key == "B" }?.isOn, true, "cell must return to reality")
        XCTAssertEqual(manager.lastError, DisplayControlError.didNotTakeEffect.errorDescription)
        XCTAssertEqual(manager.activeCount, 2)
    }

    func testAFailedSwitchOffLeavesNoGhostCellBehind() async throws {
        // If the intent flag survived a failure, the display would keep a phantom cell
        // the moment it was later unplugged.
        let (manager, provider, _) = makeManager(behaviour: .fail(.didNotTakeEffect))
        let bravo = try XCTUnwrap(manager.displays.first { $0.key == "B" })

        manager.toggle(bravo)
        try await waitUntilIdle(manager)

        provider.mutate { $0.removeAll { $0.displayID == 2 } }
        manager.refresh()
        XCTAssertEqual(manager.displays.map(\.key), ["A"])
    }

    func testTheLastLitDisplayCannotBeSwitchedOff() async throws {
        let (manager, _, controller) = makeManager(behaviour: .hardOff)

        manager.toggle(try XCTUnwrap(manager.displays.first { $0.key == "B" }))
        try await waitUntilIdle(manager)

        let alpha = try XCTUnwrap(manager.displays.first { $0.key == "A" })
        manager.toggle(alpha)

        XCTAssertEqual(manager.lastError, DisplayControlError.wouldLeaveNoActiveDisplay.errorDescription)
        XCTAssertEqual(controller.recordedCalls.count, 1, "no second call should have been attempted")
        XCTAssertTrue(manager.anyOn)
    }

    func testASecondClickIsIgnoredWhileAToggleIsInFlight() async throws {
        let (manager, _, controller) = makeManager(behaviour: .hardOff)
        let bravo = try XCTUnwrap(manager.displays.first { $0.key == "B" })

        manager.toggle(bravo)
        manager.toggle(bravo)
        manager.toggle(bravo)
        try await waitUntilIdle(manager)

        XCTAssertEqual(controller.recordedCalls.count, 1)
    }

    func testRestoreAllBringsBackAHardOffDisplayAndClearsItsIntent() async throws {
        let (manager, _, _) = makeManager(behaviour: .hardOff)

        manager.toggle(try XCTUnwrap(manager.displays.first { $0.key == "B" }))
        try await waitUntilIdle(manager)
        XCTAssertEqual(manager.totalCount, 2)
        XCTAssertEqual(manager.activeCount, 1)

        manager.restoreAllDisplays()
        try await waitUntilIdle(manager)

        XCTAssertEqual(manager.activeCount, 2, "the display should be back on")
        XCTAssertEqual(manager.totalCount, 2)
        XCTAssertEqual(manager.displays.first { $0.key == "B" }?.isOn, true)
        XCTAssertNil(manager.lastError)
    }

    func testRestoreThatFailsKeepsTheCellAndTheRememberedEntry() async throws {
        // The core reliability guarantee: a restore that does not bring the display back
        // must not erase the only way left to reach it.
        let (manager, _, controller) = makeManager(behaviour: .hardOff)

        manager.toggle(try XCTUnwrap(manager.displays.first { $0.key == "B" }))
        try await waitUntilIdle(manager)

        // Now the display refuses to come back.
        controller.set(behaviour: .fail(.displayUnavailable))
        manager.restoreAllDisplays()
        try await waitUntilIdle(manager)

        // The cell and its off state survive, and the user is told.
        let cell = try XCTUnwrap(manager.displays.first { $0.key == "B" })
        XCTAssertFalse(cell.isOn)
        XCTAssertFalse(cell.isOnline)
        XCTAssertEqual(manager.totalCount, 2)
        XCTAssertNotNil(manager.lastError)

        // And a later successful restore still works — the entry was never lost.
        controller.set(behaviour: .hardOff)
        manager.restoreAllDisplays()
        try await waitUntilIdle(manager)
        XCTAssertEqual(manager.activeCount, 2)
    }

    // MARK: - Main display

    func testSetMainMovesTheMainFlagAndClearsTheOldOne() async throws {
        let (manager, _, controller) = makeManager()
        XCTAssertEqual(manager.displays.first { $0.key == "A" }?.isMain, true)

        let bravo = try XCTUnwrap(manager.displays.first { $0.key == "B" })
        manager.setMain(bravo)
        // Optimistic: the indicator moves on the click.
        XCTAssertEqual(manager.displays.first { $0.key == "B" }?.isMain, true)
        XCTAssertEqual(manager.displays.first { $0.key == "A" }?.isMain, false)

        try await waitUntilIdle(manager)

        XCTAssertEqual(controller.mainCalls, [2])
        XCTAssertEqual(manager.displays.first { $0.key == "B" }?.isMain, true)
        XCTAssertEqual(manager.displays.filter(\.isMain).count, 1, "exactly one main display")
        XCTAssertNil(manager.lastError)
    }

    func testSettingTheCurrentMainAgainDoesNothing() {
        let (manager, _, controller) = makeManager()
        let alpha = try! XCTUnwrap(manager.displays.first { $0.key == "A" })
        manager.setMain(alpha)
        XCTAssertTrue(controller.mainCalls.isEmpty)
        XCTAssertFalse(manager.isBusy)
    }

    func testAnOffDisplayCannotBecomeMain() async throws {
        let (manager, _, controller) = makeManager(behaviour: .hardOff)

        // Turn BRAVO off, then try to make it main.
        manager.toggle(try XCTUnwrap(manager.displays.first { $0.key == "B" }))
        try await waitUntilIdle(manager)

        let offCell = try XCTUnwrap(manager.displays.first { $0.key == "B" })
        manager.setMain(offCell)

        XCTAssertTrue(controller.mainCalls.isEmpty)
        XCTAssertEqual(manager.lastError, DisplayControlError.cannotMakeOffDisplayMain.errorDescription)
        XCTAssertEqual(manager.displays.first { $0.key == "A" }?.isMain, true, "main is unchanged")
    }

    func testAFailedSetMainRollsBackTheIndicator() async throws {
        let (manager, _, _) = makeManager(behaviour: .fail(.didNotTakeEffect))
        let bravo = try XCTUnwrap(manager.displays.first { $0.key == "B" })

        manager.setMain(bravo)
        try await waitUntilIdle(manager)

        // The optimistic flag must return to reality after the failure.
        XCTAssertEqual(manager.displays.first { $0.key == "A" }?.isMain, true)
        XCTAssertEqual(manager.displays.first { $0.key == "B" }?.isMain, false)
        XCTAssertEqual(manager.lastError, DisplayControlError.didNotTakeEffect.errorDescription)
    }

    // MARK: - Persistence

    func testALockedSessionIsReportedAndNoCellIsLeftStuck() async throws {
        let (manager, provider, controller) = makeManager(behaviour: .hardOff)
        provider.setLocked(true)
        // The controller checks the real session state itself, so make it fail the way the
        // real one does when locked.
        controller.set(behaviour: .fail(.sessionLocked))

        manager.toggle(try XCTUnwrap(manager.displays.first { $0.key == "B" }))
        try await waitUntilIdle(manager)

        XCTAssertEqual(manager.lastError, DisplayControlError.sessionLocked.errorDescription)
        // The cell must snap back to its real state, not stay stuck mid-toggle.
        XCTAssertEqual(manager.displays.first { $0.key == "B" }?.isOn, true)
        XCTAssertFalse(manager.isBusy)
    }

    func testAnOffDisplaySurvivesARelaunch() async throws {
        let provider = FakeDisplayProvider([
            makeDisplay(id: 1, uuid: "A", name: "ALPHA", originX: 0, main: true),
            makeDisplay(id: 2, uuid: "B", name: "BRAVO", originX: 2560),
        ])
        let controller = FakeDisplayController(provider: provider, behaviour: .hardOff)
        let store = InMemoryDisplayStore()

        let first = DisplayManager(provider: provider, controller: controller, store: store)
        first.toggle(try XCTUnwrap(first.displays.first { $0.key == "B" }))
        try await waitUntilIdle(first)

        // Same store, fresh manager — as if the app had been quit and reopened.
        let second = DisplayManager(provider: provider, controller: controller, store: store)
        let cell = try XCTUnwrap(second.displays.first { $0.key == "B" })
        XCTAssertFalse(cell.isOn)
        XCTAssertFalse(cell.isOnline)
        XCTAssertEqual(cell.displayID, 2)
    }
}
