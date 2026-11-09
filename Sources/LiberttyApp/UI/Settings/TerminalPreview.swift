import AppKit
import LiberttyCore
import Metal

/// Settings' typography preview: a few lines as a pane draws them — by the
/// terminal's own renderer, with the config's font and its fallbacks, size,
/// line height, cell width, thickening, ligatures, theme and contrast — in a
/// terminal as wide as the preview, so a line too long for it wraps as it
/// would in a pane that wide.
@MainActor
final class TerminalPreview {
    static let shared = TerminalPreview()

    /// What it shows: a prompt, a warning, a bold and an italic, as a build prints them.
    static let sample = "\u{1b}[?25l\u{1b}[34m~/libertty\u{1b}[35m main\u{1b}[0m $ swift build && swift test\r\n"
        + "\u{1b}[1;33mwarning:\u{1b}[0m 'run() -> Bool' is deprecated\r\n"
        + "\u{1b}[1;32mBuild complete!\u{1b}[0m \u{1b}[3m(1.24 sec)\u{1b}[0m"
    /// The sample's lines as they show, for how many rows they take.
    static let lines = ["~/libertty main $ swift build && swift test", "warning: 'run() -> Bool' is deprecated",
                        "Build complete! (1.24 sec)"]
    /// Round the text, in points.
    static let padding = CGSize(width: 12, height: 10)

    private let device = MTLCreateSystemDefaultDevice()
    private var renderer: TerminalRenderer?
    /// The last one drawn and what for: Settings asks again on every change of anything.
    private var last: (config: Config, theme: Theme, width: CGFloat, scale: CGFloat, image: CGImage?)?

    /// The preview for `config`, `width` points wide, at `scale` pixels a point.
    func image(config: Config, width: CGFloat, scale: CGFloat) -> CGImage? {
        let theme = config.resolvedTheme
        if let last, last.config == config, last.theme == theme, last.width == width, last.scale == scale { return last.image }
        let image = render(config: config, width: width, scale: scale)
        last = (config, theme, width, scale, image)
        return image
    }

    /// How many columns fit across `width` pixels, and how many rows the
    /// sample takes in them.
    static func grid(width: CGFloat, cellWidth: Int) -> (cols: Int, rows: Int) {
        let cols = max(8, Int(width) / max(cellWidth, 1))
        return (cols, lines.reduce(0) { $0 + max(1, ($1.count + cols - 1) / cols) })
    }

    private func render(config: Config, width: CGFloat, scale: CGFloat) -> CGImage? {
        guard let device, width > 0 else { return nil }
        let fonts = FontSet(family: config.fontFamily, fallbacks: config.fontFallbacks, styles: config.fontStyles,
                            pointSize: CGFloat(config.fontSize),
                            scale: scale, cellHeightAdjust: config.adjustCellHeight, cellWidthAdjust: config.adjustCellWidth,
                            thicken: config.fontThicken ? CGFloat(config.fontThickenStrength) / 255 : 0)
        let renderer: TerminalRenderer
        if let existing = self.renderer {
            existing.setFonts(fonts)
            renderer = existing
        } else {
            guard let made = try? TerminalRenderer(device: device, fonts: fonts) else { return nil }
            self.renderer = made
            renderer = made
        }
        renderer.take(config)
        // On the Settings card: opaque, whatever the panes' opacity; no cursor to trail.
        renderer.backgroundOpacity = 1
        renderer.cursorTrail = false
        let padX = Self.padding.width * scale, padY = Self.padding.height * scale
        let (cols, rows) = Self.grid(width: width * scale - 2 * padX, cellWidth: fonts.cellWidth)
        let size = GridSize(cols: UInt16(cols), rows: UInt16(rows),
                            widthPx: UInt16(clamping: cols * fonts.cellWidth), heightPx: UInt16(clamping: rows * fonts.cellHeight))
        guard let session = try? TerminalSession(size: size, config: config) else { return nil }
        session.setCellSize(widthPx: UInt32(fonts.cellWidth), heightPx: UInt32(fonts.cellHeight))
        session.show(Self.sample)
        renderer.origin = SIMD2(Float(padX), Float(padY))
        renderer.pixelOffset = 0
        return renderer.snapshotImage(session, width: Int((width * scale).rounded()),
                                      height: Int((CGFloat(rows * fonts.cellHeight) + 2 * padY).rounded(.up)))
    }
}
