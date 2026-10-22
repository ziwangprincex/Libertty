import AppKit

/// User settings, read from `~/.config/libertty/config`: Ghostty's format,
/// `key = value` lines with `#` comments. Every key is optional; missing or
/// invalid values keep their defaults. `palette`, `keybind` and
/// `config-file` may repeat.
struct Config: Equatable {
    enum CursorStyle: String, CaseIterable { case block, bar, underline, block_hollow }
    enum OptionAsAlt: String, CaseIterable { case `false`, `true`, left, right }
    enum SaveState: String, CaseIterable { case `default`, never, always }
    enum NotifyWhen: String, CaseIterable { case never, unfocused, always }
    enum QuickPosition: String, CaseIterable { case top, bottom, left, right, center }
    /// When panes wear a header (Tern's `pane-headers`).
    enum PaneHeaders: String, CaseIterable { case never, split, always }
    /// Where the tabs are listed: the sidebar, or along the top (Tern's horizontal tabs).
    enum TabBar: String, CaseIterable { case sidebar, top }
    enum AutoUpdate: String, CaseIterable { case off, check, download }

    var theme = ThemeSpec(light: "Libertty Light", dark: Theme.defaultName)
    var fontFamily = ""  // empty: the bundled JetBrains Mono Nerd Font
    /// Ghostty's `font-feature` lines; `-calt`/`-liga` turn ligatures off.
    var fontFeatures: [String] = []
    var ligatures: Bool {
        // HarfBuzz feature syntax, as Ghostty reads it: `-calt`, `+calt`,
        // `calt`, `calt=0`, `calt off`, several per line with commas. The
        // last setting of a tag wins.
        var on = ["calt": true, "liga": true]
        for line in fontFeatures {
            for item in line.split(separator: ",") {
                var text = item.trimmingCharacters(in: .whitespaces).lowercased()
                var value = true
                if text.hasPrefix("-") { value = false; text.removeFirst() } else if text.hasPrefix("+") { text.removeFirst() }
                let parts = text.split(whereSeparator: { $0 == "=" || $0 == " " }).map(String.init)
                guard let tag = parts.first, on[tag] != nil else { continue }
                if parts.count > 1 { value = !["0", "off", "false"].contains(parts[1]) && value }
                on[tag] = value
            }
        }
        return on.values.allSatisfy { $0 }
    }
    var fontSize: Double = 13
    var background: RGB?
    var foreground: RGB?
    var cursorColor: RGB?
    var selectionBackground: RGB?
    var palette: [Int: RGB] = [:]
    var cursorStyle = CursorStyle.block
    var backgroundOpacity: Double = 1
    var backgroundBlur = true
    var windowPaddingX: Double = 10
    var windowPaddingY: Double = 6
    /// Ghostty's `window-padding-color`: background, extend or extend-always.
    var windowPaddingColor = TerminalRenderer.PaddingColor.background
    var windowColumns = 100
    var windowRows = 30
    var unfocusedSplitOpacity: Double = 0.65
    var paneHeaders = PaneHeaders.never
    var tabBar = TabBar.sidebar
    /// Ghostty's `scrollback-limit`: bytes of history per terminal.
    var scrollbackLimit = 10_000_000
    var optionAsAlt = OptionAsAlt.false
    var copyOnSelect = false
    var confirmClose = true
    var command = ""  // empty: the login shell
    /// `inherit` (the focused pane's directory), `home`, or a path.
    var workingDirectory = "inherit"
    /// Brings Libertty forward from any app (opening a window if there is none),
    /// or hides it when it is in front. Empty for none, as in Tern: the
    /// obvious keys (⌃`, ⌥Space) belong to editors and launchers.
    var globalHotkey = ""
    /// Opens a new window from any app. ⌃⌥T is the "open a terminal" key on
    /// Linux desktops and unused by macOS.
    var globalNewWindowHotkey = "ctrl+alt+t"
    /// Keep running without windows (so the global hotkeys still work), as
    /// macOS terminals do.
    var quitAfterLastWindowClosed = false
    /// `keybind` lines in file order, applied over the defaults.
    var keybinds: [String] = []
    /// New windows show the sidebar (tabs and files) / the inspector.
    var windowSidebar = true
    var windowInspector = false
    var sidebarShowHiddenFiles = true
    var sidebarFiles = true
    /// Markdown files open rendered (Tern's markdown_rendered); off shows the source.
    var markdownRendered = true
    /// Text files open in the editor (CodeMirror 6); false shows them as pages.
    var editSourceFiles = true
    /// The editor's keys: `default` (macOS) or `vim`.
    var editorKeymap = "default"
    /// What the browser's bar searches with: `%s` is the words typed.
    var browserSearch = "https://duckduckgo.com/?q=%s"
    /// The notebook block's `jupyter` (empty: the login shell's).
    var jupyter = ""
    /// `libertty +browser` may read and act in pages (text, eval, click…).
    var browserAutomation = false
    /// Ghostty's `window-vsync`. Off: frames go to the screen as soon as
    /// they're drawn (full screen always syncs). On: never tears, but types
    /// up to two frames later.
    var windowVsync = false
    /// Shells live in liberttyd: quitting (or a crash, or an update) keeps them
    /// running, and the next launch shows them again.
    var sessionPersistence = true
    /// Ghostty's `window-save-state`: reopen last time's windows at launch.
    var windowSaveState = SaveState.default
    /// OSC 9 / OSC 777 notifications, and programs (OSC 7501) that need you.
    var desktopNotifications = true
    /// Ghostty's notify-on-command-finish(-after): long commands that end
    /// while you're elsewhere tell you so.
    var notifyOnCommandFinish = NotifyWhen.unfocused
    var notifyOnCommandFinishAfter: Double = 10
    /// Each way a program's state (OSC 7501) gets your attention follows the
    /// states its setting names, apart from the others (after Rex): the
    /// tab's mark, notifications (with the pane's lit edge), the Dock badge,
    /// a sound.
    var programStatusIndicator = Set(ProgramStatusStore.State.allCases)
    var programStatusNotify: Set<ProgramStatusStore.State> = [.blocked, .done, .error]
    var programStatusDockBadge: Set<ProgramStatusStore.State> = [.blocked]
    /// A state's sound, by name ("" for the alert sound).
    var programStatusSound: [ProgramStatusStore.State: String] = [:]
    /// Agents set up by `libertty +agent-setup` are asked to name their
    /// session after their task (Rex's "Let agents name sessions").
    var agentSessionNames = true
    /// Ghostty's `cursor-style-blink`: nil blinks by default (and lets DEC
    /// mode 12 decide), true/false fix the default; programs can still change it.
    var cursorStyleBlink: Bool?
    /// Ghostty's `undo-timeout`: how long a closed pane, tab or window can
    /// be brought back with ⌘Z (its programs keep running meanwhile); 0 ends them at once.
    var undoTimeout: Double = 5
    /// Ghostty's `wait-after-command`: a pane stays when its program ends,
    /// until a key is pressed in it.
    var waitAfterCommand = false
    /// Ghostty's `focus-follows-mouse`: the pane under the pointer gets the keyboard.
    var focusFollowsMouse = false
    /// Ghostty's `abnormal-command-exit-runtime` (ms): a program that fails
    /// sooner than this keeps its pane, so its error can be read (Rex too).
    var abnormalCommandExitRuntime = 250
    /// Libertty ▸ Web Access: off, local (this Mac only) or network.
    var webAccess = "off"
    var webAccessPort = 7682
    /// Whether a browser may type, or only watch.
    var webAccessInput = true
    /// Ghostty's `mouse-hide-while-typing`.
    var mouseHideWhileTyping = false
    /// Trackpad scrolling moves the content by points, not whole rows.
    var scrollSmooth = true
    /// Ghostty's `bell-features`: system (the macOS alert sound), attention
    /// (bounce the Dock icon), title (🔔 in the tab title), border (flash the pane).
    var bellFeatures: Set<String> = ["attention", "title"]
    /// Ghostty's `scrollbar`: system (an overlay scroller while scrolling) or never.
    var scrollbar = "system"
    /// Ghostty's `auto-update`: look for a new version daily and offer it
    /// (check), fetch it in the background too (download), or never (off).
    var autoUpdate = AutoUpdate.check
    /// Ghostty's quick terminal: a terminal that drops down from a screen edge.
    var quickTerminalPosition = QuickPosition.top
    /// Share of the screen it covers (height for top/bottom, width for left/right).
    var quickTerminalSize: Double = 0.45
    /// Put it away when another window or app takes focus.
    var quickTerminalAutohide = true
    /// Shorthand for keybind = global:KEY=toggle_quick_terminal.
    var quickTerminalHotkey = ""
    /// Ghostty's `term`: what TERM shells get. xterm-ghostty uses the
    /// terminfo Libertty ships; programs then know about undercurl, sync output…
    var term = "xterm-ghostty"
    /// With xterm-ghostty, ssh gets TERM=xterm-256color, which every host knows.
    var sshEnv = true
    /// OSC 52: programs (vim over ssh, tmux) setting / reading the clipboard.
    var clipboardWrite = true
    var clipboardRead = false

    /// The effective key table, including the global-hotkey shorthands.
    var keybindTable: Keybinds {
        var entries = keybinds
        if !globalNewWindowHotkey.isEmpty { entries.insert("global:\(globalNewWindowHotkey)=new_window", at: 0) }
        if !globalHotkey.isEmpty { entries.insert("global:\(globalHotkey)=toggle_visibility", at: 0) }
        if !quickTerminalHotkey.isEmpty { entries.insert("global:\(quickTerminalHotkey)=toggle_quick_terminal", at: 0) }
        return Keybinds(entries: entries)
    }

    /// The theme for the current system appearance, with this config's color
    /// overrides applied.
    var resolvedTheme: Theme { resolvedTheme(dark: SystemAppearance.isDark) }

    func resolvedTheme(dark: Bool) -> Theme {
        var t = Theme.named(theme.name(dark: dark))
        if let background { t.background = background }
        if let foreground { t.foreground = foreground }
        if let cursorColor { t.cursor = cursorColor }
        if let selectionBackground { t.selection = selectionBackground }
        for (i, c) in palette where i < 16 { t.ansi[i] = c }
        return t
    }

    var padding: NSEdgeInsets {
        NSEdgeInsets(top: windowPaddingY, left: windowPaddingX, bottom: windowPaddingY + 2, right: windowPaddingX)
    }

    // MARK: Keys

    static let repeatable: Set<String> = ["palette", "keybind", "config-file", "font-feature"]

    /// Every key, in documentation order, with its help text.
    static let documentation: [(key: String, doc: String)] = [
        ("theme", "A theme name (libertty +list-themes), or light:NAME,dark:NAME to follow the system appearance."),
        ("font-family", "A monospaced font family (libertty +list-fonts). Empty: the bundled JetBrainsMono Nerd Font."),
        ("font-feature", "As in Ghostty: -calt (or -liga) turns programming ligatures (-> != ===) off. Repeatable."),
        ("font-size", "Points, 6–72."),
        ("background", "Override the theme's background (#rrggbb)."),
        ("foreground", "Override the theme's text color."),
        ("cursor-color", "Override the theme's cursor color."),
        ("selection-background", "Override the theme's selection color."),
        ("palette", "Override one palette entry: palette = N=#rrggbb, N in 0–255. Repeatable."),
        ("cursor-style", "block, bar, underline or block_hollow. Programs may still change it."),
        ("background-opacity", "0.1–1. Below 1 the window is translucent."),
        ("background-blur", "Blur what shows through a translucent window."),
        ("window-padding-x", "Points between the window's sides and the text."),
        ("window-padding-y", "Points above and below the text."),
        ("window-padding-color", "The padding's color: background, or extend (the edge cells' colors carried out to the pane's edges; not above or below a prompt, a row with default-colored cells or powerline glyphs, except in full-screen programs), or extend-always."),
        ("window-columns", "Width of new windows, in cells."),
        ("window-rows", "Height of new windows, in cells."),
        ("unfocused-split-opacity", "Opacity of the panes you're not typing in, 0.3–1."),
        ("tab-bar", "sidebar or top: list the tabs in the sidebar, or along the top of the window (the sidebar then shows the files)."),
        ("pane-headers", "never, split or always: when a pane shows a header with its program, folder and size, and buttons to float, zoom and close it."),
        ("scrollback-limit", "Bytes of scrollback per terminal, as in Ghostty (10000000 ≈ 10 MB, about 10 000 lines of 120 columns; idle history is compressed). Values under 100000 are taken as lines."),
        ("macos-option-as-alt", "false, true, left or right: which Option keys act as Alt (Meta) instead of typing characters."),
        ("copy-on-select", "Copy text to the clipboard as soon as it is selected."),
        ("confirm-close", "Ask before closing a pane or window with a running program."),
        ("command", "Run this instead of your login shell (through /bin/sh -c)."),
        ("working-directory", "Where new panes start: inherit (the focused pane's directory), home, or a path."),
        ("keybind", "TRIGGER=ACTION, e.g. cmd+d=new_split:right, ctrl+shift+c=copy_to_clipboard, cmd+k=unbind. "
            + "Prefix global: to make it work from any app. `clear` drops the defaults. Repeatable. "
            + "See libertty +list-keybinds and libertty +list-actions."),
        ("global-hotkey", "Show or hide Libertty from any app (shorthand for keybind = global:KEY=toggle_visibility)."),
        ("global-new-window-hotkey", "Open a new window from any app (shorthand for keybind = global:KEY=new_window)."),
        ("quit-after-last-window-closed", "Quit when the last window closes, instead of staying ready in the background."),
        ("window-sidebar", "Show the sidebar (tabs, and files of the focused pane's directory) in new windows."),
        ("window-inspector", "Show the inspector (directory, git, processes, ports) in new windows."),
        ("sidebar-show-hidden-files", "List dotfiles in the sidebar's file tree."),
        ("sidebar-files", "Show the file tree in the sidebar (the chevron on its header toggles this)."),
        ("window-vsync", "Wait for the display's refresh before showing a frame. false (default) cuts typing latency a lot (median 8.5 ms vs 30 ms at 120 Hz); full screen always syncs."),
        ("edit-source-files", "Open text and source files in the editor (⌘S saves); false shows them read-only. Markdown opens rendered either way; its source is the editor."),
        ("editor-keymap", "default or vim: the editor's keys."),
        ("browser-search", "The browser's search, %s standing for the words typed (default DuckDuckGo)."),
        ("jupyter", "The jupyter command notebooks run their cells with (default: the one on your login shell's PATH)."),
        ("browser-automation", "Let libertty +browser read and act in the browser's pages (text, html, eval, click, type, screenshot, url) — for scripts and agents. Off by default: a page may be one you're signed in to."),
        ("markdown-rendered", "Show Markdown files rendered; false shows their source (View ▸ Show Markdown Source toggles one)."),
        ("session-persistence", "Keep shells and programs running in liberttyd when Libertty quits (or crashes, or updates); the next launch shows them again. Closing a pane or window still ends it. Takes effect at the next launch."),
        ("desktop-notifications", "Show notifications programs ask for (OSC 9, OSC 777), and when a program reports it needs you (OSC 7501: approval, a question, sign-in) or finished, while you're elsewhere."),
        ("notify-on-command-finish", "never, unfocused or always: notify when a command that ran at least notify-on-command-finish-after ends (needs shell integration)."),
        ("notify-on-command-finish-after", "How long a command must run to be notified about: seconds, or with a unit (30s, 2m)."),
        ("program-status-indicator", "Which program states (OSC 7501) a tab and the window's subtitle show, comma-separated from idle, working, blocked (waiting for you), done and error; all (default) or none."),
        ("program-status-notify", "Which program states notify you while you're elsewhere (with desktop-notifications) and light the pane's edge. Default blocked,done,error."),
        ("program-status-dock-badge", "Which program states the Dock icon's badge counts. Default blocked."),
        ("agent-session-names", "Ask coding agents to name their session after their task (libertty +agent-setup installs what asks them); the tab shows the name."),
        ("program-status-sound", "Which program states play a sound as they begin while you're elsewhere: e.g. blocked:Ping,error:Basso,done — a state alone plays the alert sound; the names are macOS's sounds (System Settings ▸ Sound). A state with a sound here doesn't also sound its notification. Default none."),
        ("cursor-style-blink", "Whether the cursor blinks by default: empty (blinks, and programs may turn it off with DEC mode 12), true or false. Programs can still change it (DECSCUSR)."),
        ("focus-follows-mouse", "Give the keyboard to the pane under the pointer, without a click (as in Ghostty): from one terminal pane to another of the window in front."),
        ("wait-after-command", "Keep a pane open when its program ends, until a key is pressed in it (as in Ghostty). Off: only a program that fails at once keeps it (abnormal-command-exit-runtime)."),
        ("abnormal-command-exit-runtime", "Milliseconds: a program that fails (exits non-zero) sooner keeps its pane open with its error, until a key is pressed in it. 0 turns that off. Default 250."),
        ("undo-timeout", "How long Edit ▸ Undo (⌘Z) can bring back a closed pane, tab or window, programs still running: seconds or e.g. 30s; 0 ends them on close."),
        ("web-access", "Show this Mac's panes in a browser (Libertty ▸ Web Access…): off, local (this Mac only; reach it through ssh -L or Tailscale) or network (the local network too, plain HTTP). Every page needs the link's secret."),
        ("web-access-port", "The port Web Access listens on."),
        ("web-access-input", "Whether a browser may type into panes (false: watch only)."),
        ("mouse-hide-while-typing", "Hide the mouse pointer while you type; moving it brings it back."),
        ("scroll-smooth", "Trackpad scrolling follows your fingers point by point (true) or moves whole rows (false)."),
        ("bell-features", "What the bell (BEL) does, comma-separated, no- turns one off: system (the alert sound), attention (bounce the Dock icon), title (🔔 in the tab title until you look), border (flash the pane's edge). Default attention,title."),
        ("scrollbar", "system (an overlay scrollbar while scrolling, or when the pointer is at the right edge) or never."),
        ("auto-update", "check (default), download or off: look for a new Libertty once a day and offer it; download fetches and verifies it in the background, then waits for Restart to Update. Libertty ▸ Check for Updates… works either way."),
        ("quick-terminal-hotkey", "Drop the quick terminal down from any app, e.g. ctrl+grave_accent or alt+space (shorthand for keybind = global:KEY=toggle_quick_terminal). Window ▸ Quick Terminal works without one."),
        ("quick-terminal-position", "top, bottom, left, right or center: where the quick terminal comes from."),
        ("quick-terminal-size", "How much of the screen it covers: 0.2–1, or a percentage like 40%."),
        ("quick-terminal-autohide", "Put the quick terminal away when you click elsewhere."),
        ("term", "TERM for new shells: xterm-ghostty (default; Libertty ships its terminfo, since Libertty's terminal is Ghostty's) or any other name, e.g. xterm-256color."),
        ("ssh-env", "With term = xterm-ghostty, have ssh send TERM=xterm-256color, so hosts without Ghostty's terminfo still work (needs shell integration)."),
        ("clipboard-write", "allow or deny programs setting the clipboard (OSC 52; vim, tmux and remote shells use it)."),
        ("clipboard-read", "allow or deny programs reading the clipboard (OSC 52). Denied by default: anything you copied would be readable."),
        ("window-save-state", "default, never or always: reopen the windows, tabs and splits you had. With session-persistence the programs come back as they were; without, a new shell starts in each pane's last directory."),
        ("config-file", "Also load this file (relative to this one); a leading ? makes a missing file fine. Repeatable."),
    ]

    /// Current values in config syntax. Repeatable keys give one string per line.
    func values(of key: String) -> [String] {
        func color(_ c: RGB?) -> [String] { [c?.hexString ?? ""] }
        func num(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
        switch key {
        case "theme": return [theme.configString]
        case "font-family": return [fontFamily]
        case "font-feature": return fontFeatures
        case "font-size": return [num(fontSize)]
        case "background": return color(background)
        case "foreground": return color(foreground)
        case "cursor-color": return color(cursorColor)
        case "selection-background": return color(selectionBackground)
        case "palette": return palette.keys.sorted().map { "\($0)=\(palette[$0]!.hexString)" }
        case "cursor-style": return [cursorStyle.rawValue]
        case "background-opacity": return [num(backgroundOpacity)]
        case "background-blur": return [String(backgroundBlur)]
        case "window-padding-x": return [num(windowPaddingX)]
        case "window-padding-y": return [num(windowPaddingY)]
        case "window-padding-color": return [windowPaddingColor.rawValue]
        case "window-columns": return [String(windowColumns)]
        case "window-rows": return [String(windowRows)]
        case "unfocused-split-opacity": return [num(unfocusedSplitOpacity)]
        case "pane-headers": return [paneHeaders.rawValue]
        case "tab-bar": return [tabBar.rawValue]
        case "scrollback-limit": return [String(scrollbackLimit)]
        case "macos-option-as-alt": return [optionAsAlt.rawValue]
        case "copy-on-select": return [String(copyOnSelect)]
        case "confirm-close": return [String(confirmClose)]
        case "command": return [command]
        case "working-directory": return [workingDirectory]
        case "keybind": return keybinds
        case "global-hotkey": return [globalHotkey]
        case "global-new-window-hotkey": return [globalNewWindowHotkey]
        case "quit-after-last-window-closed": return [String(quitAfterLastWindowClosed)]
        case "window-sidebar": return [String(windowSidebar)]
        case "window-inspector": return [String(windowInspector)]
        case "sidebar-show-hidden-files": return [String(sidebarShowHiddenFiles)]
        case "sidebar-files": return [String(sidebarFiles)]
        case "markdown-rendered": return [String(markdownRendered)]
        case "edit-source-files": return [String(editSourceFiles)]
        case "editor-keymap": return [editorKeymap]
        case "browser-search": return [browserSearch]
        case "jupyter": return [jupyter]
        case "browser-automation": return [String(browserAutomation)]
        case "window-vsync": return [String(windowVsync)]
        case "session-persistence": return [String(sessionPersistence)]
        case "window-save-state": return [windowSaveState.rawValue]
        case "desktop-notifications": return [String(desktopNotifications)]
        case "notify-on-command-finish": return [notifyOnCommandFinish.rawValue]
        case "notify-on-command-finish-after": return [num(notifyOnCommandFinishAfter) + "s"]
        case "agent-session-names": return [String(agentSessionNames)]
        case "program-status-indicator": return [Self.statesString(programStatusIndicator)]
        case "program-status-notify": return [Self.statesString(programStatusNotify)]
        case "program-status-dock-badge": return [Self.statesString(programStatusDockBadge)]
        case "program-status-sound":
            return [ProgramStatusStore.State.named.compactMap { name, state in
                programStatusSound[state].map { $0.isEmpty ? name : "\(name):\($0)" }
            }.joined(separator: ",")]
        case "term": return [term]
        case "ssh-env": return [String(sshEnv)]
        case "cursor-style-blink": return [cursorStyleBlink.map(String.init) ?? ""]
        case "undo-timeout": return [num(undoTimeout) + "s"]
        case "wait-after-command": return [String(waitAfterCommand)]
        case "focus-follows-mouse": return [String(focusFollowsMouse)]
        case "abnormal-command-exit-runtime": return [String(abnormalCommandExitRuntime)]
        case "web-access": return [webAccess]
        case "web-access-port": return [String(webAccessPort)]
        case "web-access-input": return [String(webAccessInput)]
        case "mouse-hide-while-typing": return [String(mouseHideWhileTyping)]
        case "scroll-smooth": return [String(scrollSmooth)]
        case "bell-features": return [["system", "attention", "title", "border"].filter(bellFeatures.contains).joined(separator: ",")]
        case "scrollbar": return [scrollbar]
        case "auto-update": return [autoUpdate.rawValue]
        case "quick-terminal-hotkey": return [quickTerminalHotkey]
        case "quick-terminal-position": return [quickTerminalPosition.rawValue]
        case "quick-terminal-size": return [num(quickTerminalSize)]
        case "quick-terminal-autohide": return [String(quickTerminalAutohide)]
        case "clipboard-write": return [clipboardWrite ? "allow" : "deny"]
        case "clipboard-read": return [clipboardRead ? "allow" : "deny"]
        case "config-file": return []
        default: return []
        }
    }

    // MARK: Parsing

    struct Problem: Error { var message: String }

    /// "blocked,done", "all" or "none" → states.
    static func states(_ text: String) -> Result<Set<ProgramStatusStore.State>, Problem> {
        switch text.lowercased() {
        case "all": return .success(Set(ProgramStatusStore.State.allCases))
        case "none": return .success([])
        default: break
        }
        var states = Set<ProgramStatusStore.State>()
        for raw in text.split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            guard let state = ProgramStatusStore.State(name: name) else {
                return .failure(Problem(message: "unknown state “\(name)” (idle, working, blocked, done, error, all or none)"))
            }
            states.insert(state)
        }
        return .success(states)
    }

    static func statesString(_ states: Set<ProgramStatusStore.State>) -> String {
        if states.isEmpty { return "none" }
        if states.count == ProgramStatusStore.State.allCases.count { return "all" }
        return ProgramStatusStore.State.named.filter { states.contains($0.state) }.map(\.name).joined(separator: ",")
    }

    /// "10", "10s", "2m", "1h", "1m30s" → seconds.
    static func duration(_ text: String) -> Double? {
        if let n = Double(text), n >= 0 { return n }
        var total = 0.0, number = ""
        for ch in text {
            if ch.isNumber || ch == "." { number.append(ch); continue }
            guard let n = Double(number) else { return nil }
            switch ch {
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            number = ""
        }
        return number.isEmpty ? total : nil
    }

    /// Parse config text. Unknown keys and bad values are reported, not
    /// fatal. `config-file` lines are returned for the loader to follow.
    mutating func apply(_ text: String, source: String? = nil) -> (warnings: [String], includes: [String]) {
        var warnings: [String] = []
        var includes: [String] = []
        let prefix = source.map { "\($0): " } ?? ""
        for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else {
                warnings.append("\(prefix)line \(n + 1): expected key = value")
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if key == "config-file" {
                if !value.isEmpty { includes.append(value) }
                continue
            }
            if let problem = set(key, value) {
                warnings.append("\(prefix)line \(n + 1): \(key): \(problem)")
            }
        }
        return (warnings, includes)
    }

    static func parse(_ text: String) -> (Config, [String]) {
        var c = Config()
        let (warnings, _) = c.apply(text)
        return (c, warnings)
    }

    /// Load `url` and every `config-file` it pulls in (depth first, each
    /// once). Returns the files read, so the store can watch them.
    static func load(_ url: URL) -> (config: Config, warnings: [String], files: [URL]) {
        var config = Config()
        var warnings: [String] = []
        var files: [URL] = []
        var seen = Set<String>()
        func visit(_ file: URL, optional: Bool, label: String?) {
            let path = file.standardizedFileURL.path
            guard !seen.contains(path) else { return warnings.append("\(label ?? path): included more than once; skipped") }
            seen.insert(path)
            files.append(file)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                if !optional { warnings.append("\(label ?? path): can't read the file") }
                return
            }
            let (w, includes) = config.apply(text, source: label)
            warnings += w
            for spec in includes {
                var s = spec
                let optional = s.hasPrefix("?")
                if optional { s.removeFirst() }
                s = (s as NSString).expandingTildeInPath
                let target = s.hasPrefix("/") ? URL(fileURLWithPath: s)
                    : file.deletingLastPathComponent().appendingPathComponent(s)
                visit(target, optional: optional, label: (target.path as NSString).abbreviatingWithTildeInPath)
            }
        }
        visit(url, optional: true, label: nil)
        return (config, warnings, files)
    }

    /// Apply one key. Returns a problem description, or nil when accepted.
    /// An empty value resets the key to its default.
    mutating func set(_ key: String, _ v: String) -> String? {
        let defaults = Config()
        func double(_ range: ClosedRange<Double>) -> Double? { Double(v).map { min(range.upperBound, max(range.lowerBound, $0)) } }
        func int(_ range: ClosedRange<Int>) -> Int? { Int(v).map { min(range.upperBound, max(range.lowerBound, $0)) } }
        func bool() -> Bool? { ["true", "yes", "on", "1"].contains(v.lowercased()) ? true
            : ["false", "no", "off", "0"].contains(v.lowercased()) ? false : nil }
        func color() -> RGB?? { v.isEmpty ? .some(nil) : RGB(string: v).map { .some($0) } }
        let reset = v.isEmpty

        switch key {
        case "theme":
            if reset { theme = defaults.theme; return nil }
            guard let spec = ThemeSpec(v) else { return "expected a theme name or light:NAME,dark:NAME" }
            for name in Set([spec.light, spec.dark]) where !Theme.exists(name) {
                return "no theme named “\(name)” (libertty +list-themes)"
            }
            theme = spec
        case "font-family": fontFamily = v
        case "font-feature":
            if reset { fontFeatures = []; return nil }
            fontFeatures.append(v)
        case "font-size":
            if reset { fontSize = defaults.fontSize; return nil }
            guard let x = double(6...72) else { return "not a number" }; fontSize = x
        case "background": guard let x = color() else { return "not a color" }; background = x
        case "foreground": guard let x = color() else { return "not a color" }; foreground = x
        case "cursor-color": guard let x = color() else { return "not a color" }; cursorColor = x
        case "selection-background": guard let x = color() else { return "not a color" }; selectionBackground = x
        case "palette":
            if reset { palette = [:]; return nil }
            let parts = v.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let i = Int(parts[0]), (0..<256).contains(i), let c = RGB(string: parts[1]) else {
                return "expected N=#rrggbb"
            }
            palette[i] = c
        case "cursor-style":
            if reset { cursorStyle = defaults.cursorStyle; return nil }
            guard let x = CursorStyle(rawValue: v) else { return "block, bar, underline or block_hollow" }; cursorStyle = x
        case "background-opacity":
            if reset { backgroundOpacity = 1; return nil }
            guard let x = double(0.1...1) else { return "not a number" }; backgroundOpacity = x
        case "background-blur":
            if reset { backgroundBlur = defaults.backgroundBlur; return nil }
            guard let x = bool() else { return "true or false" }; backgroundBlur = x
        case "window-padding-x":
            if reset { windowPaddingX = defaults.windowPaddingX; return nil }
            guard let x = double(0...100) else { return "not a number" }; windowPaddingX = x
        case "window-padding-y":
            if reset { windowPaddingY = defaults.windowPaddingY; return nil }
            guard let x = double(0...100) else { return "not a number" }; windowPaddingY = x
        case "window-columns":
            if reset { windowColumns = defaults.windowColumns; return nil }
            guard let x = int(20...500) else { return "not a number" }; windowColumns = x
        case "window-rows":
            if reset { windowRows = defaults.windowRows; return nil }
            guard let x = int(5...300) else { return "not a number" }; windowRows = x
        case "pane-headers":
            if reset { paneHeaders = defaults.paneHeaders; return nil }
            guard let x = PaneHeaders(rawValue: v) else { return "never, split or always" }; paneHeaders = x
        case "tab-bar":
            if reset { tabBar = defaults.tabBar; return nil }
            guard let x = TabBar(rawValue: v) else { return "sidebar or top" }; tabBar = x
        case "unfocused-split-opacity":
            if reset { unfocusedSplitOpacity = defaults.unfocusedSplitOpacity; return nil }
            guard let x = double(0.3...1) else { return "not a number" }; unfocusedSplitOpacity = x
        case "scrollback-limit":
            if reset { scrollbackLimit = defaults.scrollbackLimit; return nil }
            guard let x = int(0...4_000_000_000) else { return "a number of bytes" }; scrollbackLimit = x
        case "macos-option-as-alt":
            if reset { optionAsAlt = defaults.optionAsAlt; return nil }
            guard let x = OptionAsAlt(rawValue: v) else { return "false, true, left or right" }; optionAsAlt = x
        case "copy-on-select":
            if reset { copyOnSelect = defaults.copyOnSelect; return nil }
            guard let x = bool() else { return "true or false" }; copyOnSelect = x
        case "confirm-close":
            if reset { confirmClose = defaults.confirmClose; return nil }
            guard let x = bool() else { return "true or false" }; confirmClose = x
        case "command": command = v
        case "working-directory": workingDirectory = v.isEmpty ? "inherit" : v
        case "keybind":
            if reset { keybinds = []; return nil }
            if let problem = Keybinds.validate(v) { return problem }
            keybinds.append(v)
        case "global-hotkey":
            guard v.isEmpty || Shortcut(v) != nil else { return "not a shortcut (e.g. ctrl+grave, cmd+shift+space)" }
            globalHotkey = v
        case "global-new-window-hotkey":
            guard v.isEmpty || Shortcut(v) != nil else { return "not a shortcut (e.g. ctrl+alt+t)" }
            globalNewWindowHotkey = v
        case "quit-after-last-window-closed":
            if reset { quitAfterLastWindowClosed = defaults.quitAfterLastWindowClosed; return nil }
            guard let x = bool() else { return "true or false" }; quitAfterLastWindowClosed = x
        case "window-sidebar":
            if reset { windowSidebar = defaults.windowSidebar; return nil }
            guard let x = bool() else { return "true or false" }; windowSidebar = x
        case "window-inspector":
            if reset { windowInspector = defaults.windowInspector; return nil }
            guard let x = bool() else { return "true or false" }; windowInspector = x
        case "sidebar-show-hidden-files":
            if reset { sidebarShowHiddenFiles = defaults.sidebarShowHiddenFiles; return nil }
            guard let x = bool() else { return "true or false" }; sidebarShowHiddenFiles = x
        case "sidebar-files":
            if reset { sidebarFiles = defaults.sidebarFiles; return nil }
            guard let x = bool() else { return "true or false" }; sidebarFiles = x
        case "window-vsync":
            if reset { windowVsync = defaults.windowVsync; return nil }
            guard let x = bool() else { return "true or false" }; windowVsync = x
        case "session-persistence":
            if reset { sessionPersistence = defaults.sessionPersistence; return nil }
            guard let x = bool() else { return "true or false" }; sessionPersistence = x
        case "window-save-state":
            if reset { windowSaveState = defaults.windowSaveState; return nil }
            guard let x = SaveState(rawValue: v) else { return "default, never or always" }; windowSaveState = x
        case "desktop-notifications":
            if reset { desktopNotifications = defaults.desktopNotifications; return nil }
            guard let x = bool() else { return "true or false" }; desktopNotifications = x
        case "notify-on-command-finish":
            if reset { notifyOnCommandFinish = defaults.notifyOnCommandFinish; return nil }
            guard let x = NotifyWhen(rawValue: v) else { return "never, unfocused or always" }; notifyOnCommandFinish = x
        case "notify-on-command-finish-after":
            if reset { notifyOnCommandFinishAfter = defaults.notifyOnCommandFinishAfter; return nil }
            guard let x = Self.duration(v) else { return "a duration like 10, 10s or 2m" }; notifyOnCommandFinishAfter = x
        case "agent-session-names":
            if reset { agentSessionNames = defaults.agentSessionNames; return nil }
            guard let x = bool() else { return "true or false" }; agentSessionNames = x
        case "program-status-indicator":
            if reset { programStatusIndicator = defaults.programStatusIndicator; return nil }
            switch Self.states(v) { case .success(let s): programStatusIndicator = s; case .failure(let why): return why.message }
        case "program-status-notify":
            if reset { programStatusNotify = defaults.programStatusNotify; return nil }
            switch Self.states(v) { case .success(let s): programStatusNotify = s; case .failure(let why): return why.message }
        case "program-status-dock-badge":
            if reset { programStatusDockBadge = defaults.programStatusDockBadge; return nil }
            switch Self.states(v) { case .success(let s): programStatusDockBadge = s; case .failure(let why): return why.message }
        case "program-status-sound":
            if reset || v.lowercased() == "none" { programStatusSound = [:]; return nil }
            var sounds: [ProgramStatusStore.State: String] = [:]
            for raw in v.split(separator: ",") {
                let item = raw.trimmingCharacters(in: .whitespaces)
                if item.isEmpty { continue }
                let parts = item.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard let state = ProgramStatusStore.State(name: parts[0]) else { return "unknown state “\(parts[0])”" }
                let sound = parts.count > 1 ? parts[1] : ""
                if !sound.isEmpty, NSSound(named: NSSound.Name(sound)) == nil { return "no sound named “\(sound)”" }
                sounds[state] = sound
            }
            programStatusSound = sounds
        case "term":
            if reset { term = defaults.term; return nil }
            guard v.allSatisfy({ $0.isLetter || $0.isNumber || "-._+".contains($0) }) else { return "a terminal type name like xterm-256color" }
            term = v
        case "ssh-env":
            if reset { sshEnv = defaults.sshEnv; return nil }
            guard let x = bool() else { return "true or false" }; sshEnv = x
        case "cursor-style-blink":
            if reset { cursorStyleBlink = nil; return nil }
            guard let x = bool() else { return "true, false or empty" }; cursorStyleBlink = x
        case "focus-follows-mouse":
            if reset { focusFollowsMouse = defaults.focusFollowsMouse; return nil }
            guard let x = bool() else { return "true or false" }; focusFollowsMouse = x
        case "wait-after-command":
            if reset { waitAfterCommand = defaults.waitAfterCommand; return nil }
            guard let x = bool() else { return "true or false" }; waitAfterCommand = x
        case "abnormal-command-exit-runtime":
            if reset { abnormalCommandExitRuntime = defaults.abnormalCommandExitRuntime; return nil }
            guard let x = int(0...60_000) else { return "milliseconds, 0 to 60000" }; abnormalCommandExitRuntime = x
        case "undo-timeout":
            if reset { undoTimeout = defaults.undoTimeout; return nil }
            guard let x = Self.duration(v) else { return "a duration like 5, 5s or 1m" }; undoTimeout = min(x, 3600)
        case "web-access":
            if reset { webAccess = defaults.webAccess; return nil }
            guard ["off", "local", "network"].contains(v) else { return "off, local or network" }; webAccess = v
        case "web-access-port":
            if reset { webAccessPort = defaults.webAccessPort; return nil }
            guard let x = Int(v), (1024...65535).contains(x) else { return "a port from 1024 to 65535" }; webAccessPort = x
        case "web-access-input":
            if reset { webAccessInput = defaults.webAccessInput; return nil }
            guard let x = bool() else { return "true or false" }; webAccessInput = x
        case "mouse-hide-while-typing":
            if reset { mouseHideWhileTyping = defaults.mouseHideWhileTyping; return nil }
            guard let x = bool() else { return "true or false" }; mouseHideWhileTyping = x
        case "scroll-smooth":
            if reset { scrollSmooth = defaults.scrollSmooth; return nil }
            guard let x = bool() else { return "true or false" }; scrollSmooth = x
        case "bell-features":
            if reset { bellFeatures = defaults.bellFeatures; return nil }
            var features = defaults.bellFeatures
            for raw in v.split(separator: ",") {
                let item = raw.trimmingCharacters(in: .whitespaces).lowercased()
                let name = item.hasPrefix("no-") ? String(item.dropFirst(3)) : item
                guard ["system", "audio", "attention", "title", "border"].contains(name) else { return "unknown bell feature “\(name)”" }
                if item.hasPrefix("no-") { features.remove(name) } else { features.insert(name) }
            }
            // A plain list (no no-) means exactly those.
            if !v.contains("no-") {
                features = Set(v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            }
            bellFeatures = features
        case "window-padding-color":
            if reset { windowPaddingColor = defaults.windowPaddingColor; return nil }
            guard let color = TerminalRenderer.PaddingColor(rawValue: v) else { return "background, extend or extend-always" }
            windowPaddingColor = color
        case "scrollbar":
            if reset { scrollbar = defaults.scrollbar; return nil }
            guard ["system", "never"].contains(v) else { return "system or never" }; scrollbar = v
        case "auto-update":
            if reset { autoUpdate = defaults.autoUpdate; return nil }
            guard let x = AutoUpdate(rawValue: v) else { return "off, check or download" }; autoUpdate = x
        case "quick-terminal-hotkey":
            guard v.isEmpty || Shortcut(v) != nil else { return "not a shortcut (e.g. ctrl+grave_accent)" }
            quickTerminalHotkey = v
        case "quick-terminal-position":
            if reset { quickTerminalPosition = defaults.quickTerminalPosition; return nil }
            guard let x = QuickPosition(rawValue: v) else { return "top, bottom, left, right or center" }; quickTerminalPosition = x
        case "quick-terminal-size":
            if reset { quickTerminalSize = defaults.quickTerminalSize; return nil }
            let text = v.hasSuffix("%") ? String(v.dropLast()) : v
            guard var x = Double(text) else { return "a fraction like 0.4 or a percentage like 40%" }
            if v.hasSuffix("%") || x > 1 { x /= 100 }
            quickTerminalSize = min(1, max(0.2, x))
        case "quick-terminal-autohide":
            if reset { quickTerminalAutohide = defaults.quickTerminalAutohide; return nil }
            guard let x = bool() else { return "true or false" }; quickTerminalAutohide = x
        case "clipboard-write", "clipboard-read":
            let isWrite = key == "clipboard-write"
            if reset {
                if isWrite { clipboardWrite = defaults.clipboardWrite } else { clipboardRead = defaults.clipboardRead }
                return nil
            }
            guard ["allow", "deny"].contains(v) else { return "allow or deny" }
            if isWrite { clipboardWrite = v == "allow" } else { clipboardRead = v == "allow" }
        case "markdown-rendered":
            if reset { markdownRendered = defaults.markdownRendered; return nil }
            guard let x = bool() else { return "true or false" }; markdownRendered = x
        case "edit-source-files":
            if reset { editSourceFiles = defaults.editSourceFiles; return nil }
            guard let x = bool() else { return "true or false" }; editSourceFiles = x
        case "editor-keymap":
            if reset { editorKeymap = defaults.editorKeymap; return nil }
            guard ["default", "vim"].contains(v) else { return "default or vim" }; editorKeymap = v
        case "jupyter":
            if reset { jupyter = defaults.jupyter; return nil }
            jupyter = (v as NSString).expandingTildeInPath
            return nil
        case "browser-search":
            if reset { browserSearch = defaults.browserSearch; return nil }
            guard v.contains("%s"), let u = URL(string: v.replacingOccurrences(of: "%s", with: "x")), ["http", "https"].contains(u.scheme ?? "") else {
                return "an http(s) address with %s for the words"
            }
            browserSearch = v
        case "browser-automation":
            if reset { browserAutomation = defaults.browserAutomation; return nil }
            guard let x = bool() else { return "true or false" }; browserAutomation = x
        default:
            return "unknown key (libertty +show-config --default lists them)"
        }
        return nil
    }

    /// What a new config file starts as (Ghostty's template, for Libertty): it
    /// sets nothing, since every option has a sensible default.
    static func template(path: String) -> String {
        """
        # This is the configuration file for Libertty.
        #
        # This template file has been automatically created at the following
        # path since Libertty couldn't find any existing config file:
        #
        #   \(path)
        #
        # The template does not set any default options, since Libertty ships
        # with sensible defaults for all options. Only set the options you
        # actually need.
        #
        # Run `libertty +show-config --default --docs` to view a list of
        # all available config options and their default values.
        # `libertty +list-themes`, `libertty +list-fonts`, `libertty +list-keybinds` and
        # `libertty +list-actions` list the values some options take.
        #
        # Libertty reloads this file as soon as it is saved. You can also reload
        # it from the menu or with the bound key (default: Command + Shift + comma).
        # Scripts can change it with `libertty +set key=value`.

        # Config syntax crash course
        # ==========================
        # # The config file consists of simple key-value pairs,
        # # separated by equals signs.
        # font-family = Menlo
        # window-padding-x = 2
        #
        # # Spacing around the equals sign does not matter.
        # # All of these are identical:
        # key=value
        # key= value
        # key =value
        # key = value
        #
        # # Any line beginning with a # is a comment. It's not possible to put
        # # a comment after a config option, since it would be interpreted as a
        # # part of the value. For example, this will have a value of "#123abc":
        # background = #123abc
        #
        # # Empty values are used to reset config keys to default.
        # key =
        #
        # # Some config options have unique syntaxes for their value,
        # # which is explained in the docs for that config option.
        # # Just for example:
        # keybind = cmd+shift+k=clear_screen
        # theme = light:Catppuccin Latte,dark:Catppuccin Mocha

        """
    }
}

/// Whether the system is in Dark Mode, also outside a running app (the CLI).
enum SystemAppearance {
    static var isDark: Bool {
        if let app = NSApp {
            return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}

/// Owns the live config: loads it (and its `config-file` includes), watches
/// the files, and notifies observers on the main thread when anything
/// changes. Settings and `libertty +set` write through `set`/`add`/`unset`,
/// which edit lines in place so comments and ordering survive.
final class ConfigStore {
    static let shared = ConfigStore()

    static var directory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        let current = base.appendingPathComponent("libertty")
        // Libertty was called Lumen: its settings stay where they were
        // until there are new ones (nothing is moved or rewritten).
        let earlier = base.appendingPathComponent("lumen")
        let fm = FileManager.default
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: earlier.appendingPathComponent("config").path) {
            return earlier
        }
        return current
    }

    private(set) var config = Config()
    private(set) var keybinds = Keybinds(entries: [])
    private(set) var warnings: [String] = []
    let url: URL

    private var observers: [UUID: (Config) -> Void] = [:]
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var watching = false
    private var lastFiles: [String: String] = [:]

    private init() {
        url = Self.directory.appendingPathComponent("config")
        reload()
    }

    var theme: Theme { config.resolvedTheme }

    /// Call `handler` now and on every change until the returned token is released.
    func observe(_ handler: @escaping (Config) -> Void) -> AnyObject {
        if !watching { watching = true; watchFiles() }
        let id = UUID()
        observers[id] = handler
        handler(config)
        return Token { [weak self] in self?.observers[id] = nil }
    }

    private final class Token {
        let cancel: () -> Void
        init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
        deinit { cancel() }
    }

    /// Re-read every file. Observers hear about it only when something
    /// changed, unless `force` (Reload Config, a system appearance change).
    func reload(force: Bool = false) {
        ThemeLibrary.shared.invalidate()
        let (parsed, problems, files) = Config.load(url)
        var contents: [String: String] = [:]
        for f in files { contents[f.path] = (try? String(contentsOf: f, encoding: .utf8)) ?? "" }
        let changed = contents != lastFiles || parsed != config || problems != warnings
        lastFiles = contents
        guard force || changed else { return }
        warnings = problems
        config = parsed
        keybinds = parsed.keybindTable
        if watching { watchFiles() }
        notify()
    }

    func notify() {
        for handler in observers.values { handler(config) }
    }

    // MARK: Editing the file

    /// Set `key` (replacing its line in place), or with nil remove it.
    /// For repeatable keys this replaces every line with one.
    func set(_ key: String, _ value: String?) {
        edit { lines in
            if let i = lines.firstIndex(where: { Self.key(of: $0) == key }) {
                if let value { lines[i] = "\(key) = \(value)" } else { lines.remove(at: i) }
                // A key set twice: the first now wins; drop the stale later ones.
                lines = lines.enumerated().filter { $0.offset <= i || Self.key(of: $0.element) != key }.map(\.element)
                if value == nil { lines.removeAll { Self.key(of: $0) == key } }
            } else if let value {
                Self.append("\(key) = \(value)", to: &lines)
            }
        }
    }

    /// Append another line for a repeatable key (`keybind`, `palette`).
    func add(_ key: String, _ value: String) {
        edit { lines in Self.append("\(key) = \(value)", to: &lines) }
    }

    /// Lines at the end of the file, a blank line before them (`+import-ghostty`).
    func appendBlock(_ block: [String]) {
        edit { lines in
            while lines.last == "" { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines += block
            lines.append("")
        }
    }

    /// The keys the file sets itself, and its lines of repeatable keys.
    var fileEntries: (keys: Set<String>, lines: Set<String>) {
        let lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        var keys = Set<String>(), repeated = Set<String>()
        for line in lines {
            guard let key = Self.key(of: line) else { continue }
            keys.insert(key)
            if Config.repeatable.contains(key) { repeated.insert("\(key) = \(Self.value(of: line))") }
        }
        return (keys, repeated)
    }

    /// Remove lines of `key`; for repeatable keys, only those whose value
    /// matches `where` when given.
    func unset(_ key: String, where match: ((String) -> Bool)? = nil) {
        edit { lines in
            lines.removeAll { line in
                guard Self.key(of: line) == key else { return false }
                return match.map { $0(Self.value(of: line)) } ?? true
            }
        }
    }

    /// Rebind `action` to `trigger` (nil: leave it unbound), keeping the
    /// file tidy: earlier user lines for the same trigger or action go.
    func rebind(_ action: Action, from old: Trigger?, to new: Trigger?) {
        edit { lines in
            lines.removeAll { line in
                guard Self.key(of: line) == "keybind", let (t, a, isGlobal) = Keybinds.parse(Self.value(of: line)),
                      !isGlobal else { return false }
                return t == old || t == new || a == action
            }
            if let old, Keybinds(entries: []).local.contains(where: { $0.trigger == old }) {
                Self.append("keybind = \(old.configString)=unbind", to: &lines)
            }
            if let new { Self.append("keybind = \(new.configString)=\(action.configString)", to: &lines) }
        }
    }

    /// Create the file from the commented template if it doesn't exist yet.
    func ensureFile() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        write(Config.template(path: url.path))
    }

    private func edit(_ change: (inout [String]) -> Void) {
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? Config.template(path: url.path))
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        change(&lines)
        write(lines.joined(separator: "\n"))
    }

    private static func append(_ line: String, to lines: inout [String]) {
        while lines.last == "" { lines.removeLast() }
        lines.append(line)
        lines.append("")
    }

    static func key(of line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        return t[..<eq].trimmingCharacters(in: .whitespaces)
    }

    static func value(of line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let eq = t.firstIndex(of: "=") else { return "" }
        return t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    }

    private func write(_ text: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        reload()
    }

    // MARK: Watching

    /// Watch the directories, not the files: editors save by replacing them.
    /// Includes elsewhere and the user themes folder are watched too.
    private func watchFiles() {
        var dirs = Set([url.deletingLastPathComponent().path, Self.directory.appendingPathComponent("themes").path])
        for path in lastFiles.keys { dirs.insert((path as NSString).deletingLastPathComponent) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for dir in dirs where watchers[dir] == nil {
            let fd = open(dir, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                                   queue: .main)
            var pending: DispatchWorkItem?
            source.setEventHandler { [weak self] in
                pending?.cancel()
                let work = DispatchWorkItem { self?.reload() }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers[dir] = source
        }
    }
}
