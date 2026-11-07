import AppKit

/// A prompt to paste into a coding agent that brings your keybindings over
/// from Ghostty, iTerm2 and tmux (Rex's "Migrate your config"): the agent
/// reads them, finds Libertty's actions, and adds `keybind` lines to the
/// config file in place. `libertty +migrate-prompt` prints it; Help ▸ Copy
/// Config Migration Prompt and the welcome guide copy it.
enum MigrationPrompt {
    enum Source: String, CaseIterable {
        case ghostty, iterm2, tmux

        var name: String {
            switch self {
            case .ghostty: "Ghostty"
            case .iterm2: "iTerm2"
            case .tmux: "tmux"
            }
        }

        /// Where its bindings are, as the prompt tells the agent.
        var instructions: String {
            switch self {
            case .ghostty:
                "Ghostty: ~/.config/ghostty/config or config.ghostty, and ~/Library/Application Support/com.mitchellh.ghostty/config "
                    + "or config.ghostty (and the files their `config-file` lines pull in). Its `keybind` lines use Libertty's format; "
                    + "check each action exists in Libertty. (Ghostty's other settings: `libertty +import-ghostty` brings those; leave them.)"
            case .iterm2:
                "iTerm2: `plutil -convert json -o - ~/Library/Preferences/com.googlecode.iterm2.plist` — `GlobalKeyMap` and each "
                    + "profile's `Keyboard Map` under `New Bookmarks`; keys are \"0xCHARACTER-0xMODIFIERS\" hex pairs (modifier bits: "
                    + "0x20000 shift, 0x40000 control, 0x80000 option, 0x100000 command)."
            case .tmux:
                "tmux: ~/.tmux.conf or ~/.config/tmux/tmux.conf — `bind`/`bind-key` lines (and its default prefix bindings, if it "
                    + "keeps them). Libertty has no prefix key: give a pane or tab action a direct chord (cmd+… or ctrl+shift+…) "
                    + "only where it isn't one of Libertty's defaults already, and say which you mapped."
            }
        }

        /// Whether this Mac has its settings.
        var found: Bool {
            let home = NSHomeDirectory()
            let fm = FileManager.default
            switch self {
            case .ghostty: return !GhosttyImport.ghosttyFiles.isEmpty
            case .iterm2: return fm.fileExists(atPath: home + "/Library/Preferences/com.googlecode.iterm2.plist")
            case .tmux: return [home + "/.tmux.conf", home + "/.config/tmux/tmux.conf"].contains { fm.fileExists(atPath: $0) }
            }
        }
    }

    /// The prompt for `sources` (none: all of them), naming `config` as the file to edit.
    static func text(from sources: [Source] = [], config: String) -> String {
        let from = sources.isEmpty ? Source.allCases : sources
        let names = from.map(\.name).joined(separator: ", ")
        return """
        Migrate my terminal keybindings from \(names) to Libertty, the terminal you're running in.

        Libertty's config file is \(config): `key = value` lines, Ghostty's format. Keybindings are repeatable lines \
        `keybind = TRIGGER=ACTION`, e.g. `keybind = cmd+d=new_split:right`; `keybind = cmd+k=unbind` removes a default. \
        Libertty has no key sequences or prefix keys.

        1. See what Libertty has: run `libertty +list-actions` (every action and its arguments) and `libertty +list-keybinds` \
        (the bindings in effect now, defaults included).
        2. Read my bindings from:
        \(from.map { "   - " + $0.instructions }.joined(separator: "\n"))
        3. For each binding whose action Libertty has, and that isn't already Libertty's default for that action, plan a \
        `keybind = …` line. When it would take a trigger Libertty uses for something else, skip it unless mine clearly \
        should win, and say so. Don't migrate themes, fonts or any other settings.
        4. Keep a copy first: `cp \(quoted(config)) \(quoted(config + ".before-migration"))` (if the file exists). Then edit the file in place: \
        append one block headed `# Keybindings migrated from \(names), <today's date>`. Never rewrite, reorder or remove \
        my other lines — Libertty writes to this file too.
        5. Check it: `libertty +validate-config` must report no problems. A running Libertty applies the file at once.
        6. Tell me what you added, and what you left out and why (no matching action, a conflict, a prefix sequence).
        """
    }

    /// `path` for the shell: as it is when nothing in it needs quoting (a
    /// leading ~ must stay outside quotes to expand), else ~/ then the rest quoted.
    static func quoted(_ path: String) -> String {
        let plain = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-~+".contains($0) }
        if plain { return path }
        let (home, rest) = path.hasPrefix("~/") ? ("~/", String(path.dropFirst(2))) : ("", path)
        return home + "'" + rest.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `libertty +migrate-prompt [--from ghostty|iterm2|tmux]…`: print it.
    static func run(_ args: [String]) -> Int32 {
        var sources: [Source] = []
        var i = 0
        while i < args.count {
            guard args[i] == "--from", i + 1 < args.count, let source = Source(rawValue: args[i + 1].lowercased()) else {
                FileHandle.standardError.write(Data("usage: libertty +migrate-prompt [--from ghostty|iterm2|tmux]…\n".utf8))
                return 2
            }
            sources.append(source)
            i += 2
        }
        print(text(from: sources, config: shownConfig))
        return 0
    }

    /// The config file as the prompt names it (~ for your home).
    static var shownConfig: String {
        (ConfigStore.shared.url.path as NSString).abbreviatingWithTildeInPath
    }

    /// The prompt for what this Mac has (else all), as the menu and guide copy it.
    static var forThisMac: String { text(from: Source.allCases.filter(\.found), config: shownConfig) }

    /// Help ▸ Migrate Keybindings with an Agent…, and the welcome guide: the
    /// prompt shown, and copied to paste into an agent.
    @MainActor static func copy() {
        let prompt = forThisMac
        let alert = NSAlert()
        alert.messageText = L10n.t("Migrate your keybindings with an agent")
        alert.informativeText = L10n.t("Paste this prompt into a coding agent running in Libertty, such as Claude Code or Codex. "
            + "It brings over your keybindings; themes, fonts and other settings stay as they are.")
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 200))
        text.string = prompt
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        text.textContainerInset = NSSize(width: 4, height: 4)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 200))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: L10n.t("Copy Prompt"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        let copy = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { r in MainActor.assumeIsolated { copy(r) } }
        } else {
            copy(alert.runModal())
        }
    }
}
