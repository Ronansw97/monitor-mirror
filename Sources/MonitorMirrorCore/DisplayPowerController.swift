import CoreGraphics
import Foundation

public enum DisplayControlError: Error, Equatable, LocalizedError {
    case unknownDisplay
    case wouldLeaveNoActiveDisplay
    case noMainDisplay
    /// The screen is locked or the login window is up; macOS will not reconfigure displays then.
    case sessionLocked
    /// Every strategy ran without reporting an error, yet the display did not change state.
    case didNotTakeEffect
    /// The display is not reachable — usually unplugged while it was switched off.
    case displayUnavailable
    /// A display that is off (or offline) cannot own the menu bar.
    case cannotMakeOffDisplayMain
    /// The window server rejected the change outright.
    case configurationFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .unknownDisplay:
            return "That display is no longer attached."
        case .wouldLeaveNoActiveDisplay:
            return "At least one display has to stay on."
        case .noMainDisplay:
            return "No main display was reported by the system."
        case .sessionLocked:
            return "macOS will not change displays while the screen is locked."
        case .didNotTakeEffect:
            return "macOS accepted the change but the display did not switch."
        case .displayUnavailable:
            return "The display did not come back. It may have been unplugged."
        case .cannotMakeOffDisplayMain:
            return "Turn the display on before making it the main display."
        case .configurationFailed(let code):
            return "macOS refused the display change (error \(code)). Try again in a moment."
        }
    }
}

/// How a display was actually switched.
public enum DisplayControlStrategy: String, Equatable, Sendable {
    /// Powered down through the window server — the panel goes dark and drops off the bus.
    case hardOff
    /// Folded into another display's mirror set — the publicly supported fallback.
    case mirror
    /// It was already in the requested state.
    case noChange
}

/// Applies on/off changes to displays. Split out from `DisplayPowerController` so the
/// manager's state handling can be tested without touching real hardware.
public protocol DisplayPowerControlling: AnyObject, Sendable {
    var supportsHardOff: Bool { get }
    @discardableResult
    func setOn(_ desiredOn: Bool, displayID: CGDirectDisplayID) throws -> DisplayControlStrategy
    /// Switches the given displays back on, one by one. Returns the IDs that were
    /// confirmed on afterwards, so the caller only clears the off-intent for those.
    func restore(displayIDs: [CGDirectDisplayID]) -> Set<CGDirectDisplayID>
    /// Makes the given display the main one — the display that owns the menu bar. Preserves
    /// the relative arrangement of every other display.
    func setMain(displayID: CGDirectDisplayID) throws
}

/// Applies on/off changes to real displays, verifies they took, and degrades from the
/// private hard power-off to public mirroring when it has to.
///
/// Every method blocks until the change is observed (or times out), so callers should
/// stay off the main thread. `DisplayManager` handles that.
public final class DisplayPowerController: DisplayPowerControlling, @unchecked Sendable {

    /// How long to wait for the window server to settle after committing a configuration.
    /// Hard power-off over DisplayPort can take well over a second.
    private let settleTimeout: TimeInterval
    private let pollInterval: TimeInterval

    private let skyLight: SkyLightBridge
    private let provider: DisplaySnapshotProviding
    /// Serialises configuration transactions: two overlapping ones would fight over the
    /// window server and leave the arrangement in a state neither caller expected.
    private let lock = NSLock()

    public init(
        provider: DisplaySnapshotProviding,
        skyLight: SkyLightBridge = .shared,
        settleTimeout: TimeInterval = 3.0,
        pollInterval: TimeInterval = 0.05
    ) {
        self.provider = provider
        self.skyLight = skyLight
        self.settleTimeout = settleTimeout
        self.pollInterval = pollInterval
    }

    public var supportsHardOff: Bool { skyLight.isAvailable }

    /// Switches one display on or off. Returns the strategy that actually worked.
    ///
    /// - Throws: `DisplayControlError` when the change is unsafe, impossible, or refused.
    @discardableResult
    public func setOn(_ desiredOn: Bool, displayID: CGDirectDisplayID) throws -> DisplayControlStrategy {
        lock.lock()
        defer { lock.unlock() }

        // While the login window is up, `CGCompleteDisplayConfiguration` does not fail
        // fast — it blocks for ten seconds and then reports an undocumented error. Check
        // first so the popover gets an honest answer straight away.
        guard !provider.sessionIsLocked() else { throw DisplayControlError.sessionLocked }

        return desiredOn ? try turnOn(displayID) : try turnOff(displayID)
    }

    /// Makes `displayID` the main display — the one macOS puts the menu bar on — by
    /// translating the whole arrangement so the target sits at the global origin (0,0),
    /// which is what "main" means to the window server. Relative positions are preserved,
    /// so nothing else on the desktop moves relative to its neighbours.
    public func setMain(displayID: CGDirectDisplayID) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !provider.sessionIsLocked() else { throw DisplayControlError.sessionLocked }

        let snapshot = provider.powerSnapshot()
        guard let target = snapshot.first(where: { $0.displayID == displayID }) else {
            throw DisplayControlError.unknownDisplay
        }
        // A mirrored/off display is not drawing its own desktop, so it cannot hold the menu bar.
        guard target.isOn else { throw DisplayControlError.cannotMakeOffDisplayMain }
        guard !target.isMain else { return }

        // Reading the target's current origin once; every display shifts by the negative of
        // it, which lands the target on (0,0) and leaves the rest where they were relative
        // to it.
        let dx = target.originX
        let dy = target.originY

        switch commit({ config in
            for display in snapshot {
                let error = CGConfigureDisplayOrigin(
                    config,
                    display.displayID,
                    Int32((display.originX - dx).rounded()),
                    Int32((display.originY - dy).rounded())
                )
                guard error == .success else { return false }
            }
            return true
        }) {
        case .committed:
            guard waitUntil({ $0.contains { $0.displayID == displayID && $0.isMain } }) else {
                throw DisplayControlError.didNotTakeEffect
            }
        case .refused(let code):
            throw DisplayControlError.configurationFailed(code)
        case .notStaged:
            throw DisplayControlError.didNotTakeEffect
        }
    }

    /// The escape hatch: switch a set of displays back on. Each goes through the same
    /// per-display `turnOn` path that ordinary re-enabling uses — which is the *only* path
    /// that actually powers a hard-off panel back up — and only the ones observed on
    /// afterwards are reported, so the caller never clears an off-intent for a display that
    /// did not really come back.
    public func restore(displayIDs: [CGDirectDisplayID]) -> Set<CGDirectDisplayID> {
        lock.lock()
        defer { lock.unlock() }

        guard !provider.sessionIsLocked() else { return [] }

        var restored: Set<CGDirectDisplayID> = []
        for id in displayIDs {
            if (try? turnOn(id)) != nil, Self.isOn(id, in: provider.powerSnapshot()) {
                restored.insert(id)
            }
        }

        // A last sweep for anything macOS remembers but the per-display path could not
        // reach (e.g. a display that never produced a SkyLight enable). Harmless when
        // there is nothing left to do.
        if restored.count < displayIDs.count {
            CGRestorePermanentDisplayConfiguration()
            _ = waitUntil { snapshot in displayIDs.allSatisfy { Self.isOn($0, in: snapshot) } }
            for id in displayIDs where Self.isOn(id, in: provider.powerSnapshot()) {
                restored.insert(id)
            }
        }
        return restored
    }

    // MARK: - Off

    private func turnOff(_ displayID: CGDirectDisplayID) throws -> DisplayControlStrategy {
        // Re-check at the point of action: the snapshot the UI decided from may be stale
        // by now, since a display can drop off between the click and this call.
        let before = provider.powerSnapshot()
        guard before.contains(where: { $0.displayID == displayID }) else {
            throw DisplayControlError.unknownDisplay
        }
        guard Self.isOn(displayID, in: before) else { return .noChange }
        guard before.filter(\.isOn).count > 1 else { throw DisplayControlError.wouldLeaveNoActiveDisplay }

        // Preferred: genuinely power the panel down.
        if skyLight.isAvailable {
            switch commit({ self.skyLight.setDisplayEnabled(false, display: displayID, config: $0) == .success }) {
            case .committed:
                if waitUntil({ Self.isOff(displayID, in: $0) }) { return .hardOff }
            case .refused(let code):
                // A refusal is about the window server, not about this particular change,
                // so mirroring would only stall for another ten seconds.
                throw DisplayControlError.configurationFailed(code)
            case .notStaged:
                break   // SkyLight would not take it; fall through to mirroring.
            }
        }

        // Fallback: fold the display into another one's mirror set. Public API, always
        // available, but the panel stays lit showing a copy.
        let master = try mirrorMaster(for: displayID)
        switch commit({ CGConfigureDisplayMirrorOfDisplay($0, displayID, master) == .success }) {
        case .committed:
            guard waitUntil({ Self.isOff(displayID, in: $0) }) else {
                throw DisplayControlError.didNotTakeEffect
            }
            return .mirror
        case .refused(let code):
            throw DisplayControlError.configurationFailed(code)
        case .notStaged:
            throw DisplayControlError.didNotTakeEffect
        }
    }

    /// The display to mirror onto. Normally the main one; if the target *is* the main
    /// display, any other lit display will do.
    private func mirrorMaster(for displayID: CGDirectDisplayID) throws -> CGDirectDisplayID {
        let main = provider.mainDisplayID()
        guard main != 0 else { throw DisplayControlError.noMainDisplay }
        guard main == displayID else { return main }
        guard let other = provider.powerSnapshot().first(where: { $0.isOn && $0.displayID != displayID })
        else { throw DisplayControlError.wouldLeaveNoActiveDisplay }
        return other.displayID
    }

    // MARK: - On

    private func turnOn(_ displayID: CGDirectDisplayID) throws -> DisplayControlStrategy {
        let before = provider.powerSnapshot()
        guard !Self.isOn(displayID, in: before) else { return .noChange }

        // Present but mirrored: clearing the mirror is all it takes.
        if before.contains(where: { $0.displayID == displayID }) {
            switch commit({ CGConfigureDisplayMirrorOfDisplay($0, displayID, kCGNullDirectDisplay) == .success }) {
            case .committed:
                if waitUntil({ Self.isOn(displayID, in: $0) }) { return .mirror }
            case .refused(let code):
                throw DisplayControlError.configurationFailed(code)
            case .notStaged:
                break
            }
        }

        // Absent from the window server: it was powered down hard, so power it back up.
        if skyLight.isAvailable {
            switch commit({ self.skyLight.setDisplayEnabled(true, display: displayID, config: $0) == .success }) {
            case .committed:
                if waitUntil({ Self.isOn(displayID, in: $0) }) { return .hardOff }
            case .refused(let code):
                throw DisplayControlError.configurationFailed(code)
            case .notStaged:
                break
            }
        }

        throw DisplayControlError.displayUnavailable
    }

    // MARK: - Transactions

    private enum CommitOutcome {
        /// The window server accepted the transaction. Whether it had the intended effect
        /// still has to be verified by reading the display list back.
        case committed
        /// The staging call itself refused — the operation is not supported here.
        case notStaged
        /// The window server rejected or timed out the commit.
        case refused(Int32)
    }

    /// Opens a display-configuration transaction, lets `stage` add changes to it, and
    /// commits — cancelling instead if staging failed, so a half-built configuration is
    /// never left open.
    private func commit(_ stage: (CGDisplayConfigRef?) -> Bool) -> CommitOutcome {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else { return .refused(begin.rawValue) }

        guard stage(config) else {
            CGCancelDisplayConfiguration(config)
            return .notStaged
        }

        // `.permanently` so the arrangement survives a relaunch or reboot, which is what
        // people expect from macOS display settings. `restoreAllDisplays()` is the undo.
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        return complete == .success ? .committed : .refused(complete.rawValue)
    }

    /// Polls the real display list until `predicate` holds or `settleTimeout` elapses.
    /// Verifying rather than trusting the return code is the whole point: the private
    /// call can report success and do nothing.
    private func waitUntil(_ predicate: ([SystemDisplay]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(settleTimeout)
        repeat {
            if predicate(provider.powerSnapshot()) { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return predicate(provider.powerSnapshot())
    }

    /// Off means either gone from the window server entirely, or present but mirroring
    /// something else.
    static func isOff(_ displayID: CGDirectDisplayID, in snapshot: [SystemDisplay]) -> Bool {
        guard let display = snapshot.first(where: { $0.displayID == displayID }) else { return true }
        return !display.isOn
    }

    static func isOn(_ displayID: CGDirectDisplayID, in snapshot: [SystemDisplay]) -> Bool {
        snapshot.contains { $0.displayID == displayID && $0.isOn }
    }
}
