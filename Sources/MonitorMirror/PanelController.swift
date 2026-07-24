import AppKit
import SwiftUI

/// A borderless panel that behaves like a popover but leaves the drawing entirely to
/// SwiftUI, so the card can be the exact white/18pt/custom-shadow the design specifies
/// rather than `NSPopover`'s system chrome and arrow.
@MainActor
final class PanelController<Content: View> {

    private let panel: FloatingPanel
    private let container: PassthroughContainerView
    private let hostingView: NSHostingView<AnyView>

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?
    private var activeAppObserver: NSObjectProtocol?

    /// Guards against the status button reopening the panel on the same click that
    /// dismissed it: the mouse-down closes the panel, then the button action fires.
    private var lastCloseDate = Date.distantPast
    private static var reopenGrace: TimeInterval { 0.2 }

    var isVisible: Bool { panel.isVisible }

    init(content: Content) {
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 100, height: 100)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card's shadow is drawn in SwiftUI so it matches the spec exactly; the
        // window's own shadow would double it up.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        // The card is a fixed white surface in both system appearances.
        panel.appearance = NSAppearance(named: .aqua)

        hostingView = NSHostingView(rootView: AnyView(content))
        container = PassthroughContainerView()
        container.addSubview(hostingView)
        panel.contentView = container
    }

    /// Re-measures the SwiftUI content and resizes the panel around it. SwiftUI updates
    /// the card itself through its own observation; only the window frame needs this.
    func relayout() {
        guard panel.isVisible else { return }
        layout(anchoredTo: anchorRect)
    }

    // MARK: - Show / hide

    private var anchorRect: NSRect = .zero

    /// Toggles the panel, ignoring a request that arrives within the grace period after
    /// a dismissal so one click on the status item does not close-then-reopen.
    func toggle(anchoredTo rect: NSRect) {
        if panel.isVisible {
            close()
        } else {
            guard Date().timeIntervalSince(lastCloseDate) > Self.reopenGrace else { return }
            show(anchoredTo: rect)
        }
    }

    func show(anchoredTo rect: NSRect) {
        anchorRect = rect
        layout(anchoredTo: rect)
        panel.makeKeyAndOrderFront(nil)
        startMonitoring()
        onVisibilityChange?(true)
    }

    func close() {
        guard panel.isVisible else { return }
        stopMonitoring()
        panel.orderOut(nil)
        lastCloseDate = Date()
        onVisibilityChange?(false)
    }

    var onVisibilityChange: ((Bool) -> Void)?

    // MARK: - Geometry

    private func layout(anchoredTo rect: NSRect) {
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let size = NSSize(width: max(fitting.width, 1), height: max(fitting.height, 1))

        hostingView.frame = NSRect(origin: .zero, size: size)
        container.frame = NSRect(origin: .zero, size: size)
        // Only the card itself takes clicks; the transparent shadow margin around it
        // must let them through so clicking beside the panel dismisses it.
        container.interactiveRect = NSRect(origin: .zero, size: size)
            .insetBy(dx: Theme.Shadow.margin, dy: Theme.Shadow.margin)

        let margin = Theme.Shadow.margin
        let gap: CGFloat = 6                    // between the menu bar item and the card
        let screen = screenContaining(rect)
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let edgeInset: CGFloat = 8

        // Centre the card under the status item, then keep it on screen.
        var cardLeft = rect.midX - (size.width - 2 * margin) / 2
        let cardWidth = size.width - 2 * margin
        cardLeft = min(max(cardLeft, visible.minX + edgeInset), visible.maxX - cardWidth - edgeInset)

        var cardTop = rect.minY - gap
        // If there is somehow no room below (a status item near the bottom of a rotated
        // display, say), flip the card above the anchor instead of running off screen.
        if cardTop - (size.height - 2 * margin) < visible.minY + edgeInset {
            cardTop = min(rect.maxY + gap + (size.height - 2 * margin), visible.maxY - edgeInset)
        }

        let origin = NSPoint(x: cardLeft - margin, y: cardTop - (size.height - margin))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func screenContaining(_ rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
    }

    // MARK: - Dismissal

    private func startMonitoring() {
        stopMonitoring()

        // Clicks in any other application.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }

        // Clicks elsewhere in this application, plus Escape. Events belonging to the panel
        // or to the status item's own window are left alone — the status item has its own
        // toggle handling, and a right-click inside the panel sets the main display.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }   // Escape
                self.close()
                return nil
            }
            if let window = event.window, window === self.panel { return event }
            self.close()
            return event
        }

        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }

        // Another app coming to the front while our panel floats above it.
        activeAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func stopMonitoring() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        if let activeAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeAppObserver)
        }
        globalMonitor = nil
        localMonitor = nil
        resignKeyObserver = nil
        activeAppObserver = nil
    }
}

/// Borderless panels are not key-eligible by default, and the card needs key status to
/// receive Escape and to know when focus moves elsewhere.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Passes clicks in the transparent shadow margin through to whatever is behind the panel.
private final class PassthroughContainerView: NSView {
    var interactiveRect: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}
