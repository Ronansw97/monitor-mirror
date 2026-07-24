import AppKit
import Combine
import MonitorMirrorCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let manager = DisplayManager()
    private var statusItem: NSStatusItem!
    private var panel: PanelController<PopoverView>!

    private var cancellables: Set<AnyCancellable> = []
    /// The states last drawn, so the icon is only re-rendered when it actually changes.
    private var currentIconStates: [Bool]?

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.startObserving()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Monitor Mirror")
        button.toolTip = "Monitor Mirror"

        panel = PanelController(content: makePopover())
        panel.onVisibilityChange = { [weak self] visible in
            self?.statusItem.button?.highlight(visible)
        }

        // Redraw the glyph when the on/off tally changes, and keep the open panel sized
        // to its content as displays come and go.
        manager.$displays
            .combineLatest(manager.$busyKeys, manager.$lastError)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                guard let self else { return }
                self.updateIcon()
                self.panel.relayout()
            }
            .store(in: &cancellables)

        // The glyph is a template image, so macOS recolours it for the menu bar's
        // appearance automatically — no need to track light/dark ourselves.
        updateIcon()
    }

    private func makePopover() -> PopoverView {
        PopoverView(manager: manager) { [weak self] in
            self?.openDisplaySettings()
        }
    }

    // MARK: - Status item

    @objc private func statusItemClicked() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true

        if isRightClick {
            panel.close()
            showMenu()
            return
        }

        guard let button = statusItem.button, let window = button.window else { return }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        // Re-read before showing: a display may have changed while the panel was closed
        // and no reconfiguration callback reached us (for example during system sleep).
        manager.refresh()
        panel.toggle(anchoredTo: rect)
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        // One segment per display, in the popover's left-to-right order.
        let states = manager.displays.map(\.isOn)
        guard states != currentIconStates else { return }
        currentIconStates = states
        button.image = MenuBarIcon.image(states: states)
    }

    // MARK: - Menu

    private func showMenu() {
        let menu = NSMenu()

        let restore = NSMenuItem(
            title: "Turn All Displays On",
            action: #selector(restoreAllDisplays),
            keyEquivalent: ""
        )
        restore.target = self
        restore.isEnabled = manager.displays.contains { !$0.isOn }
        menu.addItem(restore)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        login.isEnabled = LoginItem.isSupported
        menu.addItem(login)

        let diagnostics = NSMenuItem(
            title: "Copy Diagnostics",
            action: #selector(copyDiagnostics),
            keyEquivalent: ""
        )
        diagnostics.target = self
        menu.addItem(diagnostics)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Monitor Mirror", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Attaching the menu makes the status item draw it in the right place with the
        // right highlight; detaching immediately after keeps left-click on our action.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func restoreAllDisplays() {
        manager.restoreAllDisplays()
    }

    @objc private func toggleOpenAtLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(manager.diagnosticsReport(), forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Display settings

    private func openDisplaySettings() {
        panel.close()
        let candidates = [
            // Ventura and later.
            "x-apple.systempreferences:com.apple.Displays-Settings.extension",
            // Monterey and earlier.
            "x-apple.systempreferences:com.apple.preference.displays",
        ]
        for string in candidates {
            guard let url = URL(string: string) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
        // Last resort, if the panes ever move again.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

/// Thin wrapper over `SMAppService`, which needs a signed bundle to work. Every call is
/// tolerant of failure so an unsigned or ad-hoc build still runs, just without the option.
enum LoginItem {

    static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Monitor Mirror: could not change login item state — \(error.localizedDescription)")
        }
    }
}
