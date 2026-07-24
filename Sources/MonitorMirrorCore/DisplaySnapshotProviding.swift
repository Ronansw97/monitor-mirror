import AppKit
import CoreGraphics
import Foundation

public protocol DisplaySnapshotProviding: AnyObject, Sendable {
    /// Every display the window server currently reports, on or off, including
    /// `NSScreen`-derived names. **Main-thread only** — `NSScreen` is main-thread-affine.
    func snapshot() -> [SystemDisplay]
    /// Power state and geometry only, read purely through CoreGraphics with no `NSScreen`
    /// access, so it is safe to poll from a background thread. Names come back empty.
    func powerSnapshot() -> [SystemDisplay]
    /// The display that owns the menu bar; mirroring targets it.
    func mainDisplayID() -> CGDirectDisplayID
    /// True when the screen is locked or the login window is up. macOS blocks display
    /// reconfiguration then, so the controller checks this before attempting a change.
    func sessionIsLocked() -> Bool
}

public extension DisplaySnapshotProviding {
    /// Default so fakes only override it when a test cares about the locked state.
    func sessionIsLocked() -> Bool { false }
    /// Fakes hold a single list that already carries power state, so the two snapshots
    /// coincide for them; only the live provider needs to split `NSScreen` off.
    func powerSnapshot() -> [SystemDisplay] { snapshot() }
}

/// The live reading, straight from CoreGraphics and AppKit.
public final class SystemDisplayProvider: DisplaySnapshotProviding {
    // Stateless: every call reads straight from CoreGraphics/AppKit.

    public init() {}

    public func mainDisplayID() -> CGDirectDisplayID {
        CGMainDisplayID()
    }

    public func sessionIsLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        // Present and 1 while locked; absent or 0 otherwise.
        return (info["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    public func powerSnapshot() -> [SystemDisplay] {
        onlineIDs().map { Self.read($0, name: nil) }
    }

    public func snapshot() -> [SystemDisplay] {
        let ids = onlineIDs()
        guard !ids.isEmpty else { return [] }

        // Built once per snapshot rather than per display — `NSScreen.screens` is a
        // relatively expensive bridge and this runs on every reconfiguration event.
        var namesByID: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            namesByID[number.uint32Value] = screen.localizedName
        }

        return ids.map { Self.read($0, name: namesByID[$0]) }
    }

    private func onlineIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Reads everything about one display through CoreGraphics alone. `name` is threaded
    /// in from `NSScreen` by `snapshot()`; the background `powerSnapshot()` passes nil.
    private static func read(_ id: CGDirectDisplayID, name: String?) -> SystemDisplay {
        let mode = CGDisplayCopyDisplayMode(id)
        let bounds = CGDisplayBounds(id)
        return SystemDisplay(
            displayID: id,
            uuid: uuidString(for: id),
            vendor: CGDisplayVendorNumber(id),
            model: CGDisplayModelNumber(id),
            serial: CGDisplaySerialNumber(id),
            unitNumber: CGDisplayUnitNumber(id),
            localizedName: name,
            pixelWidth: mode?.pixelWidth ?? Int(bounds.width),
            pixelHeight: mode?.pixelHeight ?? Int(bounds.height),
            refreshHz: mode?.refreshRate ?? 0,
            isBuiltIn: CGDisplayIsBuiltin(id) != 0,
            isMain: CGDisplayIsMain(id) != 0,
            mirrorsDisplay: CGDisplayMirrorsDisplay(id),
            originX: bounds.origin.x,
            originY: bounds.origin.y
        )
    }

    static func uuidString(for id: CGDirectDisplayID) -> String? {
        guard let ref = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        let uuid = ref.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
