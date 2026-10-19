import AppKit
import WebKit

/// The editor block's page (CodeMirror 6, MIT; frontend/editor/main.js bundled by
/// scripts/build-editor.sh): where it is, what language a file is, and the
/// terminal's theme in the colors the page draws with.
enum EditorAssets {
    /// The page's folder: the app bundle's Resources/editor, or the vendored
    /// copy when running from `swift build`.
    static var page: URL? {
        candidates.map { $0.appendingPathComponent("index.html") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// What the page may read: its own folder and the bundled fonts.
    static var readAccess: URL? {
        if let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("editor/index.html").path) {
            return resources
        }
        return root
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static var candidates: [URL] {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL { dirs.append(resources.appendingPathComponent("editor")) }
        dirs.append(root.appendingPathComponent("vendor/codemirror"))
        return dirs
    }

    /// The bundled terminal font, so the editor sets code as the terminal does
    /// (the page runs in another process, which doesn't see fonts this one registered).
    static var fontURL: URL? {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL { dirs.append(resources.appendingPathComponent("Fonts")) }
        dirs.append(root.appendingPathComponent("build/fonts"))
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            if let regular = files.sorted().first(where: { $0.hasPrefix("JetBrainsMonoNerdFont-Regular") }) {
                return dir.appendingPathComponent(regular)
            }
        }
        return nil
    }

    /// The page's name for a file's language (nil: plain text).
    static func language(for url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        switch name {
        case "dockerfile", "containerfile": return "dockerfile"
        case "makefile", "gnumakefile", "justfile": return "shell"
        case "gemfile", "podfile", "rakefile", "brewfile": return "ruby"
        case ".zshrc", ".bashrc", ".zprofile", ".profile", ".bash_profile", ".zshenv": return "shell"
        case ".gitconfig", ".editorconfig": return "ini"
        default: break
        }
        switch url.pathExtension.lowercased() {
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "tsx", "mts", "cts": return "typescript"
        case "py", "pyi": return "python"
        case "rs": return "rust"
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "metal", "glsl": return "cpp"
        case "m", "mm": return "objc"
        case "json", "jsonc": return "json"
        case "md", "markdown", "mdown", "mkd": return "markdown"
        case "html", "htm", "vue", "svelte": return "html"
        case "css", "scss", "less": return "css"
        case "go": return "go"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "scala": return "scala"
        case "cs": return "csharp"
        case "sql": return "sql"
        case "xml", "plist", "svg": return "xml"
        case "yaml", "yml": return "yaml"
        case "swift": return "swift"
        case "sh", "bash", "zsh", "fish": return "shell"
        case "toml": return "toml"
        case "rb": return "ruby"
        case "lua": return "lua"
        case "diff", "patch": return "diff"
        case "ini", "conf", "cfg", "env", "properties": return "ini"
        default: return nil
        }
    }

    /// The theme as the page wants it: the terminal's colors, its font and size.
    static func theme(_ t: Theme, fontSize: CGFloat) -> [String: Any] {
        func mix(_ a: RGB, _ b: RGB, _ f: Double) -> String {
            func c(_ x: UInt8, _ y: UInt8) -> Int { Int((Double(x) * (1 - f) + Double(y) * f).rounded()) }
            return String(format: "#%02x%02x%02x", c(a.r, b.r), c(a.g, b.g), c(a.b, b.b))
        }
        let dark = t.isDark
        var theme: [String: Any] = [
            "dark": dark,
            "bg": t.background.hexString, "fg": t.foreground.hexString,
            "selection": t.selection.hexString, "cursor": t.cursor.hexString,
            "muted": mix(t.foreground, t.background, 0.5),
            "line": dark ? "rgba(255,255,255,0.06)" : "rgba(24,26,44,0.05)",
            "match": dark ? "rgba(255,255,255,0.14)" : "rgba(24,26,44,0.12)",
            "panel": mix(t.background, dark ? RGB(255, 255, 255) : RGB(0, 0, 0), dark ? 0.06 : 0.03),
            "ansi": t.ansi.map(\.hexString),
            "font": "'Libertty Mono', 'JetBrainsMono Nerd Font', ui-monospace, 'SF Mono', Menlo, monospace",
            "ui": "-apple-system, system-ui, sans-serif",
            "fontSize": Double(fontSize),
        ]
        if let font = fontURL { theme["fontURL"] = font.absoluteString }
        return theme
    }

    /// Whether a file can be edited: a regular file under 5 MB that isn't
    /// binary (no NUL in its first 8 KB). Wider than `canShow`: a commit
    /// message (`git commit` with `EDITOR="libertty +open --wait"`) has no extension.
    static func canEdit(_ url: URL) -> Bool {
        guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) < 5_000_000 else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        // UTF-16 with its byte-order mark is text, NULs and all.
        if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return true }
        return !head.contains(0)
    }
}

/// Holds the page's messages for a document without the page's controller
/// keeping the document alive (WKUserContentController retains its handlers).
final class EditorMessages: NSObject, WKScriptMessageHandler {
    weak var receiver: DocumentView?
    init(_ receiver: DocumentView) { self.receiver = receiver }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        receiver?.editorMessage(type, body)
    }
}

/// `libertty +open --wait`: the CLI waits for the editor it asked for to close.
enum EditorWait {
    static let closed = Notification.Name("dev.libertty.terminal.editor-closed")

    static func post(_ token: String) {
        DistributedNotificationCenter.default().postNotificationName(
            closed, object: nil, userInfo: ["token": token], deliverImmediately: true)
    }
}
