import AppKit

/// The interface's colors, made from a theme as Rex makes its own: each a
/// fixed step of OKLCH lightness from the terminal's background (the text
/// colors from its foreground), fitted to Rex's 41 themes (within 0.007 on
/// average, where 0.02 starts to show). The frame and sidebar are `canvas`;
/// cards, rows and controls sit on it.
struct Surfaces: Equatable {
    /// The window: frame, sidebar, the gaps around the panes.
    var canvas: RGB
    /// A raised row or card: the selected tab, a popover.
    var raised: RGB
    /// Hairlines: between compact panes, around cards.
    var stroke: RGB
    var strokeStrong: RGB
    var content: RGB
    var contentSecondary: RGB
    var contentTertiary: RGB
    var isDark: Bool

    init(_ theme: Theme) {
        let t = OKLCH(theme.background), f = OKLCH(theme.foreground)
        let dark = theme.isDark
        isDark = dark
        func from(_ dl: Double, chroma: Double) -> RGB { OKLCH(l: t.l + dl, c: t.c * chroma, h: t.h).rgb }
        func text(_ dl: Double, chroma: Double) -> RGB { OKLCH(l: t.l + dl, c: f.c * chroma, h: f.h).rgb }
        if dark {
            canvas = from(-0.0175, chroma: 1.04)
            raised = from(0.052, chroma: 0.96)
            stroke = from(0.1185, chroma: 1.23)
            strokeStrong = from(0.1945, chroma: 1.34)
            contentSecondary = text(0.4265, chroma: 0.80)
            contentTertiary = text(0.3275, chroma: 0.75)
        } else {
            canvas = from(-0.036, chroma: 1.16)
            raised = from(0.0043, chroma: 0.79)
            stroke = from(-0.0513, chroma: 1.39)
            strokeStrong = from(-0.1193, chroma: 1.53)
            contentSecondary = text(-0.4503, chroma: 0.80)
            contentTertiary = text(-0.3523, chroma: 0.72)
        }
        content = theme.foreground
    }

    /// The foreground over the canvas at Rex's strengths: a row under the
    /// pointer, a control's fill, a selected row.
    var hover: NSColor { content.nsColor.withAlphaComponent(isDark ? 0.042 : 0.046) }
    var control: NSColor { content.nsColor.withAlphaComponent(0.02) }
    var selected: NSColor { content.nsColor.withAlphaComponent(isDark ? 0.075 : 0.089) }
}

extension Theme {
    var surfaces: Surfaces { Surfaces(self) }
}
