import CoreGraphics
import Foundation
@testable import MonitorMirrorCore

/// A stand-in window server. Thread-safe because the manager reads it on the main actor
/// while the fake controller mutates it from a background task, exactly like the real one.
final class FakeDisplayProvider: DisplaySnapshotProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var displays: [SystemDisplay]
    private var main: CGDirectDisplayID
    private var locked: Bool

    init(_ displays: [SystemDisplay], main: CGDirectDisplayID = 1, locked: Bool = false) {
        self.displays = displays
        self.main = main
        self.locked = locked
    }

    func sessionIsLocked() -> Bool {
        lock.withLock { locked }
    }

    func setLocked(_ locked: Bool) {
        lock.withLock { self.locked = locked }
    }

    func snapshot() -> [SystemDisplay] {
        lock.withLock { displays }
    }

    func mainDisplayID() -> CGDirectDisplayID {
        lock.withLock { main }
    }

    func mutate(_ body: (inout [SystemDisplay]) -> Void) {
        lock.withLock { body(&displays) }
    }
}

/// A controller that either applies the change to a `FakeDisplayProvider` or fails.
final class FakeDisplayController: DisplayPowerControlling, @unchecked Sendable {

    enum Behaviour {
        /// Mirrors the display onto the main one, so it stays visible but reads as off.
        case mirror
        /// Removes the display from the list entirely, like a real hard power-off.
        case hardOff
        case fail(DisplayControlError)
    }

    let supportsHardOff = true

    private let provider: FakeDisplayProvider
    private let lock = NSLock()
    private var behaviour: Behaviour
    private var calls: [(on: Bool, id: CGDirectDisplayID)] = []
    /// Full records of hard-off displays, so a restore brings each back with its original
    /// identity — exactly as real hardware does (same UUID → same key).
    private var poweredOff: [CGDirectDisplayID: SystemDisplay] = [:]

    init(provider: FakeDisplayProvider, behaviour: Behaviour = .hardOff) {
        self.provider = provider
        self.behaviour = behaviour
    }

    var recordedCalls: [(on: Bool, id: CGDirectDisplayID)] { lock.withLock { calls } }

    func set(behaviour: Behaviour) { lock.withLock { self.behaviour = behaviour } }

    func setOn(_ desiredOn: Bool, displayID: CGDirectDisplayID) throws -> DisplayControlStrategy {
        let behaviour = lock.withLock {
            calls.append((desiredOn, displayID))
            return self.behaviour
        }

        switch behaviour {
        case .fail(let error):
            throw error

        case .mirror:
            let main = provider.mainDisplayID()
            provider.mutate { displays in
                guard let index = displays.firstIndex(where: { $0.displayID == displayID }) else { return }
                displays[index].mirrorsDisplay = desiredOn ? 0 : main
            }
            return .mirror

        case .hardOff:
            if desiredOn {
                let restored = lock.withLock { poweredOff.removeValue(forKey: displayID) }
                provider.mutate { displays in
                    guard !displays.contains(where: { $0.displayID == displayID }), let restored else { return }
                    displays.append(restored)
                }
            } else {
                provider.mutate { displays in
                    guard let index = displays.firstIndex(where: { $0.displayID == displayID }) else { return }
                    let removed = displays.remove(at: index)
                    self.lock.withLock { self.poweredOff[displayID] = removed }
                }
            }
            return .hardOff
        }
    }

    func restore(displayIDs: [CGDirectDisplayID]) -> Set<CGDirectDisplayID> {
        var restored: Set<CGDirectDisplayID> = []
        for id in displayIDs {
            if (try? setOn(true, displayID: id)) != nil,
               DisplayPowerController.isOn(id, in: provider.powerSnapshot()) {
                restored.insert(id)
            }
        }
        return restored
    }

    private(set) var mainCalls: [CGDirectDisplayID] = []

    func setMain(displayID: CGDirectDisplayID) throws {
        let behaviour = lock.withLock { mainCalls.append(displayID); return self.behaviour }
        if case .fail(let error) = behaviour { throw error }
        provider.mutate { displays in
            guard displays.contains(where: { $0.displayID == displayID && $0.isOn }) else { return }
            for index in displays.indices {
                displays[index].isMain = (displays[index].displayID == displayID)
            }
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
