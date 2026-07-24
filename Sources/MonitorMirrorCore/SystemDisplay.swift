import CoreGraphics
import Foundation

/// A raw, point-in-time reading of one display straight from the window server.
///
/// This is deliberately a plain value type with no CoreGraphics calls of its own so
/// that the reconciliation logic in `DisplayReducer` can be exercised in tests
/// without any hardware attached.
public struct SystemDisplay: Equatable, Sendable {
    public var displayID: CGDirectDisplayID
    /// Stable across reboots and distinct even for two identical monitors.
    public var uuid: String?
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var unitNumber: UInt32
    /// `NSScreen.localizedName`, e.g. "Studio Display", "H27T27 (2)".
    public var localizedName: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshHz: Double
    public var isBuiltIn: Bool
    public var isMain: Bool
    /// True when this display is showing a copy of another display rather than its own desktop.
    public var mirrorsDisplay: CGDirectDisplayID
    /// Left edge in the global coordinate space; used to order cells the way the desks are arranged.
    public var originX: Double
    /// Top edge in the global coordinate space; needed to translate the whole arrangement
    /// when reassigning the main display.
    public var originY: Double

    public init(
        displayID: CGDirectDisplayID,
        uuid: String? = nil,
        vendor: UInt32 = 0,
        model: UInt32 = 0,
        serial: UInt32 = 0,
        unitNumber: UInt32 = 0,
        localizedName: String? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        refreshHz: Double = 0,
        isBuiltIn: Bool = false,
        isMain: Bool = false,
        mirrorsDisplay: CGDirectDisplayID = 0,
        originX: Double = 0,
        originY: Double = 0
    ) {
        self.displayID = displayID
        self.uuid = uuid
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.unitNumber = unitNumber
        self.localizedName = localizedName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshHz = refreshHz
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
        self.mirrorsDisplay = mirrorsDisplay
        self.originX = originX
        self.originY = originY
    }

    /// Identity that survives unplug/replug, reboot, and `CGDirectDisplayID` reassignment.
    ///
    /// The UUID is preferred; the vendor/model/serial/unit tuple is a fallback for the
    /// rare display that does not produce one.
    public var key: String {
        if let uuid, !uuid.isEmpty { return uuid }
        return "vms:\(vendor)-\(model)-\(serial)-\(unitNumber)"
    }

    /// A display is "on" when it is drawing its own desktop — not mirroring another display.
    public var isOn: Bool { mirrorsDisplay == 0 }
}
