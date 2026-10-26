import AppKit

/// What a pane's program shows as: its name (for the tooltip) and a glyph.
/// Monochrome by default — a row of colored squares in the sidebar reads
/// as decoration, not information; the glyph is what says which program
/// it is. `tab-icon-color` (Rex's Use color for tab icons) draws each in
/// its program's color.
struct ProgramBadge {
    let name: String
    /// An SF Symbol, or nil to draw the name's first letter.
    let symbol: String?
    /// The program's color, for `tab-icon-color`.
    let tint: Tint

    /// System colors, so a light or dark sidebar shows each as it should.
    enum Tint: String { case none, orange, green, teal, blue, indigo, purple, pink, red, yellow, brown, gray, cyan
        var color: NSColor? {
            switch self {
            case .none: nil
            case .orange: .systemOrange
            case .green: .systemGreen
            case .teal: .systemTeal
            case .blue: .systemBlue
            case .indigo: .systemIndigo
            case .purple: .systemPurple
            case .pink: .systemPink
            case .red: .systemRed
            case .yellow: .systemYellow
            case .brown: .systemBrown
            case .gray: .systemGray
            case .cyan: .systemCyan
            }
        }
    }

    init(name: String, symbol: String?, tint: Tint = .none) {
        self.name = name
        self.symbol = symbol
        self.tint = tint
    }

    private static let shellNames: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "nu", "pwsh", "elvish", "xonsh", "tcsh", "csh", "ksh", "cmd", "powershell",
    ]

    /// Known programs, by process name.
    private static let known: [String: ProgramBadge] = {
        var t: [String: ProgramBadge] = [
            "claude": ProgramBadge(name: "Claude Code", symbol: "sparkles", tint: .orange),
            "codex": ProgramBadge(name: "Codex", symbol: "wand.and.stars", tint: .teal),
            "node": ProgramBadge(name: "Node", symbol: "hexagon", tint: .green),
            "bun": ProgramBadge(name: "Bun", symbol: "hare", tint: .brown),
            "deno": ProgramBadge(name: "Deno", symbol: "diamond", tint: .gray),
            "python": ProgramBadge(name: "Python", symbol: "chevron.left.forwardslash.chevron.right", tint: .blue),
            "lazygit": ProgramBadge(name: "Git Changes", symbol: "plus.forwardslash.minus", tint: .red),
            "tig": ProgramBadge(name: "Git Log", symbol: "clock", tint: .red),
            "git": ProgramBadge(name: "Git", symbol: "arrow.triangle.branch", tint: .red),
            "vim": ProgramBadge(name: "Vim", symbol: "pencil", tint: .green),
            "nvim": ProgramBadge(name: "Neovim", symbol: "pencil", tint: .green),
            "hx": ProgramBadge(name: "Helix", symbol: "pencil", tint: .purple),
            "emacs": ProgramBadge(name: "Emacs", symbol: "book", tint: .purple),
            "htop": ProgramBadge(name: "Activity", symbol: "chart.bar", tint: .yellow),
            "btop": ProgramBadge(name: "Activity", symbol: "chart.bar", tint: .yellow),
            "top": ProgramBadge(name: "Activity", symbol: "chart.bar", tint: .yellow),
            "ssh": ProgramBadge(name: "SSH", symbol: "globe", tint: .cyan),
            "mosh": ProgramBadge(name: "Mosh", symbol: "globe", tint: .cyan),
            "docker": ProgramBadge(name: "Docker", symbol: "shippingbox", tint: .blue),
            "go": ProgramBadge(name: "Go", symbol: "hammer", tint: .cyan),
            "cargo": ProgramBadge(name: "Cargo", symbol: "hammer", tint: .orange),
            "rustc": ProgramBadge(name: "Rust", symbol: "hammer", tint: .orange),
            "npm": ProgramBadge(name: "npm", symbol: "shippingbox", tint: .red),
            "pnpm": ProgramBadge(name: "pnpm", symbol: "shippingbox", tint: .yellow),
            "yarn": ProgramBadge(name: "Yarn", symbol: "shippingbox", tint: .blue),
            "ruby": ProgramBadge(name: "Ruby", symbol: "diamond", tint: .red),
            "lua": ProgramBadge(name: "Lua", symbol: "moon", tint: .indigo),
            "php": ProgramBadge(name: "PHP", symbol: "chevron.left.forwardslash.chevron.right", tint: .indigo),
            "psql": ProgramBadge(name: "PostgreSQL", symbol: "cylinder", tint: .blue),
            "mysql": ProgramBadge(name: "MySQL", symbol: "cylinder", tint: .orange),
            "redis-cli": ProgramBadge(name: "Redis", symbol: "cylinder", tint: .red),
            "tmux": ProgramBadge(name: "tmux", symbol: "rectangle.split.2x1", tint: .green),
            "make": ProgramBadge(name: "Make", symbol: "hammer", tint: .gray),
            "swift": ProgramBadge(name: "Swift", symbol: "swift", tint: .orange),
            "less": ProgramBadge(name: "Pager", symbol: "doc.text", tint: .gray),
            "tail": ProgramBadge(name: "Log", symbol: "doc.text", tint: .gray),
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
        ProgramBadge(name: name.isEmpty ? "Shell" : name, symbol: "terminal", tint: .gray)
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
    var tint: ProgramBadge.Tint = .none
    /// Where an ssh session went (its host), for the tab's label.
    var host: String?

    init(_ badge: ProgramBadge, host: String? = nil) {
        name = badge.name
        symbol = badge.symbol
        tint = badge.tint
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
    /// `tab-icon-color`: each glyph in its program's color.
    static var colored = false
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
            let color = Self.colored ? tile.tint.color : nil
            if let symbol = tile.symbol {
                let rect = NSRect(x: CGFloat(i) * Self.step, y: 0, width: Self.size, height: Self.size)
                Self.drawSymbol(symbol, in: rect, size: 11, color: color)
            } else {
                Self.drawLetter(tile.name, at: CGFloat(i) * Self.step, color: color)
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
    private static func drawSymbol(_ name: String, in rect: NSRect, size: CGFloat, color: NSColor? = nil) {
        let color = color ?? NSColor.secondaryLabelColor
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let tinted = image.withSymbolConfiguration(.init(pointSize: size, weight: .regular))?.tinting(color)
        else { return }
        let box = tinted.size
        tinted.draw(in: NSRect(x: rect.minX, y: rect.midY - box.height / 2, width: box.width, height: box.height))
    }

    private static func drawLetter(_ name: String, at x: CGFloat, color: NSColor? = nil) {
        let letter = NSAttributedString(string: String(name.prefix(1)).uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: color ?? NSColor.secondaryLabelColor,
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
