import CoreText
import Foundation

/// Fonts shipped with Libertty (JetBrains Mono with Nerd Font symbols, OFL-1.1,
/// from Ghostty's vendored set), registered for this process only so prompts
/// with Powerline/Nerd glyphs render without the user installing anything.
enum FontRegistry {
    static let bundledFamily = "JetBrainsMono Nerd Font"

    private static var registered = false

    static func registerBundledFonts() {
        guard !registered else { return }
        registered = true
        let fonts = fontDirectories.lazy
            .compactMap { dir in try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) }
            .first { !$0.isEmpty }?
            .filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) } ?? []
        guard !fonts.isEmpty else { return }
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
    }

    /// The app bundle's Resources/Fonts, or the vendored copy when running
    /// unbundled from `swift build` (development and snapshot tests).
    private static var fontDirectories: [URL] {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL {
            dirs.append(resources.appendingPathComponent("Fonts"))
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        dirs.append(root.appendingPathComponent("build/fonts"))
        return dirs
    }
}
