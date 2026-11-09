import CoreText
import Foundation
import Testing
@testable import LiberttyApp

/// font-family repeats as in Ghostty: the font, then fallbacks; an empty one
/// starts over. Choosing a font (Settings, the palette) keeps the fallbacks.
struct FontConfigTests {
    @Test func fallbacks() {
        var c = Config()
        _ = c.set("font-family", "Iosevka")
        _ = c.set("font-family", "PingFang SC")
        _ = c.set("font-family", "Apple Color Emoji")
        #expect(c.fontFamily == "Iosevka")
        #expect(c.fontFallbacks == ["PingFang SC", "Apple Color Emoji"])
        _ = c.set("font-family", "")
        #expect(c.fontFamilies.isEmpty)
        let (parsed, warnings) = Config.parse("font-family = A\nfont-family = B\nfont-family =\nfont-family = C\n")
        #expect(warnings.isEmpty)
        #expect(parsed.fontFamilies == ["C"])
    }

    @Test func choosingAFontKeepsTheFallbacks() {
        var c = Config()
        _ = c.set("font-family", "Iosevka")
        _ = c.set("font-family", "PingFang SC")
        c.setPrimaryFont("Menlo")
        #expect(c.fontFamilies == ["Menlo", "PingFang SC"])
        // The bundled font, with fallbacks to keep after it: by its name.
        c.setPrimaryFont("")
        #expect(c.fontFamilies == [FontRegistry.bundledFamily, "PingFang SC"])
        var lone = Config()
        _ = lone.set("font-family", "Iosevka")
        lone.setPrimaryFont("")
        #expect(lone.fontFamilies.isEmpty)
    }

    @Test func theFileKeepsItsFallbackLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("font-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config")
        try "# mine\nfont-family = Iosevka\nfont-family = PingFang SC\nfont-size = 14\n".write(to: file, atomically: true, encoding: .utf8)
        let store = ConfigStore(url: file, watch: false)
        store.set("font-family", "Menlo")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text == "# mine\nfont-family = Menlo\nfont-family = PingFang SC\nfont-size = 14\n")
    }

    @Test func thickenKeys() {
        var c = Config()
        #expect(c.set("font-thicken", "true") == nil)
        #expect(c.set("font-thicken-strength", "128") == nil)
        #expect(c.fontThicken && c.fontThickenStrength == 128)
        #expect(c.set("font-thicken-strength", "x") != nil)
    }
}

/// A fallback font takes the characters the font lacks, before the system's own.
struct FontFallbackTests {
    @Test func aFallbackTakesWhatTheFontLacks() {
        func family(for text: String, _ fonts: FontSet) -> String {
            let font = fonts.font([])
            let picked = CTFontCreateForString(font, text as CFString, CFRange(location: 0, length: (text as NSString).length))
            return CTFontCopyFamilyName(picked) as String
        }
        let with = FontSet(family: "Menlo", fallbacks: ["Hiragino Sans"], pointSize: 13, scale: 2)
        #expect(family(for: "中", with) == "Hiragino Sans")
        // The font's own characters stay its own.
        #expect(family(for: "M", with) == "Menlo")
        // Without it, the system's fallback (another font): the fallback is what chose it.
        #expect(family(for: "中", FontSet(family: "Menlo", pointSize: 13, scale: 2)) != "Hiragino Sans")
    }
}

@Suite struct WelcomeAndMigrationTests {
    @Test func keyTipsFollowTheKeymap() {
        let tips = WelcomeView.boundTips(Keybinds(entries: []))
        #expect(tips.contains { $0.label == "New Tab" && $0.keys == "⌘T" })
        // Unbound: not listed.
        let unbound = WelcomeView.boundTips(Keybinds(entries: ["cmd+t=unbind"]))
        #expect(!unbound.contains { $0.label == "New Tab" })
    }

    @Test func promptNamesTheSourcesAndTheFile() {
        let prompt = MigrationPrompt.text(from: [.tmux], config: "~/.config/libertty/config")
        #expect(prompt.contains("from tmux to Libertty"))
        #expect(prompt.contains("tmux.conf"))
        #expect(!prompt.contains("iterm2.plist"))
        #expect(prompt.contains("cp ~/.config/libertty/config ~/.config/libertty/config.before-migration"))
        #expect(prompt.contains("libertty +validate-config"))
        let all = MigrationPrompt.text(config: "x")
        #expect(all.contains("Ghostty, iTerm2, tmux"))
    }
}

@Suite struct MigrationQuotingTests {
    @Test func pathsWithSpacesAreQuoted() {
        #expect(MigrationPrompt.quoted("~/.config/libertty/config") == "~/.config/libertty/config")
        #expect(MigrationPrompt.quoted("~/My Config/libertty/config") == "~/'My Config/libertty/config'")
        #expect(MigrationPrompt.quoted("/tmp/it's") == "'/tmp/it'\\''s'")
        let prompt = MigrationPrompt.text(from: [.tmux], config: "~/My Config/libertty/config")
        #expect(prompt.contains("cp ~/'My Config/libertty/config' ~/'My Config/libertty/config.before-migration'"))
    }
}

@Suite @MainActor struct SettingsFontWriteTests {
    /// Settings checks a write by what the file says after it: choosing a
    /// font (with or without fallbacks after it) must match, not report
    /// "Couldn't change".
    @Test func choosingAFontMatchesWhatTheFileSays() throws {
        for start in ["font-family = Maple Mono NF\n", "font-family = Maple Mono NF\nfont-family = PingFang SC\n", ""] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("config")
            try start.write(to: file, atomically: true, encoding: .utf8)
            let store = ConfigStore(url: file, watch: false)
            for value in ["Menlo", "Maple Mono NF", ""] {
                let (want, problem) = SettingsModel.expected("font-family", value, in: store.savedConfig)
                #expect(problem == nil)
                store.set("font-family", value.isEmpty ? nil : value)
                #expect(store.savedConfig.values(of: "font-family") == want.values(of: "font-family"), "\(start) → \(value)")
            }
        }
    }
}

@Suite @MainActor struct TerminalPreviewTests {
    @Test func previewFollowsTheTypography() throws {
        let plain = try #require(TerminalPreview.shared.image(config: Config(), width: 460, scale: 2))
        var taller = Config()
        _ = taller.set("adjust-cell-height", "50%")
        let tall = try #require(TerminalPreview.shared.image(config: taller, width: 460, scale: 2))
        #expect(plain.width == 920)
        #expect(tall.height > plain.height)
        // Wider cells: fewer columns, the sample wraps onto more rows.
        #expect(TerminalPreview.grid(width: 900, cellWidth: 30).rows > TerminalPreview.grid(width: 900, cellWidth: 15).rows)
    }
}

@Suite struct FontStyleTests {
    func name(_ font: CTFont) -> String { CTFontCopyPostScriptName(font) as String }

    @Test func facesByStyleName() {
        let styles = FontSet.faces(of: "Menlo").map(\.style)
        #expect(styles == ["Regular", "Bold", "Italic", "Bold Italic"])
        let plain = FontSet(family: "Menlo", pointSize: 13, scale: 2)
        #expect(name(plain.font(.bold)) == "Menlo-Bold")
        // A face by its name; bold drawn as regular; a style the font hasn't: its own.
        let set = FontSet(family: "Menlo", styles: FontStyles(regular: "Bold", bold: "false", italic: "Nonesuch"), pointSize: 13, scale: 2)
        #expect(name(set.font(FontSet.Style())) == "Menlo-Bold")
        #expect(name(set.font(.bold)) == "Menlo-Bold")
        #expect(name(set.font(.italic)).contains("Italic"))
    }

    @Test func styleKeys() {
        var c = Config()
        #expect(c.set("font-style", "Medium") == nil && c.fontStyles.regular == "Medium")
        #expect(c.set("font-style", "false") != nil)
        #expect(c.set("font-style-bold", "FALSE") == nil && c.fontStyles.bold == "false")
        #expect(c.set("font-style-italic", "Light Italic") == nil && c.values(of: "font-style-italic") == ["Light Italic"])
        #expect(c.set("font-style-bold", "") == nil && c.fontStyles.bold.isEmpty)
    }
}
