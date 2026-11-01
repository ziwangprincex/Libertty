import Foundation

/// The Settings window's pages, in its sidebar's order (Rex's Settings:
/// the server, then the look, then the rest, then the developer's).
enum SettingsPage: String, CaseIterable, Identifiable {
    case liberttyd, interface, themes, terminal, shortcuts, integrations, notifications, remoteHosts, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liberttyd: "liberttyd"
        case .interface: "Interface"
        case .themes: "Themes"
        case .terminal: "Terminal"
        case .shortcuts: "Shortcuts"
        case .integrations: "Integrations"
        case .notifications: "Notifications"
        case .remoteHosts: "Remote Hosts"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .liberttyd: "server.rack"
        case .interface: "macwindow"
        case .themes: "paintpalette.fill"
        case .terminal: "apple.terminal.fill"
        case .shortcuts: "command"
        case .integrations: "puzzlepiece.extension.fill"
        case .notifications: "bell.badge.fill"
        case .remoteHosts: "globe"
        case .advanced: "hammer.fill"
        }
    }

    /// The sidebar's groups, a gap between each.
    var group: Int {
        switch self {
        case .liberttyd: 0
        case .interface, .themes: 1
        case .terminal, .shortcuts, .integrations, .notifications, .remoteHosts: 2
        case .advanced: 3
        }
    }

    /// A page by its title or name, any case (the UI probe's `settings:page:`).
    init?(named name: String) {
        guard let page = Self.allCases.first(where: {
            $0.title.caseInsensitiveCompare(name) == .orderedSame || $0.rawValue.caseInsensitiveCompare(name) == .orderedSame
        }) else { return nil }
        self = page
    }
}

/// One choice of a segmented control, pop-up or tiles: what it says and the
/// config value it writes.
struct SettingsOption: Hashable {
    var label: String
    var value: String
    var symbol: String? = nil
    /// Other values that mean this choice (`window-theme = system` is Auto).
    var also: [String] = []
}

/// One control of the Settings window, as data: where it is, what it says,
/// the config keys it edits and how. Search finds controls here, and the
/// unit tests check every key and value against `Config`.
struct SettingsItem: Identifiable {
    enum Kind {
        /// A switch: on writes `on`, off writes `off`; it's on unless the value is `off`.
        case toggle(on: String, off: String)
        case segmented([SettingsOption])
        case popup([SettingsOption])
        /// Pictures to pick from (Rex's Color scheme and Interface style).
        case tiles([SettingsOption])
        case slider(ClosedRange<Double>, step: Double, percent: Bool)
        case stepper(ClosedRange<Double>, step: Double, unit: String)
        case text(placeholder: String)
        /// Drawn by its page: the theme cards, the font chooser, a shortcut
        /// recorder, a program state's row… (`id` says which).
        case custom
    }

    var page: SettingsPage
    var section: String
    var title: String
    var help = ""
    /// The config keys it edits; the first is the one its value is read from.
    var keys: [String] = []
    var kind = Kind.custom
    /// Unique: a single key's control is called by its key.
    var id = ""
    /// More words Search finds it by.
    var keywords = ""

    var key: String? { keys.first }

    /// The choices of a segmented control, pop-up or tiles.
    var options: [SettingsOption] {
        switch kind {
        case .segmented(let options), .popup(let options), .tiles(let options): options
        default: []
        }
    }

    /// Every value it can write, by key (for the tests: each must be accepted).
    var values: [(key: String, value: String)] {
        guard let key else { return [] }
        switch kind {
        case .toggle(let on, let off): return [(key, on), (key, off)]
        case .segmented(let options), .popup(let options), .tiles(let options): return options.map { (key, $0.value) }
        case .slider(let range, _, _), .stepper(let range, _, _):
            return [(key, Self.number(range.lowerBound)), (key, Self.number(range.upperBound))]
        case .text, .custom: return []
        }
    }

    static func number(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%g", d)
    }
}

/// Every control of the Settings window, page by page, section by section.
enum SettingsRegistry {
    private static func item(_ page: SettingsPage, _ section: String, _ title: String, _ key: String, _ kind: SettingsItem.Kind,
                             help: String = "", keywords: String = "", id: String? = nil) -> SettingsItem {
        SettingsItem(page: page, section: section, title: title, help: help, keys: [key], kind: kind, id: id ?? key, keywords: keywords)
    }

    private static func custom(_ page: SettingsPage, _ section: String, _ title: String, id: String, keys: [String] = [],
                               help: String = "", keywords: String = "") -> SettingsItem {
        SettingsItem(page: page, section: section, title: title, help: help, keys: keys, kind: .custom, id: id, keywords: keywords)
    }

    private static func bool(_ page: SettingsPage, _ section: String, _ title: String, _ key: String,
                             help: String = "", keywords: String = "") -> SettingsItem {
        item(page, section, title, key, .toggle(on: "true", off: "false"), help: help, keywords: keywords)
    }

    private static func options(_ list: [(String, String)]) -> [SettingsOption] {
        list.map { SettingsOption(label: $0.0, value: $0.1) }
    }

    /// The program states Notifications lists, each with a page of its own.
    static let programStates: [ProgramStatusStore.State] = [.working, .blocked, .error, .done]

    /// The bell's features, as `bell-features` names them.
    static let bellFeatures: [(name: String, title: String)] = [
        ("system", "Play the alert sound"), ("attention", "Bounce the Dock icon"),
        ("title", "Show 🔔 in the tab's title"), ("border", "Flash the pane's edge"),
    ]

    static let items: [SettingsItem] = {
        var all: [SettingsItem] = []

        // liberttyd (Rex's Server)
        all += [
            custom(.liberttyd, "", "liberttyd", id: "daemon", keywords: "server daemon sessions running"),
            item(.liberttyd, "Web Access", "Web Access", "web-access", .popup(options([
                ("Off", "off"), ("This Mac only", "local"), ("This Mac and the local network", "network"),
                ("My tailnet (Tailscale, HTTPS)", "tailscale"),
            ])), help: "Show this Mac's panes in a browser; every page needs the link's secret.", keywords: "browser phone remote"),
            item(.liberttyd, "Web Access", "Port", "web-access-port", .text(placeholder: "7682")),
            bool(.liberttyd, "Web Access", "Allow typing from the browser", "web-access-input"),
            custom(.liberttyd, "Web Access", "Link and QR code", id: "web-access-link", keywords: "qr code url"),
        ]

        // Interface
        all += [
            item(.interface, "Appearance", "Color scheme", "window-theme", .tiles([
                SettingsOption(label: "Auto", value: "auto", also: ["system"]),
                SettingsOption(label: "Light", value: "light"), SettingsOption(label: "Dark", value: "dark"),
            ]), keywords: "light dark appearance mode"),
            item(.interface, "Appearance", "Interface style", "interface-style", .tiles(options([("Classic", "classic"), ("Glass", "glass")])),
                 keywords: "glass translucent blur"),
            bool(.interface, "Appearance", "Tint with theme", "interface-tint", help: "Glass takes the theme's color."),
            item(.interface, "Tabs", "Tab style", "tab-bar", .segmented([
                SettingsOption(label: "Above", value: "top", symbol: "rectangle.topthird.inset.filled"),
                SettingsOption(label: "Left Side", value: "left", symbol: "sidebar.left", also: ["sidebar"]),
                SettingsOption(label: "Right Side", value: "right", symbol: "sidebar.right"),
            ]), keywords: "tab bar sidebar vertical"),
            bool(.interface, "Tabs", "Fill available space", "tab-fill", help: "Tabs above share the bar's whole width."),
            item(.interface, "Tabs", "Show tab icons", "tab-icons", .slider(0...5, step: 1, percent: false),
                 help: "How many of a tab's programs show as icons on it."),
            bool(.interface, "Tabs", "Use color for tab icons", "tab-icon-color"),
            item(.interface, "Panes", "Pane style", "pane-style", .segmented(options([("Comfortable", "comfortable"), ("Compact", "compact")]))),
            item(.interface, "Panes", "Show pane headers", "pane-headers", .popup(options([("Never", "never"), ("In Splits", "split"), ("Always", "always")])),
                 help: "A pane's program, folder and size, with buttons to float, zoom and close it."),
            item(.interface, "Panes", "Match program backgrounds", "window-padding-color", .toggle(on: "extend", off: "background"),
                 help: "Color a pane's edges with the background a full-screen program such as an editor paints.", id: "match-program-backgrounds"),
            bool(.interface, "Panes", "Autobalance splits", "split-autobalance", help: "The panes even out after every split, close and move."),
            bool(.interface, "Panes", "Fade inactive panes", "inactive-pane-fade"),
            item(.interface, "Panes", "Inactive pane opacity", "unfocused-split-opacity", .slider(0.3...1, step: 0.05, percent: true),
                 keywords: "unfocused dim"),
            bool(.interface, "Panes", "Focus follows mouse", "focus-follows-mouse", help: "The pane under the pointer gets the keyboard, without a click."),
            bool(.interface, "Sidebar", "Show the sidebar in new windows", "window-sidebar"),
            bool(.interface, "Sidebar", "Show files in the sidebar", "sidebar-files", keywords: "file tree"),
            item(.interface, "Animation", "Animation style", "animation", .segmented(options([("Snappy", "snappy"), ("Natural", "natural"), ("Off", "off")])),
                 keywords: "motion"),
        ]

        // Themes
        all += [
            custom(.themes, "Light Mode", "Light Mode theme", id: "themes-light", keys: ["theme"], keywords: "color scheme"),
            custom(.themes, "Dark Mode", "Dark Mode theme", id: "themes-dark", keys: ["theme"], keywords: "color scheme"),
            bool(.themes, "Extended Palette", "Use extended theme palette", "palette-generate",
                 help: "Make colors 16–255 from the theme's own; off, they're xterm's standard set.", keywords: "256 colors"),
            custom(.themes, "Import Theme", "Import a Ghostty or iTerm theme file", id: "theme-import", keywords: "itermcolors"),
        ]

        // Terminal
        all += [
            custom(.terminal, "Typography", "Preview", id: "font-preview"),
            custom(.terminal, "Typography", "Terminal font", id: "font-family", keys: ["font-family"], keywords: "typeface"),
            item(.terminal, "Typography", "Font size", "font-size", .stepper(6...72, step: 1, unit: "pt"), keywords: "text size"),
            item(.terminal, "Typography", "Line height", "adjust-cell-height", .popup([SettingsOption(label: "The font's own", value: "")]
                + ["-10%", "-5%", "5%", "10%", "15%", "20%", "25%", "30%", "40%", "50%"].map {
                    SettingsOption(label: $0.hasPrefix("-") ? "\($0) shorter" : "+\($0) taller", value: $0)
                }), keywords: "cell height spacing"),
            custom(.terminal, "Typography", "Ligatures", id: "ligatures", keys: ["font-feature"], help: "Programming ligatures such as -> != ===.",
                   keywords: "calt liga"),
            item(.terminal, "Colors", "Minimum text contrast", "minimum-contrast", .popup(options([
                ("Off", "1"), ("1.1 · no invisible text", "1.1"), ("3 · easy to read", "3"), ("4.5 · WCAG AA", "4.5"), ("7 · WCAG AAA", "7"),
            ])), help: "Text that reads worse than this against its background is drawn white or black.", keywords: "improve readable"),
            item(.terminal, "Cursor", "Cursor style", "cursor-style", .popup(options([
                ("Block", "block"), ("Bar", "bar"), ("Underline", "underline"), ("Hollow Block", "block_hollow"),
            ]))),
            item(.terminal, "Cursor", "Blinking", "cursor-style-blink", .popup(options([("As programs ask", ""), ("Blink", "true"), ("Steady", "false")])),
                 keywords: "cursor blink"),
            item(.terminal, "Keyboard", "Option key", "macos-option-as-alt", .popup(options([
                ("Types characters", "false"), ("Acts as Alt", "true"), ("Left Option is Alt", "left"), ("Right Option is Alt", "right"),
            ])), help: "Which Option keys act as Alt (Meta) instead of typing accents and symbols.", keywords: "meta alt"),
            bool(.terminal, "Scrolling", "Smooth scrolling", "scroll-smooth", help: "Trackpad scrolling follows your fingers point by point."),
            item(.terminal, "Padding", "Padding color", "window-padding-color", .popup(options([
                ("Background", "background"), ("Extend", "extend"), ("Extend Always", "extend-always"),
            ])), help: "Background uses the pane's background. Extend carries the edge cells' colors out to the pane's edges."),
            item(.terminal, "Padding", "Horizontal padding", "window-padding-x", .stepper(0...100, step: 1, unit: "pt")),
            item(.terminal, "Padding", "Vertical padding", "window-padding-y", .stepper(0...100, step: 1, unit: "pt")),
            bool(.terminal, "Selection", "Copy on selection", "copy-on-select"),
            item(.terminal, "Clipboard", "Programs may set the clipboard", "clipboard-write", .toggle(on: "allow", off: "deny"),
                 help: "OSC 52: vim, tmux and remote shells use it.", keywords: "osc 52 copy"),
            item(.terminal, "Clipboard", "Programs may read the clipboard", "clipboard-read", .toggle(on: "allow", off: "deny"),
                 help: "Off by default: anything you copied would be readable.", keywords: "osc 52 paste"),
            item(.terminal, "Shell", "Startup command", "command", .text(placeholder: "Your login shell"),
                 help: "Run this instead of your login shell (through /bin/sh -c).", keywords: "shell program"),
            item(.terminal, "Shell", "Working directory", "working-directory", .text(placeholder: "inherit"),
                 help: "Where new panes start: inherit (the focused pane's folder), home, or a path.", keywords: "folder cwd"),
            item(.terminal, "Shell", "TERM", "term", .text(placeholder: "xterm-ghostty"), keywords: "terminfo"),
            item(.terminal, "Shell", "Scrollback", "scrollback-limit", .popup(options([
                ("1 MB", "1000000"), ("10 MB", "10000000"), ("50 MB", "50000000"), ("100 MB", "100000000"), ("500 MB", "500000000"),
            ])), help: "History kept per terminal; 10 MB is about 10 000 lines of 120 columns.", keywords: "history lines"),
            bool(.terminal, "Shell", "Confirm before closing a running program", "confirm-close", keywords: "quit close ask"),
        ]

        // Shortcuts: one recorder per action, then the keys that work from any app.
        for group in SettingsShortcuts.groups {
            for entry in group.actions {
                all.append(custom(.shortcuts, group.title, entry.title, id: "shortcut:" + entry.action, keys: ["keybind"],
                                  keywords: entry.action.replacingOccurrences(of: "_", with: " ")))
            }
        }
        all += [
            custom(.shortcuts, "From Any App", "Show or hide Libertty", id: "global-hotkey", keys: ["global-hotkey"], keywords: "global hotkey"),
            custom(.shortcuts, "From Any App", "New window", id: "global-new-window-hotkey", keys: ["global-new-window-hotkey"], keywords: "global hotkey"),
            custom(.shortcuts, "From Any App", "Quick terminal", id: "quick-terminal-hotkey", keys: ["quick-terminal-hotkey"], keywords: "global hotkey dropdown"),
            item(.shortcuts, "Quick Terminal", "Comes from", "quick-terminal-position", .popup(options([
                ("Top", "top"), ("Bottom", "bottom"), ("Left", "left"), ("Right", "right"), ("Center", "center"),
            ])), keywords: "quick terminal position"),
            item(.shortcuts, "Quick Terminal", "Size", "quick-terminal-size", .slider(0.2...1, step: 0.05, percent: true), keywords: "quick terminal"),
            bool(.shortcuts, "Quick Terminal", "Put it away when you click elsewhere", "quick-terminal-autohide", keywords: "quick terminal hide"),
        ]

        // Integrations
        all += [
            custom(.integrations, "Coding Agents", "Integrate with available agents", id: "agent-setup",
                   help: "Installs a Libertty skill and session hooks for Claude Code and Codex.", keywords: "claude codex hooks skill"),
            bool(.integrations, "Coding Agents", "Let agents name sessions", "agent-session-names",
                 help: "The tab shows the name an agent gives its task.", keywords: "claude codex"),
        ]

        // Notifications
        all += [
            bool(.notifications, "System Notifications", "Terminal notifications", "desktop-notifications",
                 help: "Programs can send notifications with OSC 9 or OSC 777, and say when they need you.", keywords: "osc alerts"),
        ]
        for state in programStates {
            all.append(custom(.notifications, "Program Activity", state.title, id: "program-state:\(state.name)",
                              keys: ["program-status-indicator", "program-status-notify", "program-status-dock-badge", "program-status-sound"],
                              keywords: "agent status osc 7501 dock badge sound"))
        }
        all += [
            item(.notifications, "Long-Running Commands", "Notify when a command finishes", "notify-on-command-finish", .popup(options([
                ("Never", "never"), ("When Libertty isn't in front", "unfocused"), ("Always", "always"),
            ])), help: "Needs shell integration.", keywords: "done finished"),
            item(.notifications, "Long-Running Commands", "After running for", "notify-on-command-finish-after", .popup(options([
                ("5 seconds", "5s"), ("10 seconds", "10s"), ("30 seconds", "30s"), ("1 minute", "60s"), ("5 minutes", "300s"),
            ]))),
        ]
        for feature in bellFeatures {
            all.append(custom(.notifications, "Bell", feature.title, id: "bell:\(feature.name)", keys: ["bell-features"], keywords: "bell beep bel"))
        }

        // Remote Hosts
        all.append(custom(.remoteHosts, "", "Remote Hosts", id: "remote-hosts", keywords: "ssh connect host server"))

        // Advanced (Rex's Developer)
        all += [
            custom(.advanced, "Configuration", "Config file", id: "config-file", keywords: "open reload edit text"),
            item(.advanced, "Updates", "Updates", "auto-update", .popup(options([
                ("Check and offer", "check"), ("Download in the background", "download"), ("Off", "off"),
            ])), keywords: "update version"),
            bool(.advanced, "Sessions", "Keep sessions running in liberttyd", "session-persistence",
                 help: "Programs keep running when Libertty quits, crashes or updates. Takes effect at the next launch.", keywords: "persist daemon"),
            item(.advanced, "Sessions", "Reopen windows", "window-save-state", .popup(options([
                ("As macOS says", "default"), ("Never", "never"), ("Always", "always"),
            ])), keywords: "restore layout"),
            bool(.advanced, "Rendering", "Sync to the display", "window-vsync",
                 help: "Never tears, but types up to two frames later.", keywords: "vsync latency"),
        ]
        return all
    }()

    static func items(on page: SettingsPage) -> [SettingsItem] { items.filter { $0.page == page } }

    static func item(_ id: String) -> SettingsItem? { items.first { $0.id == id } }

    /// What Search shows for `query`: titles that start with it first, then
    /// titles, help and keywords that contain it; pages whose name matches too.
    static func search(_ query: String) -> [SettingsItem] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        func haystack(_ item: SettingsItem) -> String {
            [item.title, item.section, item.help, item.keywords, item.page.title, item.keys.joined(separator: " ")]
                .joined(separator: " ").lowercased()
        }
        let found = items.filter { item in words.allSatisfy(haystack(item).contains) }
        let first = words[0]
        let prefixed = found.filter { $0.title.lowercased().hasPrefix(first) }
        return prefixed + found.filter { !$0.title.lowercased().hasPrefix(first) }
    }
}

extension ProgramStatusStore.State {
    /// As the Settings window says it.
    var title: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .blocked: "Blocked"
        case .error: "Error"
        case .done: "Done"
        }
    }
}

/// The actions the Shortcuts page lists, by group, with the names the menus
/// give them.
enum SettingsShortcuts {
    struct Entry { var title: String; var action: String }
    struct Group { var title: String; var actions: [Entry] }

    private static func e(_ title: String, _ action: String) -> Entry { Entry(title: title, action: action) }

    static let groups: [Group] = [
        Group(title: "Window", actions: [
            e("New Window", "new_window"), e("Close Window", "close_window"), e("Close All Windows", "close_all_windows"),
            e("Toggle Full Screen", "toggle_fullscreen"), e("Float on Top", "toggle_window_float_on_top"),
            e("Return to Default Size", "reset_window_size"), e("Show/Hide All Terminals", "toggle_visibility"),
            e("Show/Hide Sidebar", "toggle_sidebar"), e("Show/Hide Inspector", "toggle_inspector"),
            e("Picture in Picture", "toggle_picture_in_picture"),
        ]),
        Group(title: "App", actions: [
            e("Command Palette…", "toggle_command_palette"), e("Settings…", "open_settings"), e("Open Config File", "open_config"),
            e("Reload Configuration", "reload_config"), e("Theme Editor…", "open_theme_editor"),
            e("Connect to Host…", "connect_to_host"), e("Quick Terminal", "toggle_quick_terminal"),
            e("Secure Keyboard Entry", "toggle_secure_input"), e("Quit Libertty", "quit"),
        ]),
        Group(title: "Tabs", actions: [
            e("New Tab", "new_tab"), e("Close Tab", "close_tab"), e("Show Previous Tab", "previous_tab"), e("Show Next Tab", "next_tab"),
            e("Show Last Tab", "last_tab"),
        ] + (1...8).map { e("Show Tab \($0)", "goto_tab:\($0)") } + [
            e("Show All Tabs", "toggle_tab_overview"), e("Change Tab Title…", "prompt_tab_title"),
            e("Move Tab to New Window", "move_tab_to_new_window"), e("Go to Directory…", "go_to_directory"),
        ]),
        Group(title: "Panes", actions: [
            e("Split Right", "new_split:right"), e("Split Left", "new_split:left"), e("Split Down", "new_split:down"),
            e("Split Up", "new_split:up"), e("Split Best Fit", "new_split:auto"), e("Close", "close_surface"),
            e("Select Previous Split", "goto_split:previous"), e("Select Next Split", "goto_split:next"),
            e("Select Split Above", "goto_split:up"), e("Select Split Below", "goto_split:down"),
            e("Select Split Left", "goto_split:left"), e("Select Split Right", "goto_split:right"),
            e("Move Divider Up", "resize_split:up,10"), e("Move Divider Down", "resize_split:down,10"),
            e("Move Divider Left", "resize_split:left,10"), e("Move Divider Right", "resize_split:right,10"),
            e("Equalize Splits", "equalize_splits"), e("Zoom Split", "toggle_split_zoom"), e("Go to Pane…", "goto_pane"),
            e("Restart Shell in Pane", "restart_surface"), e("Park Pane", "park_surface"), e("Unpark Pane", "unpark_surface"),
            e("Float Pane", "float_surface"), e("Move Pane to New Tab", "move_surface_to_new_tab"),
            e("Move Pane to New Window", "move_surface_to_new_window"), e("Broadcast Input to All Panes", "toggle_broadcast_input"),
            e("Bring Back Closed Pane", "undo"), e("Close It Again", "redo"),
        ]),
        Group(title: "Text", actions: [
            e("Copy", "copy_to_clipboard"), e("Paste", "paste_from_clipboard"), e("Select All", "select_all"),
            e("Clear Screen", "clear_screen"), e("Copy Output of Last Command", "copy_command_output"),
            e("Increase Font Size", "increase_font_size:1"), e("Decrease Font Size", "decrease_font_size:1"),
            e("Reset Font Size", "reset_font_size"), e("Change Terminal Title…", "prompt_surface_title"),
            e("Terminal Read-only", "toggle_readonly"), e("Export Text As…", "write_scrollback_file:save"),
            e("Open Scrollback in Tab", "write_scrollback_file:open"),
        ]),
        Group(title: "Scrolling", actions: [
            e("Scroll to Top", "scroll_to_top"), e("Scroll to Bottom", "scroll_to_bottom"),
            e("Scroll Page Up", "scroll_page_up"), e("Scroll Page Down", "scroll_page_down"),
            e("Jump to Previous Prompt", "jump_to_prompt:-1"), e("Jump to Next Prompt", "jump_to_prompt:1"),
        ]),
        Group(title: "Find", actions: [
            e("Find…", "start_search"), e("Find Next", "navigate_search:next"), e("Find Previous", "navigate_search:previous"),
            e("Hide Find Bar", "end_search"), e("Use Selection for Find", "search_selection"),
        ]),
        Group(title: "Workspaces", actions: [
            e("New Workspace…", "new_workspace"), e("Rename Workspace…", "rename_workspace"), e("Close Workspace", "close_workspace"),
            e("Show Next Workspace", "next_workspace"), e("Show Previous Workspace", "previous_workspace"),
        ]),
        Group(title: "Documents and Tools", actions: [
            e("Show Markdown Source", "toggle_markdown_source"), e("Edit Document", "toggle_editor"),
            e("Git", "open_git"), e("Browser", "open_browser"), e("Browser Address Bar", "focus_address"), e("Tasks", "open_tasks"),
            e("New Canvas", "new_canvas"), e("Profiler", "open_profiler"), e("Board", "open_board"), e("Plugins", "open_plugins"),
            e("Screen", "open_screen"),
        ]),
    ]
}
