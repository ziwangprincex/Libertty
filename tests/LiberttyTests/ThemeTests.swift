import Foundation
import Testing
@testable import LiberttyApp

/// Theme files and their new colors, Rex's themes read from its app, the
/// `theme` setting, and the Theme Customizer's palette.
struct ThemeTests {
    static let rexFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/rex-themes.json")

    @Test @MainActor func themeFileRoundTripsEveryColor() {
        var t = Theme.named("Nord")
        t.name = "Probe"
        t.cursorText = RGB(1, 2, 3)
        t.selectionForeground = RGB(0xfe, 0xfe, 0xfe)
        t.paletteGenerate = true
        t.paletteHarmonious = true
        t.extendedPalette = [16: RGB(10, 20, 30), 255: RGB(250, 250, 250)]
        let text = ThemeEditor.text(of: t)
        #expect(text.contains("cursor-text = #010203"))
        #expect(text.contains("selection-foreground = #fefefe"))
        #expect(text.contains("palette-generate = true"))
        #expect(Theme.parse(name: "Probe", text: text) == t)
    }

    @Test @MainActor func unsetColorsStayUnset() {
        var t = Theme.named("Nord")
        t.name = "Probe"
        let text = ThemeEditor.text(of: t)
        #expect(!text.contains("cursor-text") && !text.contains("selection-foreground") && !text.contains("palette-generate"))
        let back = Theme.parse(name: "Probe", text: text)
        #expect(back.cursorText == nil && back.selectionForeground == nil && !back.paletteGenerate)
    }

    @Test func ghosttyThemeKeys() {
        let t = Theme.parse(name: "Probe", text: """
            background = #101010
            cursor-text = #202020
            selection-foreground = #e0e0e0
            palette = 3=#333333
            palette = 100=#646464
            palette = 300=#ffffff
            palette-generate = true
            """)
        #expect(t.cursorText == RGB(0x20, 0x20, 0x20))
        #expect(t.selectionForeground == RGB(0xe0, 0xe0, 0xe0))
        #expect(t.ansi[3] == RGB(0x33, 0x33, 0x33))
        #expect(t.extendedPalette == [100: RGB(100, 100, 100)])
        #expect(t.paletteGenerate && !t.paletteHarmonious)
        // Its own entries over the generated ones.
        #expect(t.fullPalette[100] == RGB(100, 100, 100))
        #expect(t.fullPalette[16] == t.background)
    }

    @Test func configCoversTheThemesColors() {
        var c = Config()
        #expect(c.set("cursor-text", "#0a0b0c") == nil)
        #expect(c.set("selection-foreground", "#fafbfc") == nil)
        #expect(c.set("palette", "200=#123456") == nil)
        let t = c.resolvedTheme(dark: true)
        #expect(t.cursorText == RGB(0x0a, 0x0b, 0x0c))
        #expect(t.selectionForeground == RGB(0xfa, 0xfb, 0xfc))
        #expect(t.fullPalette[200] == RGB(0x12, 0x34, 0x56))
        #expect(c.set("cursor-text", "nope") != nil)
    }

    @Test func paletteGenerateFollowsTheThemeUnlessTheConfigSays() throws {
        let library = ThemeLibrary()
        library.rexThemesFile = Self.rexFixture
        var theme = try #require(library.load("Probe Dusk"))
        #expect(theme.paletteGenerate)
        var c = Config()
        #expect(c.paletteGenerate == nil)
        // (resolvedTheme's own steps, on this library's theme.)
        if let generate = c.paletteGenerate { theme.paletteGenerate = generate }
        #expect(theme.paletteGenerate)
        _ = c.set("palette-generate", "false")
        if let generate = c.paletteGenerate { theme.paletteGenerate = generate }
        #expect(!theme.paletteGenerate)
        #expect(theme.fullPalette == theme.palette256)
    }

    @Test func rexThemesFromItsFile() throws {
        let themes = RexThemes.parse(try Data(contentsOf: Self.rexFixture))
        // The broken one (15 colors short) and the one that's no theme are left out.
        #expect(themes.map(\.name) == ["Probe Dusk", "Probe Noon"])
        let dusk = themes[0]
        #expect(dusk.background == RGB(0x10, 0x14, 0x18))
        #expect(dusk.cursor == RGB(0x40, 0xe0, 0xc0))
        #expect(dusk.cursorText == RGB(0x10, 0x14, 0x18))
        #expect(dusk.selection == RGB(0x20, 0x30, 0x40))
        #expect(dusk.selectionForeground == RGB(0xf0, 0xf4, 0xf8))
        #expect(dusk.ansi.count == 16 && dusk.ansi[15] == RGB(0xf0, 0xf4, 0xf8))
        #expect(dusk.paletteGenerate && !dusk.paletteHarmonious)
        // Without a cursor of its own: the text's color; no selected text color: unset.
        let noon = themes[1]
        #expect(noon.cursor == noon.foreground)
        #expect(noon.selectionForeground == nil)
        #expect(noon.paletteHarmonious && !noon.isDark)
    }

    @Test func rexThemesAreLookedUpByName() throws {
        let library = ThemeLibrary()
        library.rexThemesFile = Self.rexFixture
        let entry = try #require(library.entry(for: "probe dusk"))
        #expect(entry.source == "Rex" && !entry.isOwn)
        #expect(entry.url == Self.rexFixture)
        #expect(library.load("Probe Noon")?.background == RGB(0xf8, 0xf4, 0xee))
        #expect(library.url(for: "Probe Broken") == nil)
        library.rexThemesFile = .some(nil)
        library.invalidate()
        #expect(library.entry(for: "Probe Dusk") == nil)
    }

    @Test func yourThemesWinOverRexs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rex-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "background = #ababab\n".write(to: folder.appendingPathComponent("Probe Dusk"), atomically: true, encoding: .utf8)
        final class Library: ThemeLibrary {
            var folder: URL!
            override var directories: [(URL, String)] { [(folder, "user")] }
        }
        let library = Library()
        library.folder = folder
        library.rexThemesFile = Self.rexFixture
        #expect(library.entry(for: "Probe Dusk")?.source == "user")
        #expect(library.load("Probe Dusk")?.background == RGB(0xab, 0xab, 0xab))
        #expect(library.entry(for: "Probe Noon")?.source == "Rex")
    }

    @Test func themeSettingWithOneHalf() {
        #expect(ThemeSpec("dark:Merino Dark") == ThemeSpec(light: "Libertty Light", dark: "Merino Dark"))
        #expect(ThemeSpec("light:Nord") == ThemeSpec(light: "Nord", dark: Theme.defaultName))
        #expect(ThemeSpec("light:Nord,dark:Dracula") == ThemeSpec(light: "Nord", dark: "Dracula"))
        #expect(ThemeSpec("Nord,Dracula") == nil)
    }

    @Test @MainActor func duplicatedNames() {
        #expect(ThemeCustomizerModel.freeName(from: "Probe Nowhere") == "Probe Nowhere (Duplicated)")
        #expect(ThemeCustomizerModel.freeName(from: "Probe Nowhere (Duplicated)") == "Probe Nowhere (Duplicated)")
        #expect(ThemeCustomizerModel.freeName(from: "Nord") == "Nord (Duplicated)")
    }

    @Test @MainActor func extendedPaletteKeepsItsColorsWhenNotRegenerating() {
        let model = ThemeCustomizerModel()
        var t = Theme.named(Theme.defaultName)
        t.paletteGenerate = true
        model.load(t, from: Theme.defaultName)
        #expect(model.autoRegenerate)
        let before = model.palette[16]
        model.setAutoRegenerate(false)
        #expect(model.theme.extendedPalette.count == 240)
        model.set(.background, RGB(0x40, 0, 0))
        #expect(model.palette[16] == before)
        model.regenerate()
        #expect(model.palette[16] == RGB(0x40, 0, 0))
        // On again: generated as the colors change.
        model.setAutoRegenerate(true)
        model.set(.background, RGB(0, 0x40, 0))
        #expect(model.palette[16] == RGB(0, 0x40, 0))
        // One chosen by hand is an override, until reset.
        model.set(.indexed(20), RGB(1, 1, 1))
        #expect(model.overrides == 1 && model.palette[20] == RGB(1, 1, 1))
        model.resetOverrides()
        #expect(model.overrides == 0)
        // Off: xterm's colors.
        model.generate = false
        #expect(model.palette == model.theme.palette256)
    }

    @Test @MainActor func pickerKeepsWhatWasDragged() {
        let model = ThemeCustomizerModel()
        model.load(Theme.named(Theme.defaultName), from: Theme.defaultName)
        model.beginPicking(.background)
        // Out of sRGB: the swatch gets the nearest color, the picker keeps the chroma asked for.
        model.setPicked(OKLCH(l: 0.7, c: 0.37, h: 150))
        #expect(model.picked.c == 0.37)
        #expect(model.theme.background == OKLCH(l: 0.7, c: 0.37, h: 150).rgb)
        model.setPicked(OKLCH(l: 0.2, c: 0.02, h: 250))
        #expect(model.theme.background == RGB(0x0f, 0x17, 0x1f))
        #expect(model.previewSettings().contains { $0.key == "background" && $0.value == "#0f171f" })
    }
}
