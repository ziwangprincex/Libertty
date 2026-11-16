import AppKit
import Testing
@testable import LiberttyApp

/// The interface's quieter colors still read (WCAG 2.x): text 4.5:1, a
/// control's glyph 3:1, on what they're drawn over in Libertty's own light
/// and dark themes — and a suggestion 3.5:1 while it stays well short of
/// what's typed.
@Suite @MainActor struct InkContrastTests {
    /// `color` (with its alpha) over `ground`, as the window draws it.
    private func over(_ color: NSColor, in appearanceName: NSAppearance.Name, on ground: RGB) -> RGB {
        var resolved = NSColor.black
        NSAppearance(named: appearanceName)!.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? .black
        }
        let a = resolved.alphaComponent
        func mix(_ c: CGFloat, _ g: UInt8) -> UInt8 { UInt8((c * 255 * a + CGFloat(g) * (1 - a)).rounded()) }
        return RGB(mix(resolved.redComponent, ground.r), mix(resolved.greenComponent, ground.g), mix(resolved.blueComponent, ground.b))
    }

    private var themes: [(Theme, NSAppearance.Name)] {
        [(Theme.named("Libertty Light"), .aqua), (Theme.named("Libertty Dark"), .darkAqua)]
    }

    @Test func secondaryTextReadsOnTheSidebarAndTheComposer() {
        for (theme, appearance) in themes {
            let canvas = theme.surfaces.canvas
            let text = over(Ink.secondary, in: appearance, on: canvas)
            #expect(text.contrast(with: canvas) >= 4.5, "\(theme.name): \(text.contrast(with: canvas))")
            // A selected row: the theme's text over the canvas, at the selection's strength.
            let selected = over(theme.surfaces.selected, in: appearance, on: canvas)
            let onSelected = over(Ink.secondary, in: appearance, on: selected)
            #expect(onSelected.contrast(with: selected) >= 4.5, "\(theme.name) selected: \(onSelected.contrast(with: selected))")
            // The composer's ground: the window background (light #ececec, dark #323232 measured).
            let composer = appearance == .aqua ? RGB(0xec, 0xec, 0xec) : RGB(0x32, 0x32, 0x32)
            let hint = over(Ink.secondary, in: appearance, on: composer)
            #expect(hint.contrast(with: composer) >= 4.5, "\(theme.name) composer: \(hint.contrast(with: composer))")
        }
    }

    @Test func controlGlyphsReadOnTheSidebar() {
        for (theme, appearance) in themes {
            let canvas = theme.surfaces.canvas
            let glyph = over(Ink.control, in: appearance, on: canvas)
            #expect(glyph.contrast(with: canvas) >= 3, "\(theme.name): \(glyph.contrast(with: canvas))")
        }
    }

    @Test func suggestionReadsYetStaysDimmer() {
        let a = Double(TerminalRenderer.ghostAlpha) / 255
        for (theme, _) in themes {
            let bg = theme.background, fg = theme.foreground
            func mix(_ f: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(f) * a + Double(b) * (1 - a)).rounded()) }
            let ghost = RGB(mix(fg.r, bg.r), mix(fg.g, bg.g), mix(fg.b, bg.b))
            #expect(ghost.contrast(with: bg) >= 3.5, "\(theme.name): \(ghost.contrast(with: bg))")
            #expect(fg.contrast(with: bg) >= 2.5 * ghost.contrast(with: bg), "\(theme.name): typed \(fg.contrast(with: bg))")
        }
    }
}
