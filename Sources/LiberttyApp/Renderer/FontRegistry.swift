import CoreText
import Foundation

/// Fonts shipped with Libertty (JetBrains Mono with Nerd Font symbols, OFL-1.1,
/// from Ghostty's vendored set), registered for this process only so prompts
/// with Powerline/Nerd glyphs render without the user installing anything.
enum FontRegistry {
    static let bundledFamily = "JetBrainsMono Nerd Font"

    /// Once, from whichever thread gets here first (see FontWarmup).
    private static let registration: Void = {
        let fonts = fontFiles
        guard !fonts.isEmpty else { return }
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
    }()

    static func registerBundledFonts() { _ = registration }

    /// The app bundle's Resources/Fonts; unbundled (`swift build`: development,
    /// the tests), the same files where the checkout keeps them — not a copy
    /// a bundle made earlier, which a fresh checkout doesn't have yet.
    private static var fontFiles: [URL] {
        func fonts(in dir: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
        }
        if let resources = Bundle.main.resourceURL {
            let bundled = fonts(in: resources.appendingPathComponent("Fonts"))
            if !bundled.isEmpty { return bundled }
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let mono = root.appendingPathComponent("vendor/ghostty/src/font/res")
        let ui = root.appendingPathComponent("vendor/geist")
        return ["Regular", "Bold", "Italic", "BoldItalic"].map { mono.appendingPathComponent("JetBrainsMonoNerdFont-\($0).ttf") }
            + ["Regular", "Medium", "SemiBold"].map { ui.appendingPathComponent("Geist-\($0).ttf") }
    }
}
