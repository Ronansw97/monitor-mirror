import CoreGraphics
import Foundation

/// What the popover renders for a single display.
public struct ManagedDisplay: Identifiable, Equatable, Sendable {
    public var id: String { key }
    /// Stable identity — see `SystemDisplay.key`.
    public var key: String
    /// The ID to pass back to CoreGraphics. For an offline display this is the last
    /// ID we saw, which is what re-enabling needs.
    public var displayID: CGDirectDisplayID
    public var name: String
    public var spec: String
    public var isOn: Bool
    /// False when the display has been switched off hard and has dropped off the bus.
    public var isOnline: Bool
    public var isMain: Bool
    public var isBuiltIn: Bool

    public init(
        key: String,
        displayID: CGDirectDisplayID,
        name: String,
        spec: String,
        isOn: Bool,
        isOnline: Bool,
        isMain: Bool = false,
        isBuiltIn: Bool = false
    ) {
        self.key = key
        self.displayID = displayID
        self.name = name
        self.spec = spec
        self.isOn = isOn
        self.isOnline = isOnline
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
    }
}

/// A display we have seen before, kept so a display switched off hard — which
/// disappears from the window server entirely — still has a cell to switch back on.
public struct RememberedDisplay: Codable, Equatable, Sendable {
    public var key: String
    public var displayID: CGDirectDisplayID
    public var name: String
    public var spec: String
    public var originX: Double
    public var isBuiltIn: Bool
    /// True when *this app* turned the display off. Only these survive going offline;
    /// a display the user simply unplugged is forgotten.
    public var wantsOff: Bool
    public var lastSeen: Date

    public init(
        key: String,
        displayID: CGDirectDisplayID,
        name: String,
        spec: String,
        originX: Double,
        isBuiltIn: Bool,
        wantsOff: Bool,
        lastSeen: Date
    ) {
        self.key = key
        self.displayID = displayID
        self.name = name
        self.spec = spec
        self.originX = originX
        self.isBuiltIn = isBuiltIn
        self.wantsOff = wantsOff
        self.lastSeen = lastSeen
    }
}

/// Merges what the window server currently reports with what we remember, producing
/// the list the UI draws. Kept pure so every edge case below is unit-testable.
public enum DisplayReducer {

    /// How long an off-but-absent display keeps its cell. Long enough to survive a
    /// weekend and a couple of reboots; short enough that a monitor sold months ago
    /// does not haunt the popover.
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    public struct Output: Equatable {
        public var displays: [ManagedDisplay]
        public var remembered: [RememberedDisplay]
    }

    public static func reconcile(
        online: [SystemDisplay],
        remembered: [RememberedDisplay],
        now: Date
    ) -> Output {
        var rememberedByKey = Dictionary(remembered.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [(originX: Double, display: ManagedDisplay)] = []
        var nextRemembered: [RememberedDisplay] = []

        for system in online {
            let key = system.key
            let name = DisplayNaming.shortName(from: system.localizedName, isBuiltIn: system.isBuiltIn)
            let spec = DisplayNaming.spec(
                pixelWidth: system.pixelWidth,
                pixelHeight: system.pixelHeight,
                refreshHz: system.refreshHz
            )

            rows.append((system.originX, ManagedDisplay(
                key: key,
                displayID: system.displayID,
                name: name,
                spec: spec,
                isOn: system.isOn,
                isOnline: true,
                isMain: system.isMain,
                isBuiltIn: system.isBuiltIn
            )))

            // `wantsOff` records whether *this app* switched the display off — the manager
            // sets it before toggling. Reconcile must not fabricate it from raw state, or a
            // display someone mirrored in System Settings would be retained for 30 days
            // after unplugging. So an on display clears it; an off one keeps whatever intent
            // we already recorded (false when we never touched it).
            let priorIntent = rememberedByKey[key]?.wantsOff ?? false
            nextRemembered.append(RememberedDisplay(
                key: key,
                displayID: system.displayID,
                name: name,
                spec: spec,
                // A mirrored display reports the master's origin, so keep the last
                // standalone position rather than stacking every off display at 0.
                originX: system.isOn ? system.originX : (rememberedByKey[key]?.originX ?? system.originX),
                isBuiltIn: system.isBuiltIn,
                wantsOff: system.isOn ? false : priorIntent,
                lastSeen: now
            ))
            rememberedByKey.removeValue(forKey: key)
        }

        // Anything left in `rememberedByKey` is not currently reported by the window
        // server. Keep only the ones we deliberately switched off, and only for a while.
        for entry in rememberedByKey.values {
            guard entry.wantsOff, now.timeIntervalSince(entry.lastSeen) <= retention else { continue }
            rows.append((entry.originX, ManagedDisplay(
                key: entry.key,
                displayID: entry.displayID,
                name: entry.name,
                spec: entry.spec,
                isOn: false,
                isOnline: false,
                isMain: false,
                isBuiltIn: entry.isBuiltIn
            )))
            nextRemembered.append(entry)
        }

        // Order cells the way the displays are physically arranged, left to right.
        // `key` breaks ties so the order never flickers between refreshes.
        rows.sort { ($0.originX, $0.display.key) < ($1.originX, $1.display.key) }

        var displays = rows.map(\.display)
        let unique = DisplayNaming.disambiguate(displays.map(\.name))
        for index in displays.indices { displays[index].name = unique[index] }

        nextRemembered.sort { $0.key < $1.key }
        return Output(displays: displays, remembered: nextRemembered)
    }

    /// Why a requested toggle cannot be performed. `nil` means it is allowed.
    public static func rejectionReason(
        toggling target: ManagedDisplay,
        to desiredOn: Bool,
        in displays: [ManagedDisplay]
    ) -> DisplayControlError? {
        guard displays.contains(where: { $0.key == target.key }) else { return .unknownDisplay }
        guard target.isOn != desiredOn else { return nil }
        // Switching the last lit display off would leave the machine with nowhere to
        // draw — including this app's own popover.
        if !desiredOn && displays.filter(\.isOn).count <= 1 { return .wouldLeaveNoActiveDisplay }
        return nil
    }
}
