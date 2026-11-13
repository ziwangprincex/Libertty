import AppKit
import LiberttyCore

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
    /// A coding agent's name, as its screen's rules know it (AgentScreen).
    var agent: String?

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

    init(name: String, symbol: String?, tint: Tint = .none, agent: String? = nil) {
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.agent = agent
    }

    /// Coding agents, by process name: what they show as, and that their
    /// screens tell what they're doing (Kero's list).
    static let agents: [String: ProgramBadge] = [
        "claude": ProgramBadge(name: "Claude Code", symbol: "sparkles", tint: .orange, agent: "claude"),
        "codex": ProgramBadge(name: "Codex", symbol: "wand.and.stars", tint: .teal, agent: "codex"),
        "gemini": ProgramBadge(name: "Gemini", symbol: "sparkle", tint: .blue, agent: "gemini"),
        "opencode": ProgramBadge(name: "OpenCode", symbol: "curlybraces", tint: .gray, agent: "opencode"),
        "amp": ProgramBadge(name: "Amp", symbol: "bolt", tint: .red, agent: "amp"),
        "cursor-agent": ProgramBadge(name: "Cursor Agent", symbol: "cursorarrow.rays", tint: .gray, agent: "cursor-agent"),
        "droid": ProgramBadge(name: "Droid", symbol: "cpu", tint: .orange, agent: "droid"),
        "qwen": ProgramBadge(name: "Qwen Code", symbol: "sparkle", tint: .purple, agent: "qwen"),
        "copilot": ProgramBadge(name: "Copilot", symbol: "airplane", tint: .indigo, agent: "copilot"),
        "kiro-cli": ProgramBadge(name: "Kiro", symbol: "sparkle", tint: .purple, agent: "kiro-cli"),
        "cline": ProgramBadge(name: "Cline", symbol: "sparkle", tint: .gray, agent: "cline"),
        "kimi": ProgramBadge(name: "Kimi", symbol: "moon.stars", tint: .indigo, agent: "kimi"),
        "pi": ProgramBadge(name: "Pi", symbol: "sparkle", tint: .green, agent: "pi"),
        "omp": ProgramBadge(name: "OMP", symbol: "sparkle", tint: .green, agent: "omp"),
        "aider": ProgramBadge(name: "Aider", symbol: "sparkle", tint: .green, agent: "aider"),
        "goose": ProgramBadge(name: "Goose", symbol: "bird", tint: .gray, agent: "goose"),
        "crush": ProgramBadge(name: "Crush", symbol: "heart", tint: .pink, agent: "crush"),
        "auggie": ProgramBadge(name: "Auggie", symbol: "sparkle", tint: .green, agent: "auggie"),
        "codebuddy": ProgramBadge(name: "CodeBuddy", symbol: "sparkle", tint: .indigo, agent: "codebuddy"),
        "iflow": ProgramBadge(name: "iFlow", symbol: "sparkle", tint: .blue, agent: "iflow"),
        "qodercli": ProgramBadge(name: "Qoder", symbol: "sparkle", tint: .gray, agent: "qodercli"),
        "kilocode": ProgramBadge(name: "Kilo Code", symbol: "sparkle", tint: .yellow, agent: "kilocode"),
        "jules": ProgramBadge(name: "Jules", symbol: "sparkle", tint: .purple, agent: "jules"),
        "junie": ProgramBadge(name: "Junie", symbol: "sparkle", tint: .green, agent: "junie"),
        "letta": ProgramBadge(name: "Letta Code", symbol: "sparkle", tint: .gray, agent: "letta"),
        "vibe": ProgramBadge(name: "Mistral Vibe", symbol: "sparkle", tint: .orange, agent: "vibe"),
        "cn": ProgramBadge(name: "Continue", symbol: "sparkle", tint: .gray, agent: "cn"),
        "trae": ProgramBadge(name: "Trae Agent", symbol: "sparkle", tint: .green, agent: "trae"),
        "openhands": ProgramBadge(name: "OpenHands", symbol: "hand.raised", tint: .gray, agent: "openhands"),
        "plandex": ProgramBadge(name: "Plandex", symbol: "sparkle", tint: .teal, agent: "plandex"),
    ]

    /// The agent a name is (AgentNames: Libertty's list, then yours).
    static func agentKey(_ name: String) -> String? { AgentNames.key(name) }

    private static let shellNames = AgentNames.shells

    /// Known programs, by process name.
    private static let known: [String: ProgramBadge] = {
        var t: [String: ProgramBadge] = agents
        t.merge([
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
        ]) { agent, _ in agent }
        // Other names for the same programs. A typo here would quietly drop
        // the alias, so it stops a debug build instead.
        for (alias, of) in [("python3", "python"), ("ipython", "python"), ("view", "vim"), ("vi", "vim"),
                            ("man", "less"), ("more", "less"), ("bunx", "bun"), ("pdx", "plandex")] {
            assert(t[of] != nil, "alias \(alias) of a program that isn't there: \(of)")
            t[alias] = t[of]
        }
        return t
    }()

    /// A shell in the foreground (a nested one, started by hand).
    static func shell(_ name: String) -> ProgramBadge {
        ProgramBadge(name: name.isEmpty ? "Shell" : name, symbol: "terminal", tint: .gray)
    }

    /// The badge for a foreground process: its name, and its arguments when
    /// it's a runtime (empty otherwise).
    static func forProcess(_ name: String, arguments: String = "") -> ProgramBadge {
        let name = AgentNames.baseName(name)
        if !arguments.isEmpty, runsAnotherProgram(name), let key = AgentNames.scripted(arguments) { return agent(key) }
        guard !name.isEmpty else { return shell("") }
        if let b = known[name.lowercased()] { return b }
        if let key = agentKey(name) { return agent(key) }
        if shellNames.contains(name.lowercased()) { return shell(name) }
        // Anything else: its own name, drawn as its first letter.
        return ProgramBadge(name: name, symbol: nil)
    }

    /// An agent's badge by its key: Libertty's, or one of yours (its rules'
    /// `name`, or its id), drawn as a sparkle.
    static func agent(_ key: String) -> ProgramBadge {
        if let b = agents[key] { return b }
        let name = AgentScreen.manifest(for: key)?.name ?? key
        return ProgramBadge(name: name, symbol: "sparkle", tint: .gray, agent: key)
    }

    /// A program that runs something else lives inside it: a language
    /// runtime, a shell (AgentNames). Only for these is the argument list
    /// worth reading (see TerminalSession.foregroundProgram).
    static func runsAnotherProgram(_ name: String) -> Bool { AgentNames.runsAnotherProgram(name) }
}

/// One pane's tile, ready for the sidebar.
struct ProgramTile: Equatable {
    var name: String
    var symbol: String?
    var tint: ProgramBadge.Tint = .none
    /// Where an ssh session went (its host), for the tab's label.
    var host: String?
    /// A coding agent's name, when it is one.
    var agent: String?

    init(_ badge: ProgramBadge, host: String? = nil) {
        name = badge.name
        symbol = badge.symbol
        tint = badge.tint
        agent = badge.agent
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
    /// How many glyphs before "+N" takes over (`tab-icons`, Rex's Show tab icons).
    static var cap = 3

    var tiles: [ProgramTile] = [] { didSet { changed() } }
    /// Drawn instead of the tiles when no program runs.
    var fallbackSymbol: String? { didSet { changed() } }

    private var shown: [ProgramTile] = []
    private var overflow = 0

    private func changed() {
        // The last ones: the focused pane's comes last, to sit in front.
        shown = Self.cap > 0 ? Array(tiles.suffix(Self.cap)) : []
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

    // VoiceOver: the programs the glyphs stand for ("Running: claude, vim"); none at a prompt.
    override func isAccessibilityElement() -> Bool { !tiles.isEmpty }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? {
        tiles.isEmpty ? nil : L10n.t("Running") + ": " + tiles.map(\.name).joined(separator: ", ")
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
            let rect = NSRect(x: CGFloat(i) * Self.step, y: 0, width: Self.size, height: Self.size)
            // A coding agent: its own logo, a gap clear of the one in front.
            if let agent = tile.agent, let logo = AgentLogo.image(agent) {
                let front = i + 1 < shown.count ? rect.offsetBy(dx: Self.step, dy: 0) : nil
                AgentLogo.draw(logo, agent: agent, in: rect, under: front, color: color ?? .secondaryLabelColor)
                continue
            }
            if let symbol = tile.symbol {
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

/// Coding agents' own logos, as their makers publish them (Resources/logos,
/// by agent; where each came from is in THIRD-PARTY-NOTICES.txt): on the
/// tabs in place of a glyph, drawn as they are. Each is its maker's
/// trademark, shown only to say which program runs in the pane.
enum AgentLogo {
    /// One-color marks: drawn in the label's color, as a glyph is.
    private static let monochrome: Set<String> = ["copilot", "cline", "auggie"]
    /// Made for a dark background (its white would vanish on a light
    /// sidebar): drawn on that dark.
    private static let onDark: [String: NSColor] = ["omp": NSColor(srgbRed: 0x0d / 255, green: 0x0d / 255, blue: 0x0d / 255, alpha: 1)]
    /// A square picture (an avatar): its corners rounded, as an app icon's.
    private static let squarePicture: Set<String> = ["codex"]
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
    nonisolated(unsafe) private static var missing: Set<String> = []

    static func image(_ agent: String) -> NSImage? {
        if let image = cache[agent] { return image }
        guard !missing.contains(agent) else { return nil }
        let url = ["svg", "png"].lazy.compactMap { AppResources.url("logos/\(agent).\($0)") }.first
        guard let url, let image = NSImage(contentsOf: url) else {
            missing.insert(agent)
            return nil
        }
        cache[agent] = image
        return image
    }

    /// `image` fitted into `rect`; `under`: the logo in front of it, which
    /// it stays a gap clear of, so each reads as its own.
    static func draw(_ image: NSImage, agent: String, in rect: NSRect, under front: NSRect?, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let radius = (rect.width * 0.22).rounded()
        if let front {
            let gap: CGFloat = 1.5
            let clip = NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2))
            clip.append(NSBezierPath(roundedRect: front.insetBy(dx: -gap, dy: -gap), xRadius: radius + gap, yRadius: radius + gap))
            clip.windingRule = .evenOdd
            clip.addClip()
        }
        var box = rect
        if let plate = onDark[agent] {
            plate.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            box = rect.insetBy(dx: rect.width * 0.12, dy: rect.width * 0.12)
        }
        if squarePicture.contains(agent) { NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip() }
        // Its own proportions, centered.
        let size = image.size
        let scale = min(box.width / max(size.width, 1), box.height / max(size.height, 1))
        let fitted = NSRect(x: box.midX - size.width * scale / 2, y: box.midY - size.height * scale / 2,
                            width: size.width * scale, height: size.height * scale)
        (monochrome.contains(agent) ? image.tinting(color) : image).draw(in: fitted)
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
