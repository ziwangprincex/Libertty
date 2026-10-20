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
    /// A pane on the window's frame (Tern's: measured from its shots).
    static let pane: CGFloat = 10
    static let control: CGFloat = 8
    static let chip: CGFloat = 6
}

enum Layout {
    /// Between the window's edges and the panes' column, and around each
    /// pane inside it: cards 6 apart, 6 from the edges (3 below the toolbar).
    static let stageInset: CGFloat = 3
    static let paneInset: CGFloat = 3
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
}

enum Timing {
    /// Delay before telling the pty about a size change during live resize
    /// (Otty `liveResizeSigwinchDelayMs`): the grid reflows and redraws every
    /// frame, but the shell only redraws once the drag settles.
    static let ptyResizeDebounce: TimeInterval = 0.05
}
