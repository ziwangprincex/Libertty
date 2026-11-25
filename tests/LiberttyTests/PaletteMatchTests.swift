import AppKit
import Testing
@testable import LiberttyApp

/// What the command palette finds for what's typed: a row that flips a
/// setting at once only for words that begin its own, never for letters
/// scattered through it.
struct PaletteMatchTests {
    @Test func settingSwitchesNeedTheirOwnWords() {
        let text = "Turn Off Show the sidebar in new windows window-sidebar Sidebar"
        // Scattered letters ("forward" runs through it) don't count.
        #expect(CommandPalette.score("forward", text) != nil)
        #expect(!CommandPalette.wordsBegin("forward", text))
        // Words that begin its own do, in any order, and its config key's parts too.
        #expect(CommandPalette.wordsBegin("side", text))
        #expect(CommandPalette.wordsBegin("new win", text))
        #expect(CommandPalette.wordsBegin("window sid", text))
        #expect(!CommandPalette.wordsBegin("sidebar tabs", text))
    }

    /// Chinese has no spaces between words: a word of it is found anywhere
    /// in the title, and scattered characters still aren't.
    @Test func chineseWordsAreFoundInside() {
        let text = "关闭 新窗口显示侧栏 window-sidebar"
        #expect(CommandPalette.wordsBegin("侧栏", text))
        #expect(CommandPalette.wordsBegin("关闭 窗口", text))
        #expect(CommandPalette.wordsBegin("侧栏 side", text))
        #expect(!CommandPalette.wordsBegin("窗栏", text))
        #expect(!CommandPalette.wordsBegin("剪贴板", text))
    }

    /// A key cap takes its colors in its own light or dark (the palette's
    /// is the theme's), not in the one AppKit has current.
    @Test @MainActor func keyCapsFollowTheirOwnAppearance() throws {
        let cap = KeyCap("esc")
        for (name, light) in [(NSAppearance.Name.darkAqua, false), (.aqua, true)] {
            cap.appearance = NSAppearance(named: name)
            NSAppearance(named: light ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                cap.viewDidChangeEffectiveAppearance()
            }
            let color = try #require(cap.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
            #expect((color.redComponent < 0.5) == light, "\(name.rawValue): \(color)")
        }
    }
}
