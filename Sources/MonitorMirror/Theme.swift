import AppKit
import SwiftUI

/// Design tokens from the handoff. Literal sRGB values, not semantic colors: the popover
/// is a fixed white panel in both system appearances, so nothing here adapts.
enum Theme {
    static let accent = Color(hex: 0xFF4A00)
    static let ink = Color(hex: 0x1B1B1A)
    static let secondaryText = Color(hex: 0x8F8F8B)
    static let mutedText = Color(hex: 0x9A9A96)
    static let faintText = Color(hex: 0xAAAAA6)
    static let offScreenFill = Color(hex: 0xECECEA)
    static let offStand = Color(hex: 0xDCDCD8)
    static let hoverFill = Color(hex: 0xF7F7F5)
    static let panel = Color.white

    enum Radius {
        static let panel: CGFloat = 18
        static let cell: CGFloat = 10
        static let monitor: CGFloat = 6
        static let stand: CGFloat = 1
    }

    enum Motion {
        /// State changes on the monitor blocks and labels.
        static let state = Animation.easeInOut(duration: 0.25)
        /// Hover and link colour.
        static let hover = Animation.easeInOut(duration: 0.2)
    }

    /// Extra room the panel window leaves around the card so the drawn shadow is not clipped.
    enum Shadow {
        static let margin: CGFloat = 60
        static let ambientRadius: CGFloat = 30   // CSS blur 60 ≈ SwiftUI radius 30
        static let ambientY: CGFloat = 24
        static let contactRadius: CGFloat = 4    // CSS blur 8
        static let contactY: CGFloat = 2
    }

    /// SF Mono, the native substitute the handoff allows for IBM Plex Mono.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension View {
    /// CSS `letter-spacing` is em-relative; SwiftUI `tracking` is in points.
    func tracking(em: CGFloat, size: CGFloat) -> some View {
        tracking(em * size)
    }

    /// Shows the pointing-hand cursor while the pointer is inside this view.
    ///
    /// `NSCursor.push`/`pop` is balanced per enter/exit, and the cursor is popped when the
    /// view goes away so a panel dismissed mid-hover cannot strand the cursor.
    func pointingHandCursor(enabled: Bool = true) -> some View {
        modifier(PointingHandCursor(enabled: enabled))
    }
}

private struct PointingHandCursor: ViewModifier {
    let enabled: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                let shouldPush = inside && enabled
                guard shouldPush != pushed else { return }
                pushed = shouldPush
                if shouldPush { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                guard pushed else { return }
                pushed = false
                NSCursor.pop()
            }
    }
}
