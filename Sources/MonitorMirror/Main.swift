import AppKit
import MonitorMirrorCore

@main
enum MonitorMirrorMain {

    @MainActor
    static func main() {
        // `--diagnose` prints everything the app can see about the attached displays and
        // exits. Lets someone file a useful bug report without running the menu bar app.
        if CommandLine.arguments.contains("--diagnose") {
            let manager = DisplayManager(store: InMemoryDisplayStore())
            print(manager.diagnosticsReport())
            exit(0)
        }

        // Design QA: renders the popover offscreen to a PNG and exits.
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
           index + 1 < CommandLine.arguments.count {
            // A GUI connection is needed even offscreen, but no window is ever shown.
            _ = NSApplication.shared
            exit(PreviewRenderer.render(to: CommandLine.arguments[index + 1]) ? 0 : 1)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only: no Dock icon, no application menu.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
