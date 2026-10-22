import AppKit
import LiberttyCore

/// ⌘⇧P (Ghostty's toggle_command_palette): type to find any command, a pane
/// of any window, a liberttyd session no window shows, or a theme; Return
/// runs it. ⌘P opens it on the panes alone (Go to Pane, after GoRex).
final class CommandPalette: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    /// What an item is: the scope chips and the section headings follow it.
    enum Kind: Equatable { case pane, folder, workspace, session, command, theme }

    struct Item {
        var title: String
        var subtitle: String = ""
        var symbol: String
        var shortcut: String = ""
        var kind: Kind = .command
        var run: () -> Void
    }

    /// The chips under the field (Tern's All / Commands / Files / Sessions…).
    enum Scope: CaseIterable {
        case all, panes, folders, commands, workspaces, sessions, themes
        var title: String {
            switch self {
            case .all: "All"
            case .panes: "Panes"
            case .folders: "Folders"
            case .commands: "Commands"
            case .workspaces: "Workspaces"
            case .sessions: "Sessions"
            case .themes: "Themes"
            }
        }
        func admits(_ kind: Kind) -> Bool {
            switch self {
            case .all: true
            case .panes: kind == .pane
            case .folders: kind == .folder
            case .commands: kind == .command
            case .workspaces: kind == .workspace
            case .sessions: kind == .session
            case .themes: kind == .theme
            }
        }
    }

    private enum Row {
        case group(String)
        case item(Item)
    }

    private static var current: CommandPalette?

    /// `scope`: the chip it opens on (Go to Directory: Folders).
    static func toggle(in controller: TerminalWindowController?, panesOnly: Bool = false, scope: Scope = .all) {
        if let open = current {
            open.close()
            // ⌘P with the commands open switches to the panes, and back
            // (whichever chip was picked since).
            if open.panesOnly == panesOnly, open.openedScope == scope { return }
        }
        guard let controller, let window = controller.window else { return }
        let palette = CommandPalette(controller: controller, parent: window, panesOnly: panesOnly, scope: scope)
        current = palette
        palette.show()
    }

    private weak var controller: TerminalWindowController?
    private weak var parent: NSWindow?
    private let panesOnly: Bool
    private let panel: QuickPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var all: [Item] = []
    private var shown: [Item] = []
    private var rows: [Row] = []
    private var scope = Scope.all
    /// The chip it opened on, which its shortcut toggles.
    private let openedScope: Scope
    /// The chips this window has: no Folders for a host's (they'd be that machine's).
    private var scopes: [Scope] {
        Scope.allCases.filter { $0 != .folders || controller?.host == nil }
    }
    private var chips: [(scope: Scope, button: ScopeChip)] = []
    private let searchIcon = NSImageView()
    private let topLine = NSView(), footerLine = NSView()
    private var footer: (hints: NSStackView, close: NSStackView)?
    private var topCap: KeyCap?
    private var dim: NSView?
    private var veilTint: NSView?
    private static let width: CGFloat = 640, itemHeight: CGFloat = 40, groupHeight: CGFloat = 32
    private static let topHeight: CGFloat = 54, chipsHeight: CGFloat = 34, footerHeight: CGFloat = 38
    private static let maxListHeight: CGFloat = 400

    private init(controller: TerminalWindowController, parent: NSWindow, panesOnly: Bool, scope: Scope) {
        self.controller = controller
        self.parent = parent
        self.panesOnly = panesOnly
        self.scope = panesOnly ? .all : scope
        openedScope = scope
        Self.lastListing = nil
        panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        all = panesOnly ? Self.panes(around: controller)
            : Self.panes(around: controller) + Self.folders(around: controller) + items()
        build()
        filter("")
    }

    // MARK: Contents

    /// Every pane of every window and of the quick terminal — terminals,
    /// documents beside them, document tabs — with its program (or name),
    /// its folder, and where it is. Picking one brings its window, tab and
    /// split forward. (Without the app's window list — a `--ui-probe` run —
    /// this window's.)
    private static func panes(around current: TerminalWindowController) -> [Item] {
        var windows = (NSApp.delegate as? AppDelegate)?.windowControllers ?? [current]
        let quick = QuickTerminal.shared.windowController
        if let quick, !windows.contains(where: { $0 === quick }) { windows.append(quick) }
        let named = windows.filter { $0 !== quick }.count > 1
        var out: [Item] = []
        for controller in windows {
            let isQuick = controller === quick
            let groups = controller.workspaceTabs
            let workspaceNames = controller.workspaceNames
            for (w, group) in groups.enumerated() {
              for (t, tab) in group.enumerated() {
                var place = !isQuick ? "Tab \(t + 1)" : group.count > 1 ? "Quick Terminal · Tab \(t + 1)" : "Quick Terminal"
                if groups.count > 1, !isQuick { place = workspaceNames[w] + " · " + place }
                // The name you gave the tab finds its panes too.
                if !tab.titleOverride.isEmpty { place += " · " + tab.titleOverride }
                if (tab.container?.views.count ?? 0) > 1 { place += " · split" }
                if named, !isQuick { place += " · " + (controller.window?.title ?? "") }
                func open(_ leaf: NSView?) -> () -> Void {
                    return { [weak controller, weak tab, weak leaf] in
                        guard let controller, let tab else { return }
                        if isQuick { QuickTerminal.shared.show() }
                        // Another window's pane brings Libertty's window forward too.
                        if controller.reveal(leaf, in: tab) { Probe.activateApp() }
                    }
                }
                if let doc = tab.document {
                    out.append(Item(title: doc.title, subtitle: place, symbol: symbol(of: doc), kind: .pane, run: open(nil)))
                    continue
                }
                for entry in tab.parked {
                    let pane = entry.pane
                    let label = controller.label(of: pane)
                    out.append(Item(title: label.name, subtitle: [label.detail, place, "parked"].filter { !$0.isEmpty }.joined(separator: " · "),
                                    symbol: "tray.and.arrow.down", kind: .pane) { [weak controller, weak tab, weak pane] in
                        guard let controller, let tab, let pane else { return }
                        if isQuick { QuickTerminal.shared.show() }
                        if controller.reveal(pane, in: tab) { Probe.activateApp() }
                    })
                }
                for leaf in tab.container?.views ?? [] {
                    if let pane = leaf as? TerminalView {
                        let label = controller.label(of: pane)
                        let subtitle = [label.detail, place].filter { !$0.isEmpty }.joined(separator: " · ")
                        out.append(Item(title: label.name, subtitle: subtitle, symbol: controller.symbol(of: pane),
                                        kind: .pane, run: open(pane)))
                    } else if let doc = leaf as? DocumentView {
                        out.append(Item(title: doc.title, subtitle: place, symbol: symbol(of: doc), kind: .pane, run: open(doc)))
                    }
                }
              }
            }
        }
        return out
    }

    private static func symbol(of doc: DocumentView) -> String { doc.symbol }

    private func items() -> [Item] {
        let keybinds = ConfigStore.shared.keybinds
        // The window it was opened over: the palette itself is gone by the
        // time an item runs.
        weak let controller = self.controller
        var out: [Item] = []
        func command(_ title: String, _ action: Action, _ symbol: String) {
            out.append(Item(title: title, symbol: symbol, shortcut: keybinds.trigger(for: action)?.displayString ?? "") {
                ActionDispatcher.perform(action, in: controller?.focusedTerminal, controller: controller)
            })
        }
        command("New Window", .newWindow, "macwindow.badge.plus")
        command("New Tab", .newTab, "plus.square")
        command("Split Right", .newSplit(.right), "rectangle.split.2x1")
        command("Split Down", .newSplit(.down), "rectangle.split.1x2")
        command("Split Left", .newSplit(.left), "rectangle.leadinghalf.inset.filled")
        command("Split Up", .newSplit(.up), "rectangle.tophalf.inset.filled")
        command("Close Pane", .closeSurface, "xmark")
        command("Close Tab", .closeTab, "xmark.square")
        command("Close Window", .closeWindow, "xmark.rectangle")
        command("Close All Windows", .closeAllWindows, "xmark.rectangle.portrait")
        command("Restart Shell in Pane", .restartSurface, "arrow.counterclockwise")
        command("Park Pane", .parkSurface, "tray.and.arrow.down")
        command("Unpark Pane", .unparkSurface, "tray.and.arrow.up")
        command("Float Pane", .floatSurface, "pip.enter")
        command("Move Pane to New Tab", .moveSurfaceToNewTab, "rectangle.portrait.and.arrow.right")
        command("Move Pane to New Window", .moveSurfaceToNewWindow, "macwindow.badge.plus")
        command("Move Tab to New Window", .moveTabToNewWindow, "uiwindow.split.2x1")
        // Each other tab the focused pane could join.
        for (i, tab) in (controller?.tabs ?? []).enumerated() where controller?.canMoveFocusedPane(toTab: i + 1) == true {
            command("Move Pane to Tab \(i + 1): \(controller?.label(of: tab).name ?? "")", .moveSurfaceToTab(i + 1),
                    "rectangle.portrait.and.arrow.right")
        }
        command("Git", .openGit, "arrow.triangle.branch")
        command("Browser", .openBrowser, "globe")
        command("Tasks", .openTasks, "gauge.with.dots.needle.33percent")
        command("New Canvas", .newCanvas, CanvasBlock.symbol)
        command("Profiler", .openProfiler, ProfilerBlock.symbol)
        command("Board", .openBoard, BoardBlock.symbol)
        command("Plugins", .openPlugins, PluginsBlock.symbol)
        command("Screen", .openScreen, ScreenShareBlock.symbol)
        // What the plugins that run offer.
        PluginHost.shared.start()
        for c in PluginHost.shared.commands {
            out.append(Item(title: "\(c.plugin.title): \(c.title)", symbol: PluginsBlock.symbol) { c.plugin.runCommand(c.title) })
        }
        command("New Workspace…", .newWorkspace, "square.stack.3d.up")
        command("Rename Workspace…", .renameWorkspace, "pencil")
        command("Close Workspace", .closeWorkspace, "xmark.square")
        command("Next Workspace", .nextWorkspace, "chevron.right.2")
        command("Previous Workspace", .previousWorkspace, "chevron.left.2")
        command("Go to Pane…", .gotoPane, "rectangle.3.group")
        command("Go to Directory…", .gotoDirectory, "folder")
        // The sidebar's activity filter, and back to every tab.
        // (Not the one it shows: show_tabs again would undo it.)
        if let shown = controller?.sidebarActivity {
            for (activity, title) in [(TabActivity.working, "Working Tabs"), (.waiting, "Tabs Waiting for You"),
                                      (.attention, "Finished or Failed Tabs"), (.all, "All Tabs")] where activity != shown {
                command("Sidebar: \(title)", .showTabs(activity), "line.3.horizontal.decrease.circle")
            }
        }
        command("Zoom Split", .toggleSplitZoom, "arrow.up.left.and.arrow.down.right")
        command("Equalize Splits", .equalizeSplits, "square.split.2x2")
        command("Next Pane", .gotoSplit(.next), "arrow.right.square")
        command("Previous Pane", .gotoSplit(.previous), "arrow.left.square")
        command("Select Split Left", .gotoSplit(.direction(.left)), "arrow.left")
        command("Select Split Right", .gotoSplit(.direction(.right)), "arrow.right")
        command("Select Split Above", .gotoSplit(.direction(.up)), "arrow.up")
        command("Select Split Below", .gotoSplit(.direction(.down)), "arrow.down")
        command("Move Divider Left", .resizeSplit(.left, 10), "arrow.left.to.line")
        command("Move Divider Right", .resizeSplit(.right, 10), "arrow.right.to.line")
        command("Move Divider Up", .resizeSplit(.up, 10), "arrow.up.to.line")
        command("Move Divider Down", .resizeSplit(.down, 10), "arrow.down.to.line")
        command("Show All Tabs", .toggleTabOverview, "square.grid.2x2")
        command("Next Tab", .nextTab, "chevron.right")
        command("Previous Tab", .previousTab, "chevron.left")
        command("Find…", .startSearch, "magnifyingglass")
        command("Find Selection", .searchSelection, "text.magnifyingglass")
        command("Copy", .copyToClipboard, "doc.on.doc")
        command("Copy Output of Last Command", .copyCommandOutput, "text.append")
        command("Broadcast Input to All Panes", .toggleBroadcastInput, "dot.radiowaves.left.and.right")
        command("Export Text As…", .writeScrollbackFile("save"), "square.and.arrow.up")
        command("Open Scrollback in Tab", .writeScrollbackFile("open"), "doc.text")
        command("Paste", .pasteFromClipboard, "doc.on.clipboard")
        command("Select All", .selectAll, "selection.pin.in.out")
        command("Clear Screen and Scrollback", .clearScreen, "clear")
        command("Undo Close", .undo, "arrow.uturn.backward")
        command("Scroll to Top", .scrollToTop, "arrow.up.to.line")
        command("Scroll to Bottom", .scrollToBottom, "arrow.down.to.line")
        command("Previous Prompt", .jumpToPrompt(-1), "chevron.up")
        command("Next Prompt", .jumpToPrompt(1), "chevron.down")
        command("Bigger Text", .increaseFontSize(1), "textformat.size.larger")
        command("Smaller Text", .decreaseFontSize(1), "textformat.size.smaller")
        command("Actual Size", .resetFontSize, "textformat.size")
        command("Change Terminal Title…", .promptSurfaceTitle, "character.cursor.ibeam")
        command("Change Tab Title…", .promptTabTitle, "character.cursor.ibeam")
        command("Terminal Read-only", .toggleReadonly, "lock")
        command("Show/Hide Sidebar", .toggleSidebar, "sidebar.left")
        command("Show/Hide Inspector", .toggleInspector, "sidebar.right")
        command("Show Markdown Source", .toggleMarkdownSource, "doc.plaintext")
        command("Quick Terminal", .toggleQuickTerminal, "rectangle.topthird.inset.filled")
        command("Connect to Host…", .connectToHost, "network")
        command("Picture in Picture", .togglePictureInPicture, "pip")
        command("Toggle Full Screen", .toggleFullscreen, "arrow.up.left.and.arrow.down.right.rectangle")
        command("Float on Top", .toggleWindowFloatOnTop, "pin")
        command("Return to Default Size", .resetWindowSize, "arrow.down.right.and.arrow.up.left")
        command("Secure Keyboard Entry", .toggleSecureInput, "lock.display")
        command("Settings…", .openConfig, "gear")
        command("Reload Configuration", .reloadConfig, "arrow.clockwise")
        command("Show/Hide All Terminals", .toggleVisibility, "eye")

        // Workspaces of this window: pick one to show it.
        if let controller, controller.workspaceNames.count > 1 {
            let counts = controller.workspaceTabs.map(\.count)
            for (i, name) in controller.workspaceNames.enumerated() {
                let current = i == controller.activeWorkspace
                out.append(Item(title: name, subtitle: "\(counts[i]) tab\(counts[i] == 1 ? "" : "s")" + (current ? " · current" : ""),
                                symbol: current ? "checkmark" : "square.stack.3d.up", kind: .workspace) {
                    controller.switchWorkspace(to: i)
                })
            }
        }
        // (Panes come first, from `panes()`: tabs are reached through them.)
        // Sessions liberttyd keeps that no window shows.
        if Persistence.enabled, let sessions = DaemonClient.sessions() {
            for s in sessions where s.clients == 0 {
                let dir = SessionInfo.directory(fromPwd: s.workingDirectory).map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
                out.append(Item(title: "Show Session \(s.id)", subtitle: [s.title, dir].filter { !$0.isEmpty }.joined(separator: " · "),
                                symbol: "rectangle.stack", kind: .session) { controller?.attachTab(s.id) })
            }
        }
        // Themes: built-in, ~/.config/libertty/themes, and Ghostty's.
        var names = Theme.all.map(\.name)
        let known = Set(names.map { $0.lowercased() })
        names += ThemeLibrary.shared.entries.map(\.name).filter { !known.contains($0.lowercased()) }
        for name in names {
            out.append(Item(title: "Theme: \(name)", symbol: "paintpalette", kind: .theme) {
                ConfigStore.shared.set("theme", name.contains(",") ? "\"\(name)\"" : name)
            })
        }
        return out
    }

    // MARK: Folders (Go to Directory, after Rex)

    /// The folders a new tab could start in: where this Mac's panes are, then
    /// where its shells have been lately. A host's window has none (they're
    /// that machine's, not this Mac's).
    private static func folders(around current: TerminalWindowController) -> [Item] {
        guard current.host == nil else { return [] }
        let windows = (NSApp.delegate as? AppDelegate)?.windowControllers ?? [current]
        var seen = Set<String>(), out: [Item] = []
        let here = windows.filter { $0.host == nil }.flatMap(\.workingDirectories)
        for path in here + RecentFolders.shared.paths where seen.insert(path).inserted {
            out.append(folderItem(path, subtitle: here.contains(path) ? "a pane is here" : "recent", in: current))
        }
        return out
    }

    /// A folder's entries, the last one asked for kept (typing a path asks
    /// again at every key).
    private static func listing(of folder: String) -> [(name: String, isDirectory: Bool)] {
        if let last = lastListing, last.folder == folder { return last.entries }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: folder, isDirectory: true), includingPropertiesForKeys: Array(keys))) ?? []
        let entries = urls.map { url -> (name: String, isDirectory: Bool) in
            let values = try? url.resourceValues(forKeys: keys)
            // A link to a folder is one too.
            var isDirectory = values?.isDirectory == true
            if values?.isSymbolicLink == true {
                var followed: ObjCBool = false
                isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &followed) && followed.boolValue
            }
            return (url.lastPathComponent, isDirectory)
        }
        lastListing = (folder, entries)
        return entries
    }
    private static var lastListing: (folder: String, entries: [(name: String, isDirectory: Bool)])?

    private static func folderItem(_ path: String, subtitle: String, in controller: TerminalWindowController) -> Item {
        Item(title: (path as NSString).abbreviatingWithTildeInPath, subtitle: subtitle, symbol: "folder", kind: .folder) {
            [weak controller] in
            controller?.newTab(workingDirectory: path)
        }
    }

    /// A path being typed (`/`, `~`): the folders it could go on to.
    private func typedFolders(_ query: String) -> [Item] {
        guard let controller, controller.host == nil, query.hasPrefix("/") || query.hasPrefix("~") else { return [] }
        let expanded = (query as NSString).expandingTildeInPath
        let (parent, prefix) = expanded.hasSuffix("/")
            ? (expanded, "") : ((expanded as NSString).deletingLastPathComponent, (expanded as NSString).lastPathComponent)
        var out: [Item] = []
        // The folder typed, first ("~/src/" too, before what's in it).
        var isDirectory: ObjCBool = false
        let itself = expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
        if FileManager.default.fileExists(atPath: itself, isDirectory: &isDirectory), isDirectory.boolValue {
            out.append(Self.folderItem(itself, subtitle: "new tab here", in: controller))
        }
        // Then the folders in its parent that it could go on to. The listing
        // is the parent's once while typing in it: a folder may hold many.
        let entries = Self.listing(of: parent)
        let lower = prefix.lowercased()
        let names = entries.filter { $0.name.lowercased().hasPrefix(lower) && $0.name.lowercased() != lower
            && (prefix.hasPrefix(".") || !$0.name.hasPrefix(".")) && $0.isDirectory }.map(\.name)
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).prefix(30) {
            out.append(Self.folderItem((parent as NSString).appendingPathComponent(name), subtitle: "new tab here", in: controller))
        }
        return out
    }

    // MARK: Matching

    /// Fuzzy match: every typed character in order. Consecutive runs and
    /// word starts score higher; nil if it doesn't match.
    static func score(_ query: String, _ text: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        var qi = 0, score = 0, run = 0
        for (i, c) in t.enumerated() where qi < q.count {
            guard c == q[qi] else { run = 0; continue }
            let wordStart = i == 0 || !t[i - 1].isLetter && !t[i - 1].isNumber
            score += 1 + run * 3 + (wordStart ? 8 : 0) + (i == qi ? 4 : 0)
            run += 1
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score - t.count / 8
    }

    private func filter(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        let inScope = all.filter { scope.admits($0.kind) }
        if q.isEmpty {
            // Themes and folders only when asked for (their chip, or a search): there are many.
            shown = inScope.filter { (scope == .themes || $0.kind != .theme) && (scope == .folders || $0.kind != .folder) }
        } else {
            // A path being typed lists where it leads first (not in Go to Pane).
            let typed = scope.admits(.folder) && !panesOnly ? typedFolders(q) : []
            let typedTitles = Set(typed.map(\.title))
            shown = typed + inScope.filter { $0.kind != .folder || !typedTitles.contains($0.title) }
                .compactMap { item in Self.score(q, item.title + " " + item.subtitle).map { (item, $0) } }
                .sorted { $0.1 > $1.1 }.prefix(60).map(\.0)
        }
        // Sections (Panes, Sessions, Commands…) when browsing; a search
        // lists by how well things match, with no headings between.
        rows = []
        let sectioned = q.isEmpty && !panesOnly && scope == .all
        var last: Kind?
        for item in shown {
            if sectioned, item.kind != last { rows.append(.group(Self.heading(item.kind))) }
            last = item.kind
            rows.append(.item(item))
        }
        noMatches = shown.isEmpty
        noMatchesText = q.isEmpty ? "Nothing here" : "No matches"
        table.reloadData()
        // The quiet "No matches" row is never the one Return would run.
        if let first = rows.firstIndex(where: { if case .item = $0 { true } else { false } }) {
            table.selectRowIndexes([first], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        } else {
            table.deselectAll(nil)
        }
        layout()
    }

    private static func heading(_ kind: Kind) -> String {
        switch kind {
        case .pane: "Panes"
        case .folder: "Folders"
        case .workspace: "Workspaces"
        case .session: "Sessions"
        case .command: "Commands"
        case .theme: "Themes"
        }
    }

    /// Nothing to list: one quiet row says so, rather than the palette
    /// shrinking to the field.
    private var noMatches = false
    private var noMatchesText = "No matches"

    private func setScope(_ new: Scope) {
        guard new != scope else { return }
        scope = new
        for (s, button) in chips { button.isOn = s == new }
        filter(field.stringValue)
    }

    private func cycleScope(_ delta: Int) {
        guard !panesOnly else { return }
        let all = scopes
        let i = all.firstIndex(of: scope) ?? 0
        setScope(all[(i + delta + all.count) % all.count])
    }

    // MARK: Panel

    private func build() {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Radius.panel - 2
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        searchIcon.contentTintColor = .secondaryLabelColor
        effect.addSubview(searchIcon)

        field.placeholderString = panesOnly ? "Go to a pane: type its program, folder or tab"
            : "Run a command or go to a pane…"
        field.font = Typeface.ui(16)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        effect.addSubview(field)
        let esc = KeyCap("esc", mono: true)
        effect.addSubview(esc)
        topCap = esc

        for line in [topLine, footerLine] {
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor.separatorColor.cgColor
            effect.addSubview(line)
        }

        if !panesOnly {
            for s in scopes {
                let chip = ScopeChip(s.title)
                chip.isOn = s == scope
                chip.onClick = { [weak self] in self?.setScope(s) }
                effect.addSubview(chip)
                chips.append((s, chip))
            }
        }

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.floatsGroupRows = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        effect.addSubview(scroll)

        let hints = NSStackView(views: [
            KeyCap("↑"), KeyCap("↓"), Self.hint("navigate"), KeyCap("↵"), Self.hint("run"),
        ])
        hints.spacing = 6
        hints.setCustomSpacing(12, after: hints.views[2])
        let close = NSStackView(views: [KeyCap("esc", mono: true), Self.hint("close")])
        close.spacing = 6
        for bar in [hints, close] {
            bar.alignment = .centerY
            effect.addSubview(bar)
        }
        footer = (hints, close)
    }

    private static func hint(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Typeface.secondary
        label.textColor = .secondaryLabelColor
        return label
    }

    private var listHeight: CGFloat {
        let content = noMatches ? Self.itemHeight : rows.reduce(0) { sum, row in
            if case .group = row { sum + Self.groupHeight } else { sum + Self.itemHeight }
        }
        return min(Self.maxListHeight, content)
    }

    private func layout() {
        guard let parent else { return }
        let width = min(Self.width, parent.frame.width - 40)
        let list = listHeight
        let chipsH = chips.isEmpty ? 0 : Self.chipsHeight
        let height = Self.topHeight + chipsH + (list > 0 ? list + 12 : 0) + Self.footerHeight
        let content = parent.contentLayoutRect
        let top = parent.frame.minY + content.maxY - 12
        let frame = NSRect(x: parent.frame.midX - width / 2, y: top - height, width: width, height: height)
        panel.setFrame(frame, display: true)

        let topY = height - Self.topHeight
        searchIcon.frame = NSRect(x: 18, y: topY + (Self.topHeight - 20) / 2, width: 20, height: 20)
        if let cap = topCap {
            let size = cap.intrinsicContentSize
            cap.frame = NSRect(x: width - 16 - size.width, y: topY + (Self.topHeight - size.height) / 2,
                               width: size.width, height: size.height)
        }
        field.frame = NSRect(x: 48, y: topY + (Self.topHeight - 24) / 2, width: width - 48 - 70, height: 24)
        topLine.frame = NSRect(x: 0, y: topY, width: width, height: 1)

        var x: CGFloat = 10
        for (_, chip) in chips {
            let size = chip.intrinsicContentSize
            chip.frame = NSRect(x: x, y: topY - chipsH + (chipsH - size.height) / 2 - 1, width: size.width, height: size.height)
            x += size.width + 2
        }

        footerLine.frame = NSRect(x: 0, y: Self.footerHeight, width: width, height: 1)
        if let (hints, close) = footer {
            let h = hints.fittingSize, c = close.fittingSize
            hints.frame = NSRect(x: 16, y: (Self.footerHeight - h.height) / 2, width: h.width, height: h.height)
            close.frame = NSRect(x: width - 16 - c.width, y: (Self.footerHeight - c.height) / 2, width: c.width, height: c.height)
        }
        scroll.frame = NSRect(x: 0, y: Self.footerHeight + 6, width: width, height: max(0, list))
        table.tableColumns.first?.width = scroll.contentSize.width
    }

    private func show() {
        guard let parent else { return }
        // Libertty comes forward first: the palette must never take the keyboard
        // from another app (as it would, asked for from a script while you type elsewhere).
        Probe.activateApp()
        parent.makeKeyAndOrderFront(nil)
        // Its blur and text follow the window's light or dark, not the system's.
        panel.appearance = parent.appearance
        // Mostly opaque over the blur (Tern's 0.98): readable on any desktop.
        let dark = parent.appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tint = dark ? NSColor(srgbRed: 40 / 255, green: 43 / 255, blue: 52 / 255, alpha: 0.92)
            : NSColor(white: 1, alpha: 0.92)
        // (A plain view: the blur view draws over its own layer's color.)
        if let effect = panel.contentView, veilTint == nil {
            let layer = NSView(frame: effect.bounds)
            layer.autoresizingMask = [.width, .height]
            layer.wantsLayer = true
            effect.addSubview(layer, positioned: .below, relativeTo: nil)
            veilTint = layer
        }
        veilTint?.layer?.backgroundColor = tint.cgColor
        // The window recedes behind it.
        if let frame = parent.contentView?.superview {
            let veil = PaletteVeil(frame: frame.bounds)
            veil.autoresizingMask = [.width, .height]
            frame.addSubview(veil, positioned: .above, relativeTo: nil)
            dim = veil
        }
        parent.addChildWindow(panel, ordered: .above)
        layout()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// `refocus`: the window it was opened over takes the keyboard back (Esc,
    /// Return, toggling it); not when the keyboard went elsewhere on its own,
    /// to another window or app, which keeps it.
    private func close(refocus: Bool = true) {
        guard Self.current === self else { return }
        Self.current = nil
        dim?.removeFromSuperview()
        dim = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if refocus, let controller { controller.window?.makeKeyAndOrderFront(nil) }
    }

    private func runSelected() {
        let row = table.selectedRow
        guard rows.indices.contains(row), case .item(let item) = rows[row] else { return }
        close()
        // After the palette is gone, so the action sees the real focus.
        DispatchQueue.main.async { item.run() }
    }

    @objc private func clicked(_ sender: Any?) { runSelected() }

    /// The palette's panel, while one is open (`--ui-probe` types into it).
    static var openPanel: NSWindow? { current?.panel }
    /// The rows it shows now, as "title · subtitle" (`--ui-probe` checks them).
    static var shownRows: [String]? {
        guard let current else { return nil }
        if current.noMatches { return [current.noMatchesText] }
        return current.shown.map { $0.subtitle.isEmpty ? $0.title : "\($0.title) · \($0.subtitle)" }
    }
    /// The chips and which one is on (`--ui-probe`).
    static var shownScopes: [String]? {
        guard let current else { return nil }
        return current.chips.map { ($0.button.isOn ? "[\($0.scope.title)]" : $0.scope.title) }
    }

    func windowDidResignKey(_ notification: Notification) {
        // A probe's app is never active, so its panel never stays key.
        guard !Probe.running else { return }
        close(refocus: false)
    }

    // MARK: Field

    func controlTextDidChange(_ obj: Notification) { filter(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        // Tab walks the chips: All, Panes, Commands…
        case #selector(NSResponder.insertTab(_:)): cycleScope(1)
        case #selector(NSResponder.insertBacktab(_:)): cycleScope(-1)
        default: return false
        }
        return true
    }

    /// To the next row that can run (headings are skipped), wrapping around.
    private func move(_ delta: Int) {
        let selectable = rows.indices.filter { if case .item = rows[$0] { true } else { false } }
        guard !selectable.isEmpty else { return }
        let at = selectable.firstIndex(of: table.selectedRow) ?? 0
        let row = selectable[(at + delta + selectable.count) % selectable.count]
        table.selectRowIndexes([row], byExtendingSelection: false)
        // The heading above the first row belongs in view with it.
        table.scrollRowToVisible(row == selectable.first ? 0 : row)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { noMatches ? 1 : rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if !noMatches, rows.indices.contains(row), case .group = rows[row] { return Self.groupHeight }
        return Self.itemHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if noMatches {
            let cell = tableView.makeView(withIdentifier: PaletteCell.identifier, owner: nil) as? PaletteCell ?? PaletteCell()
            cell.show(Item(title: noMatchesText, symbol: "magnifyingglass") {}, dim: true)
            return cell
        }
        switch rows[row] {
        case .group(let title):
            let cell = tableView.makeView(withIdentifier: PaletteGroupCell.identifier, owner: nil) as? PaletteGroupCell ?? PaletteGroupCell()
            cell.title.stringValue = title
            return cell
        case .item(let item):
            let cell = tableView.makeView(withIdentifier: PaletteCell.identifier, owner: nil) as? PaletteCell ?? PaletteCell()
            cell.show(item)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard !noMatches, rows.indices.contains(row), case .item = rows[row] else { return false }
        return true
    }

    // The row under the pointer is the one Return would run: hovering
    // selects it, as menus do.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = HoverRowView()
        view.onHover = { [weak self, weak tableView] in
            guard let self, let tableView, !self.noMatches, self.rows.indices.contains(row),
                  case .item = self.rows[row] else { return }
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        return view
    }
}

/// The window behind the palette, dimmed (Tern's scrim). It lets every
/// click through: the palette closes when it loses the keyboard.
private final class PaletteVeil: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A scope chip under the field: the one on is a tinted pill in the accent.
private final class ScopeChip: NSView {
    var onClick: (() -> Void)?
    var isOn = false { didSet { update() } }
    private let label: NSTextField

    init(_ title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        label.font = Typeface.ui(12, .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.intrinsicContentSize.width) + 20, height: 24) }

    private func update() {
        label.textColor = isOn ? .controlAccentColor : .secondaryLabelColor
        layer?.backgroundColor = (isOn ? NSColor.controlAccentColor.withAlphaComponent(0.16) : .clear).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// A key drawn as a key: a small rounded cap with its legend (Tern's kbd).
final class KeyCap: NSView {
    private let label: NSTextField

    init(_ text: String, mono: Bool = false) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 0.5
        label.font = mono ? .monospacedSystemFont(ofSize: 10.5, weight: .medium) : .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(19, ceil(label.intrinsicContentSize.width) + 10), height: 19)
    }

    private func updateColors() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// "⌘⇧P" as caps: each modifier its own, the key (a name or a glyph) last.
    static func caps(for shortcut: String) -> [KeyCap] {
        let modifiers = Set("⌘⇧⌥⌃")
        var out: [KeyCap] = []
        var rest = Substring(shortcut)
        while let c = rest.first, modifiers.contains(c) {
            out.append(KeyCap(String(c)))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { out.append(KeyCap(String(rest))) }
        return out
    }
}

/// A row: the selected one is a lifted bar with a mark at its edge.
private final class HoverRowView: NSTableRowView {
    var onHover: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(new)
        area = new
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }

    override func drawSelection(in dirtyRect: NSRect) {
        let bar = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: Radius.control, yRadius: Radius.control)
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        bar.fill()
        // Tern's accent mark at the bar's left edge.
        let mark = NSBezierPath(roundedRect: NSRect(x: 8, y: bounds.midY - 8, width: 2.5, height: 16), xRadius: 1.25, yRadius: 1.25)
        NSColor.controlAccentColor.setFill()
        mark.fill()
    }

    override var isEmphasized: Bool { get { false } set {} }
}

private final class PaletteGroupCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PaletteGroupCell")
    let title = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = Typeface.ui(11.5, .medium)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class PaletteCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PaletteCell")
    private let tile = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let keys = NSStackView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 7
        icon.symbolConfiguration = .init(pointSize: 12.5, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.font = Typeface.row
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = Typeface.hint
        subtitle.textColor = .tertiaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        keys.spacing = 3
        for v in [tile, icon, title, subtitle, keys] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keys.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 26), tile.heightAnchor.constraint(equalToConstant: 26),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            subtitle.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -10),
            keys.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateColors() {
        tile.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func show(_ item: CommandPalette.Item, dim: Bool = false) {
        icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        title.stringValue = item.title
        title.textColor = dim ? .secondaryLabelColor : .labelColor
        subtitle.stringValue = item.subtitle
        keys.arrangedSubviews.forEach { keys.removeArrangedSubview($0); $0.removeFromSuperview() }
        KeyCap.caps(for: item.shortcut).forEach { keys.addArrangedSubview($0) }
    }
}
