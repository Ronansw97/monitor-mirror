import MonitorMirrorCore
import SwiftUI

/// The white card. Geometry, type sizes and tracking come straight from the handoff;
/// see `Theme` for the colour tokens.
struct PopoverView: View {

    @ObservedObject var manager: DisplayManager
    var onOpenDisplaySettings: () -> Void

    /// Fixed by the design. Everything inside is laid out against this width.
    static let cardWidth: CGFloat = 324

    private var columnCount: Int {
        min(max(manager.displays.count, 1), 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            grid.padding(.top, 22)
            if let error = manager.lastError {
                errorLine(error).padding(.top, 14)
            }
            footer.padding(.top, 20)
        }
        .padding(EdgeInsets(top: 22, leading: 22, bottom: 16, trailing: 22))
        .frame(width: Self.cardWidth)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .shadow(
            color: .black.opacity(0.14),
            radius: Theme.Shadow.ambientRadius,
            y: Theme.Shadow.ambientY
        )
        .shadow(
            color: .black.opacity(0.06),
            radius: Theme.Shadow.contactRadius,
            y: Theme.Shadow.contactY
        )
        .animation(Theme.Motion.state, value: manager.displays)
        .animation(Theme.Motion.hover, value: manager.lastError)
        // Room for the drawn shadow to bleed into. `PanelController` measures this whole
        // view and insets by the same margin to work out where the card actually is, so
        // the margin belongs here rather than at the call site.
        .padding(Theme.Shadow.margin)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("MONITOR MIRROR")
                .font(Theme.mono(11, .semibold))
                .tracking(em: 0.16, size: 11)
                .foregroundColor(Theme.ink)
            Spacer(minLength: 8)
            Text(countLabel)
                .font(Theme.mono(9))
                .tracking(em: 0.12, size: 9)
                .foregroundColor(Theme.secondaryText)
                .monospacedDigit()
        }
    }

    private var countLabel: String {
        manager.displays.isEmpty ? "—" : "\(manager.activeCount)/\(manager.totalCount)"
    }

    @ViewBuilder
    private var grid: some View {
        if manager.displays.isEmpty {
            Text("NO DISPLAYS DETECTED")
                .font(Theme.mono(8.5))
                .tracking(em: 0.12, size: 8.5)
                .foregroundColor(Theme.mutedText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columnCount),
                spacing: 14
            ) {
                ForEach(manager.displays) { display in
                    DisplayCell(
                        display: display,
                        isBusy: manager.busyKeys.contains(display.key),
                        action: { manager.toggle(display) },
                        setMain: { manager.setMain(display) }
                    )
                }
            }
        }
    }

    private func errorLine(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.mono(7.5))
            .tracking(em: 0.08, size: 7.5)
            .foregroundColor(Theme.accent)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
    }

    private var footer: some View {
        HStack {
            Text("MM–01")
                .font(Theme.mono(8))
                .tracking(em: 0.14, size: 8)
                .foregroundColor(Theme.faintText)
            Spacer(minLength: 8)
            DisplaySettingsLink(action: onOpenDisplaySettings)
        }
    }
}

/// One monitor: block, stand, name, spec. The whole cell is the hit target.
private struct DisplayCell: View {

    let display: ManagedDisplay
    let isBusy: Bool
    let action: () -> Void
    let setMain: () -> Void

    @State private var isHovering = false

    private var isOn: Bool { display.isOn }
    /// The main display always draws a desktop, but guard anyway so an odd state can't put a
    /// dock on a dark monitor.
    private var showsDockBadge: Bool { display.isMain && isOn }

    var body: some View {
        VStack(spacing: 9) {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: Theme.Radius.monitor, style: .continuous)
                    .fill(isOn ? Theme.accent : Theme.offScreenFill)
                    .frame(width: 68, height: 44)
                    .overlay {
                        // Top sheen, on only. Clipped so it does not square off the corners.
                        if isOn {
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.25), location: 0),
                                    .init(color: .white.opacity(0), location: 0.55),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.monitor, style: .continuous))
                        }
                    }
                    // Main-display indicator: a tiny dock at the bottom of the screen —
                    // exactly where the real Dock sits on the display that holds it.
                    .overlay(alignment: .bottom) {
                        if showsDockBadge { dockBadge.transition(.opacity) }
                    }

                RoundedRectangle(cornerRadius: Theme.Radius.stand, style: .continuous)
                    .fill(isOn ? Theme.accent : Theme.offStand)
                    .frame(width: 18, height: 2)
            }

            VStack(spacing: 4) {
                Text(display.name)
                    .font(Theme.mono(9, .semibold))
                    .tracking(em: 0.08, size: 9)
                    .foregroundColor(isOn ? Theme.ink : Theme.mutedText)
                Text(display.spec)
                    .font(Theme.mono(7.5))
                    .tracking(em: 0.08, size: 7.5)
                    .foregroundColor(Theme.mutedText)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.cell, style: .continuous)
                .fill(isHovering ? Theme.hoverFill : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.cell, style: .continuous))
        .opacity(isBusy ? 0.55 : 1)
        .onHover { isHovering = $0 && !isBusy }
        .pointingHandCursor(enabled: !isBusy)
        .onTapGesture(perform: action)
        // Right-click makes this the main display straight away — no menu.
        .overlay { if !isBusy { RightClickCatcher(action: setMain) } }
        .allowsHitTesting(!isBusy)
        .animation(Theme.Motion.state, value: isOn)
        .animation(Theme.Motion.state, value: display.isMain)
        .animation(Theme.Motion.hover, value: isHovering)
        .animation(Theme.Motion.hover, value: isBusy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(display.name), \(display.spec)")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isOn ? "Tap to turn off. Right-click to make it the main display." : "Tap to turn on.")
    }

    /// A tiny frosted dock, per DOCK-BADGE-CHANGE.md: three white squares in a pill,
    /// bottom-centre of the screen, shown only for the main display while it is on.
    private var dockBadge: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(.white)
                    .frame(width: 2.5, height: 2.5)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(.white.opacity(0.32))
        )
        .padding(.bottom, 3)
    }

    private var accessibilityValue: String {
        if display.isMain { return isOn ? "On, main display" : "Off" }
        return isOn ? "On" : "Off"
    }
}

/// Catches right-clicks (only) on the cell and fires `action`, leaving left-clicks and
/// hover to pass straight through to the SwiftUI view beneath. Used so a right-click sets
/// the main display immediately, with no intervening menu.
private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSView { CatcherView(action: action) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.action = action
    }

    final class CatcherView: NSView {
        var action: () -> Void
        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        // Claim the point only while a right-click is being routed; for every other event
        // (left click, hover) return nil so the SwiftUI content below handles it normally.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) { action() }
    }
}

private struct DisplaySettingsLink: View {

    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Text("DISPLAY SETTINGS ↗")
            .font(Theme.mono(8.5))
            .tracking(em: 0.12, size: 8.5)
            .foregroundColor(isHovering ? Theme.accent : Theme.secondaryText)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .pointingHandCursor()
            .onTapGesture(perform: action)
            .animation(Theme.Motion.hover, value: isHovering)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Display settings")
            .accessibilityAddTraits(.isButton)
    }
}
