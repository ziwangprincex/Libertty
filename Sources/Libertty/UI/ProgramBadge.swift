import AppKit

/// What a pane's program shows as: its name (for the tooltip) and a glyph.
/// Monochrome on purpose — a row of colored squares in the sidebar reads
/// as decoration, not information; the glyph is what says which program
/// it is.
struct ProgramBadge {
    let name: String
    /// An SF Symbol, or nil to draw the name's first letter.
    let symbol: String?

    init(name: String, symbol: String?) {
        self.name = name
        self.symbol = symbol
    }

    private static let shellNames: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "nu", "pwsh", "elvish", "xonsh", "tcsh", "csh", "ksh", "cmd", "powershell",
    ]

    /// Known programs, by process name.
    private static let known: [String: ProgramBadge] = {
        var t: [String: ProgramBadge] = [
            "claude": ProgramBadge(name: "Claude Code", symbol: "sparkles"),
            "codex": ProgramBadge(name: "Codex", symbol: "wand.and.stars"),
            "node": ProgramBadge(name: "Node", symbol: "hexagon"),
            "bun": ProgramBadge(name: "Bun", symbol: "hare"),
            "deno": ProgramBadge(name: "Deno", symbol: "diamond"),
            "python": ProgramBadge(name: "Python", symbol: "chevron.left.forwardslash.chevron.right"),
            "lazygit": ProgramBadge(name: "Git Changes", symbol: "plus.forwardslash.minus"),
            "tig": ProgramBadge(name: "Git Log", symbol: "clock"),
            "git": ProgramBadge(name: "Git", symbol: "arrow.triangle.branch"),
            "vim": ProgramBadge(name: "Vim", symbol: "pencil"),
            "nvim": ProgramBadge(name: "Neovim", symbol: "pencil"),
            "hx": ProgramBadge(name: "Helix", symbol: "pencil"),
            "emacs": ProgramBadge(name: "Emacs", symbol: "book"),
            "htop": ProgramBadge(name: "Activity", symbol: "chart.bar"),
            "btop": ProgramBadge(name: "Activity", symbol: "chart.bar"),
            "top": ProgramBadge(name: "Activity", symbol: "chart.bar"),
            "ssh": ProgramBadge(name: "SSH", symbol: "globe"),
            "mosh": ProgramBadge(name: "Mosh", symbol: "globe"),
            "docker": ProgramBadge(name: "Docker", symbol: "shippingbox"),
            "go": ProgramBadge(name: "Go", symbol: "hammer"),
            "cargo": ProgramBadge(name: "Cargo", symbol: "hammer"),
            "rustc": ProgramBadge(name: "Rust", symbol: "hammer"),
            "npm": ProgramBadge(name: "npm", symbol: "shippingbox"),
            "pnpm": ProgramBadge(name: "pnpm", symbol: "shippingbox"),
            "yarn": ProgramBadge(name: "Yarn", symbol: "shippingbox"),
            "ruby": ProgramBadge(name: "Ruby", symbol: "diamond"),
            "lua": ProgramBadge(name: "Lua", symbol: "moon"),
            "php": ProgramBadge(name: "PHP", symbol: "chevron.left.forwardslash.chevron.right"),
            "psql": ProgramBadge(name: "PostgreSQL", symbol: "cylinder"),
            "mysql": ProgramBadge(name: "MySQL", symbol: "cylinder"),
            "redis-cli": ProgramBadge(name: "Redis", symbol: "cylinder"),
            "tmux": ProgramBadge(name: "tmux", symbol: "rectangle.split.2x1"),
            "make": ProgramBadge(name: "Make", symbol: "hammer"),
            "swift": ProgramBadge(name: "Swift", symbol: "swift"),
            "less": ProgramBadge(name: "Pager", symbol: "doc.text"),
            "tail": ProgramBadge(name: "Log", symbol: "doc.text"),
        ]
        // Other names for the same programs. A typo here would quietly drop
        // the alias, so it stops a debug build instead.
        for (alias, of) in [("python3", "python"), ("ipython", "python"), ("view", "vim"), ("vi", "vim"),
                            ("man", "less"), ("more", "less"), ("bunx", "bun")] {
            assert(t[of] != nil, "alias \(alias) of a program that isn't there: \(of)")
            t[alias] = t[of]
        }
        return t
    }()

    /// A shell in the foreground (a nested one, started by hand).
    static func shell(_ name: String) -> ProgramBadge {
        ProgramBadge(name: name.isEmpty ? "Shell" : name, symbol: "terminal")
    }

    /// Programs often started through something else — a wrapper (tclaude),
    /// a launcher, npx — and worth finding behind it. By process name.
    static func isOftenWrapped(_ name: String) -> Bool {
        ["claude", "codex"].contains(name.lowercased())
    }

    /// The badge for a foreground process: its name, and its arguments when
    /// it's a runtime (empty otherwise).
    static func forProcess(_ name: String, arguments: String = "") -> ProgramBadge {
        let base = (name as NSString).lastPathComponent
        let name = base.hasPrefix("-") ? String(base.dropFirst()) : base
        if !arguments.isEmpty, runsAnotherProgram(name), let badge = scripted(arguments) { return badge }
        guard !name.isEmpty else { return shell("") }
        if let b = known[name.lowercased()] { return b }
        if shellNames.contains(name.lowercased()) { return shell(name) }
        // Anything else: its own name, drawn as its first letter.
        return ProgramBadge(name: name, symbol: nil)
    }

    /// The program a runtime runs, by the script it was given: the script's
    /// own name (`node /opt/homebrew/bin/claude`, through its shebang) or
    /// the package it's in (`…/node_modules/@openai/codex/bin/codex.js`).
    /// Names only, never a substring of the command line:
    /// /Users/claude/server.js isn't Claude Code, nor imagemagick Ruby.
    private static func scripted(_ arguments: String) -> ProgramBadge? {
        // The script is the first argument that isn't an option.
        guard let script = arguments.split(separator: " ").first(where: { !$0.hasPrefix("-") }) else { return nil }
        let parts = script.split(separator: "/").map(String.init)
        var names: [String] = []
        if let last = parts.last { names.append((last as NSString).deletingPathExtension) }
        if let i = parts.lastIndex(of: "node_modules"), i + 1 < parts.count {
            let package = parts[i + 1].hasPrefix("@") && i + 2 < parts.count ? parts[i + 2] : parts[i + 1]
            names.append(package)
        }
        for name in names.map({ $0.lowercased() }) {
            // "claude", or "claude-code".
            if let key = ["claude", "codex"].first(where: { name == $0 || name.hasPrefix($0 + "-") }) {
                return known[key]
            }
        }
        return nil
    }

    /// A program that runs something else lives inside it: a language
    /// runtime, a shell. Only for these is the argument list worth reading
    /// (see TerminalSession.foregroundProgram).
    static func runsAnotherProgram(_ name: String) -> Bool {
        let runtime = ["node", "deno", "bun", "python", "python3", "ipython", "ruby", "perl", "php", "lua",
                       "java", "dotnet", "cargo", "go"]
        let base = (name as NSString).lastPathComponent.lowercased()
        return shellNames.contains(base) || runtime.contains(base)
    }
}

/// One pane's tile, ready for the sidebar.
struct ProgramTile: Equatable {
    var name: String
    var symbol: String?
    /// Where an ssh session went (its host), for the tab's label.
    var host: String?

    init(_ badge: ProgramBadge, host: String? = nil) {
        name = badge.name
        symbol = badge.symbol
        self.host = host
    }

    /// The host in an ssh command line: its first argument that isn't an
    /// option or an option's value (GoRex's reading). `-l user` stays out;
    /// `user@host` is the host as typed.
    static func sshHost(_ arguments: String) -> String? {
        let words = arguments.split(separator: " ").map(String.init)
        let takesValue = Set("bcDEeFIiJLlmOopQRSWw")
        var i = 0
        while i < words.count {
            let word = words[i]
            if word.hasPrefix("-") {
                if word.count == 2, let flag = word.last, takesValue.contains(flag) { i += 1 }
                i += 1
                continue
            }
            return word
        }
        return nil
    }
}

/// A tab's glyphs, one per pane running a program, drawn overlapping with
/// the focused pane's in front (Rex's stacked tiles). A tab whose panes
/// sit at their prompts has no glyphs: it draws `fallbackSymbol`, the
/// tab's own, so an idle shell stays quiet.
final class TileStack: NSView {
    static let size: CGFloat = 14
    static let step: CGFloat = 11
    /// How many glyphs before "+N" takes over.
    private static let cap = 4

    var tiles: [ProgramTile] = [] { didSet { changed() } }
    /// Drawn instead of the tiles when no program runs.
    var fallbackSymbol: String? { didSet { changed() } }

    private var shown: [ProgramTile] = []
    private var overflow = 0

    private func changed() {
        // The last ones: the focused pane's comes last, to sit in front.
        shown = Array(tiles.suffix(Self.cap))
        overflow = tiles.count - shown.count
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        guard !shown.isEmpty else {
            return NSSize(width: fallbackSymbol == nil ? 0 : 16, height: Self.size)
        }
        let width = Self.step * CGFloat(shown.count - 1) + Self.size
        return NSSize(width: overflow > 0 ? width + 12 : width, height: Self.size)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !shown.isEmpty else {
            if let symbol = fallbackSymbol {
                Self.drawSymbol(symbol, in: bounds, size: 11)
            }
            return
        }
        for (i, tile) in shown.enumerated() {
            // Front to back: the last one is the focused pane's.
            if let symbol = tile.symbol {
                let rect = NSRect(x: CGFloat(i) * Self.step, y: 0, width: Self.size, height: Self.size)
                Self.drawSymbol(symbol, in: rect, size: 11)
            } else {
                Self.drawLetter(tile.name, at: CGFloat(i) * Self.step)
            }
        }
        if overflow > 0 {
            let string = NSAttributedString(string: "+\(overflow)", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            string.draw(at: NSPoint(x: CGFloat(shown.count) * Self.step + 1, y: 1))
        }
    }

    /// A symbol fades as it goes back in the stack, so the focused pane's
    /// is the one you read.
    private static func drawSymbol(_ name: String, in rect: NSRect, size: CGFloat) {
        let color = NSColor.secondaryLabelColor
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let tinted = image.withSymbolConfiguration(.init(pointSize: size, weight: .regular))?.tinting(color)
        else { return }
        let box = tinted.size
        tinted.draw(in: NSRect(x: rect.minX, y: rect.midY - box.height / 2, width: box.width, height: box.height))
    }

    private static func drawLetter(_ name: String, at x: CGFloat) {
        let letter = NSAttributedString(string: String(name.prefix(1)).uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let box = letter.size()
        letter.draw(at: NSPoint(x: x + 2, y: (Self.size - box.height) / 2))
    }
}

private extension NSImage {
    /// A template symbol in a color of its own.
    func tinting(_ color: NSColor) -> NSImage {
        let image = copy() as! NSImage
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceIn)
        image.unlockFocus()
        return image
    }
}
