import AppKit
import QuartzCore

/// Design tokens shared by every animated or styled surface, so motion and
/// shape stay consistent and Reduce Motion turns everything off in one place.
/// Values follow Tern's CSS tokens and Otty's settings UI.
enum Motion {
    /// Color and opacity changes (Tern `--ease`).
    static let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
    /// Movement: fast start, long settle (Tern `--out`, expo-out-like).
    static let out = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

    static let hover: CFTimeInterval = 0.15
    static let small: CFTimeInterval = 0.20
    static let pop: CFTimeInterval = 0.22
    static let card: CFTimeInterval = 0.32
    static let panel: CFTimeInterval = 0.45

    static var reduced: Bool { forceReduced || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// No animations at all (`--ui-probe`): a script must not depend on
    /// Core Animation getting frames, which stops while the display sleeps.
    static var forceReduced = false

    /// Duration to use for an animation, or zero when the user asked for less motion.
    static func duration(_ value: CFTimeInterval) -> CFTimeInterval { reduced ? 0 : value }
}

/// The interface's accent: the system's (default), or with `accent-color`
/// the theme's own or a color of your choosing (Rex's Use theme accent) —
/// the focused pane's line, selections in the sidebar and palette, rings.
enum Accent {
    static var custom: RGB?
    static var color: NSColor { custom?.nsColor ?? .controlAccentColor }

    /// `accent-color = theme`: the theme's cursor when it's a color of its
    /// own (not a gray) and stands out from the background, else its blue.
    static func of(_ theme: Theme) -> RGB {
        let c = theme.cursor
        let (r, g, b) = (Double(c.r), Double(c.g), Double(c.b))
        let chroma = max(r, g, b) - min(r, g, b)
        return chroma > 60 && c.contrast(with: theme.background) >= 2.5 ? c : theme.ansi[4]
    }
}

/// `--ui-probe` drives a window that's off screen and never in front:
/// nothing may bring Libertty forward then — not a palette, not a panel —
/// or keystrokes meant for whatever the user is doing would land here.
enum Probe {
    static var running = false

    /// Bring Libertty forward, unless a probe runs.
    static func activateApp() {
        guard !running else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum Radius {
    static let panel: CGFloat = 16
    static let card: CGFloat = 12
    /// A pane on the window's frame (Tern's: measured from its shots);
    /// square when compact (`pane-style`).
    static var pane: CGFloat { Layout.compact ? 0 : floating }
    /// A pane floating as a card or a picture in picture: rounded always.
    static let floating: CGFloat = 10
    static let control: CGFloat = 8
    static let chip: CGFloat = 6
}

enum Layout {
    /// `pane-style = compact` (Rex's Compact Pane Style): the panes meet
    /// with a hairline of the frame between them, square, out to the
    /// window's edges — every point for text. Comfortable (default): cards.
    static var compact = false
    /// Between the window's edges and the panes' column, and around each
    /// pane inside it: cards 6 apart, 6 from the edges (3 below the toolbar).
    static var stageInset: CGFloat { compact ? 0 : 3 }
    static var paneInset: CGFloat { compact ? 0.5 : 3 }
    /// Gap between pane cards.
    static var paneGap: CGFloat { paneInset * 2 }
    /// A sidebar row (tabs).
    static let rowHeight: CGFloat = 30
}

/// The interface's type: Geist (bundled, OFL), as Tern sets it, else the
/// system face. Sizes are Tern's: rows 13.5, headers and secondary 12.5,
/// key hints in the monospaced face at 11.5.
enum Typeface {
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        FontRegistry.registerBundledFonts()
        let name = switch weight {
        case .medium: "Geist-Medium"
        case .semibold, .bold, .heavy, .black: "Geist-SemiBold"
        default: "Geist-Regular"
        }
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    static let row = ui(13.5)
    static let header = ui(12.5, .medium)
    static let secondary = ui(12.5)
    static let hint = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
}

struct RGB: Equatable {
    var r: UInt8, g: UInt8, b: UInt8
    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { (self.r, self.g, self.b) = (r, g, b) }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// Packed little-endian RGBA as the shaders read it (`unpack_unorm4x8_to_float`).
    func packed(alpha: UInt8 = 255) -> UInt32 {
        UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(alpha) << 24
    }

    /// sRGB → linear, per channel value.
    private static let linear: [Double] = (0..<256).map { i in
        let c = Double(i) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Relative luminance (WCAG 2.0), 0 for black to 1 for white.
    var luminance: Double {
        0.2126 * Self.linear[Int(r)] + 0.7152 * Self.linear[Int(g)] + 0.0722 * Self.linear[Int(b)]
    }

    /// WCAG 2.0 contrast ratio, 1 (the same) to 21 (black on white).
    func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Ghostty's `minimum-contrast`: this color as text on `background`, or
    /// white or black (whichever reads better) when it's below `minimum`.
    func readable(on background: RGB, minimum: Double) -> RGB {
        guard minimum > 1, contrast(with: background) < minimum else { return self }
        let l = background.luminance
        return 1.05 / (l + 0.05) > (l + 0.05) / 0.05 ? RGB(255, 255, 255) : RGB(0, 0, 0)
    }
}

enum Timing {
    /// Delay before telling the pty about a size change during live resize
    /// (Otty `liveResizeSigwinchDelayMs`): the grid reflows and redraws every
    /// frame, but the shell only redraws once the drag settles.
    static let ptyResizeDebounce: TimeInterval = 0.05
}
