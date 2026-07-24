import AppKit
import MonitorMirrorCore
import SwiftUI

/// Renders the popover offscreen to a PNG using sample data, for design QA against the
/// handoff without needing the app running or a screen recording permission.
///
/// Invoked with `MonitorMirror --render-preview <path.png>`.
@MainActor
enum PreviewRenderer {

    static func render(to path: String) -> Bool {
        let manager = DisplayManager(
            provider: SampleDisplayProvider(),
            controller: InertPowerController(),
            store: InMemoryDisplayStore()
        )

        let view = PopoverView(manager: manager, onOpenDisplaySettings: {})
            // The design's checkered desktop stands in for anything behind the card, so
            // the shadow is visible in the render.
            .background(Color(hex: 0xE3E3DF))

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }

        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            return false
        }
    }
}

/// The three displays from the design mock.
private final class SampleDisplayProvider: DisplaySnapshotProviding {
    func mainDisplayID() -> CGDirectDisplayID { 1 }
    func snapshot() -> [SystemDisplay] {
        [
            SystemDisplay(displayID: 1, uuid: "1", localizedName: "Studio Display",
                          pixelWidth: 5120, pixelHeight: 2880, refreshHz: 60,
                          isMain: true, originX: 0),
            SystemDisplay(displayID: 2, uuid: "2", localizedName: "DELL U2720Q",
                          pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60,
                          originX: 2560),
            SystemDisplay(displayID: 3, uuid: "3", localizedName: "LG UltraFine",
                          pixelWidth: 2560, pixelHeight: 1440, refreshHz: 144,
                          mirrorsDisplay: 1, originX: 5120),
        ]
    }
}

private final class InertPowerController: DisplayPowerControlling {
    let supportsHardOff = false
    func setOn(_ desiredOn: Bool, displayID: CGDirectDisplayID) throws -> DisplayControlStrategy { .mirror }
    func restore(displayIDs: [CGDirectDisplayID]) -> Set<CGDirectDisplayID> { [] }
    func setMain(displayID: CGDirectDisplayID) throws {}
}
