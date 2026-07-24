import AppKit

/// Draws the menu bar glyph: a monitor frame whose inner area is split into one segment
/// per display, in popover order — a lit segment (solid) for each display that is on, a
/// faint one for each that is off. The whole thing is a **template image**, so macOS tints
/// it to match the menu bar (light or dark) and the on/off contrast is carried purely by
/// opacity. Geometry is from ICON-CHANGE.md.
enum MenuBarIcon {

    // Frame 17×11 with a 1.5pt stroke drawn inside; stand 7×1.5 sits 2pt below it.
    private static let frameWidth: CGFloat = 17
    private static let frameHeight: CGFloat = 11
    private static let stroke: CGFloat = 1.5
    private static let standWidth: CGFloat = 7
    private static let standHeight: CGFloat = 1.5
    private static let standGap: CGFloat = 2
    // Inset from the frame edge. The stroke itself takes the outer 1.5pt, so this must be
    // comfortably larger than that or the segments crowd the border.
    private static let inset: CGFloat = 3.25
    private static let segmentGap: CGFloat = 1.5
    private static let offOpacity: CGFloat = 0.22

    static let size = NSSize(width: frameWidth, height: frameHeight + standGap + standHeight)

    /// - Parameter states: one entry per display, in popover order; `true` = on.
    static func image(states: [Bool]) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            // Template images are masks: only alpha matters, so everything is drawn in
            // black and the system supplies the colour. On/off contrast is the alpha.
            let ink = NSColor.black

            // Frame occupies the top; stand sits at the very bottom.
            let frameRect = NSRect(x: 0, y: standHeight + standGap, width: frameWidth, height: frameHeight)

            // Segments, inset inside the frame, one per display.
            let inner = frameRect.insetBy(dx: inset, dy: inset)
            if !states.isEmpty {
                let count = CGFloat(states.count)
                let totalGap = segmentGap * (count - 1)
                let segWidth = max(1, (inner.width - totalGap) / count)
                for (index, on) in states.enumerated() {
                    let x = inner.minX + CGFloat(index) * (segWidth + segmentGap)
                    ink.withAlphaComponent(on ? 1 : offOpacity).setFill()
                    NSBezierPath(
                        roundedRect: NSRect(x: x, y: inner.minY, width: segWidth, height: inner.height),
                        xRadius: 1,
                        yRadius: 1
                    ).fill()
                }
            }

            // Frame stroke, drawn inside the 17×11 box (inset by half the line width).
            ink.setStroke()
            let outline = NSBezierPath(
                roundedRect: frameRect.insetBy(dx: stroke / 2, dy: stroke / 2),
                xRadius: 3,
                yRadius: 3
            )
            outline.lineWidth = stroke
            outline.stroke()

            // Stand.
            ink.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: (frameWidth - standWidth) / 2, y: 0, width: standWidth, height: standHeight),
                xRadius: 1,
                yRadius: 1
            ).fill()

            return true
        }
        // Template: macOS recolours the whole glyph for the menu bar appearance and draws
        // the standard highlight when the popover is open. Opacity survives as coverage.
        image.isTemplate = true
        let onCount = states.filter { $0 }.count
        image.accessibilityDescription = states.isEmpty
            ? "No displays"
            : "\(onCount) of \(states.count) displays on"
        return image
    }
}
