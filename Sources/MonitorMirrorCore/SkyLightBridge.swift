import CoreGraphics
import Foundation

/// Late-bound access to the one window-server call that can genuinely power a display
/// down: `SLSConfigureDisplayEnabled` (historically `CGSConfigureDisplayEnabled`).
///
/// There is no public API for this — `CGConfigureDisplayMirrorOfDisplay` is the closest
/// supported equivalent and only hides a display behind a mirror. So the symbol is
/// resolved with `dlsym` at runtime rather than linked: if a future macOS drops or
/// renames it, `isAvailable` goes false and `DisplayPowerController` quietly falls back
/// to mirroring instead of failing to launch.
public final class SkyLightBridge {

    public static let shared = SkyLightBridge()

    /// `CGError SLSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, boolean_t)`
    private typealias ConfigureDisplayEnabled =
        @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, UInt32) -> CGError

    private let configureDisplayEnabled: ConfigureDisplayEnabled?

    public var isAvailable: Bool { configureDisplayEnabled != nil }

    public init(frameworkPath: String = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight") {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            configureDisplayEnabled = nil
            return
        }
        // `SLS` is the current spelling; `CGS` is the historical alias. Both are still
        // exported on macOS 26, but try each so the bridge survives either being dropped.
        let symbol = dlsym(handle, "SLSConfigureDisplayEnabled")
            ?? dlsym(handle, "CGSConfigureDisplayEnabled")
        configureDisplayEnabled = symbol.map {
            unsafeBitCast($0, to: ConfigureDisplayEnabled.self)
        }
        // The handle is intentionally not closed: the function pointer outlives this call
        // and SkyLight is resident for the lifetime of any GUI process anyway.
    }

    /// Stages an enable/disable on an open display-configuration transaction.
    /// Returns `nil` when the symbol could not be resolved.
    public func setDisplayEnabled(_ enabled: Bool, display: CGDirectDisplayID, config: CGDisplayConfigRef?) -> CGError? {
        guard let configureDisplayEnabled else { return nil }
        return configureDisplayEnabled(config, display, enabled ? 1 : 0)
    }
}
