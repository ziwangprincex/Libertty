import AppKit
import LiberttyCore

/// One tab of a window: a tree of split panes, each with its own session,
/// or a document (a Markdown or source file opened from the sidebar).
final class TerminalTab {
    let container: SplitContainerView?
    let document: DocumentView?
    var focusedPane: TerminalView?
    /// A document pane of the split that had the focus last (nil when a
    /// terminal has it): what focus goes back to, and what ⌘F searches.
    var focusedDocument: DocumentView?
    /// Set with Change Tab Title; empty means the focused program's title.
    var titleOverride = ""
    /// Set with Change Terminal Title.
    var paneTitleOverride = ""
    /// A pane rang the bell and you haven't looked yet (`bell-features = title`).
    var rang = false
    /// Broadcast Input: typing in one pane types in all of them.
    var broadcasting = false

    init(pane: TerminalView) {
        container = SplitContainerView(pane: pane)
        document = nil
        focusedPane = pane
    }

    init(root: PaneNode, focused: NSView?) {
        container = SplitContainerView(root: root)
        document = nil
        focusedPane = focused as? TerminalView ?? root.leaves.lazy.compactMap { $0 as? TerminalView }.first
        focusedDocument = focused as? DocumentView
    }

    /// Which workspace a saved tab belongs to, and whether it was its
    /// workspace's front tab (read once, when the window is built from a saved layout).
    var restoredWorkspace: String?
    var restoredSelected = false

    /// Documents shown as panes beside the terminals.
    var documentPanes: [DocumentView] { container?.views.compactMap { $0 as? DocumentView } ?? [] }

    init(document: DocumentView) {
        container = nil
        self.document = document
    }

    var panes: [TerminalView] { container?.panes ?? [] }

    /// A pane taken out of the split but still running (park): where it
    /// stood, for putting it back.
    struct Parked {
        let pane: TerminalView
        weak var anchor: NSView?
        let side: SplitContainerView.Direction
        /// Shown live in a corner of the split (in-window picture in picture).
        var showsCard = false
        var cardCorner: String?
    }
    /// Parked panes, the latest last. Their programs keep running; nothing draws them.
    var parked: [Parked] = []
    /// The panes shown and the ones parked: every program the tab runs.
    var everyPane: [TerminalView] { panes + parked.map(\.pane) }

    /// The panes in the order they last had the focus, latest first: where
    /// focus goes back to when the focused pane closes (GoRex).
    private var recent: [ObjectIdentifier] = []

    func noteFocus(_ pane: TerminalView) {
        recent.removeAll { $0 == ObjectIdentifier(pane) }
        recent.insert(ObjectIdentifier(pane), at: 0)
    }

    /// The pane focused most recently, other than `pane`, that's still here.
    func previouslyFocused(besides pane: TerminalView) -> TerminalView? {
        let here = panes
        recent.removeAll { id in !here.contains { ObjectIdentifier($0) == id } }
        for id in recent where id != ObjectIdentifier(pane) {
            if let p = here.first(where: { ObjectIdentifier($0) == id }) { return p }
        }
        return nil
    }
    /// The focused pane of the split, a terminal or a document.
    var focusedLeaf: NSView? { focusedDocument ?? focusedPane }
    /// What takes the keyboard when this tab comes forward.
    var focusTarget: NSView? { focusedDocument?.focusTarget ?? focusedPane ?? document?.focusTarget }
    var isTerminal: Bool { container != nil }
    /// What the middle column shows.
    var content: NSView { container ?? document! }
}

/// A terminal window. A `--ui-probe`'s stays off every screen: AppKit
/// would move a titled window back onto one (onto the built-in display's
/// corner, say), there for the user to see.
final class TerminalWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        Probe.running ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// One terminal window, laid out like Tern and Otty: tabs and files in a
/// sidebar, the selected tab's panes in the middle, an inspector on the
/// right, and the common actions in the toolbar.
final class TerminalWindowController: NSWindowController, NSWindowDelegate, TerminalSessionDelegate, NSToolbarDelegate {
    var tabs: [TerminalTab] = [] {
        // The overview's cards are by index: tabs coming or going end it.
        didSet { dismissOverview() }
    }
    var selectedTab: TerminalTab

    /// A named set of tabs (Tern's session): a window holds several and shows
    /// one, the others' programs running on unseen. The active one's tabs
    /// live in `tabs`/`selectedTab`/`terminalTab` and are copied back here
    /// when it is switched away from.
    struct Workspace {
        /// Who it is, whatever its place in the list (which changes).
        let id = UUID()
        var name: String
        var tabs: [TerminalTab]
        var selected: TerminalTab
        var terminal: TerminalTab
    }
    var workspaces: [Workspace] = []
    var activeWorkspace = 0
    /// Each workspace's front tab (for saving a layout).
    var workspaceFrontTabs: [TerminalTab] { workspaces.map(\.selected) }
    /// The names, in order, and which one is showing.
    var workspaceNames: [String] { workspaces.map(\.name) }
    /// Each workspace's tabs, in order (the showing one's are the live ones).
    var workspaceTabs: [[TerminalTab]] {
        workspaces.enumerated().map { $0.offset == activeWorkspace ? tabs : $0.element.tabs }
    }
    /// Every tab of every workspace.
    var everyTab: [TerminalTab] { workspaceTabs.flatMap { $0 } }
    /// The terminal tab last selected: what new tabs, splits and the sidebar's
    /// "insert path" act on while a document is in front. There is always one.
    var terminalTab: TerminalTab
    var config: Config
    private var configToken: AnyObject?
    private var layoutObservation: NSKeyValueObservation?
    private var sidebarObservation: NSKeyValueObservation?
    /// The sidebar was folded because the tabs moved to the top and it had no files to show.
    var foldedForTabBar = false

    let splitController = ColumnsController()
    let sidebar = SidebarViewController()
    let areaController = TerminalAreaViewController()
    let inspector = InspectorViewController()
    let sidebarItem: NSSplitViewItem
    let inspectorItem: NSSplitViewItem
    var area: TerminalAreaView { areaController.area }

    /// Float on Top for new windows (Window ▸ Use as Default).
    static let floatDefaultsKey = "WindowFloatOnTop"
    private static let sidebarWidth: CGFloat = 250, inspectorWidth: CGFloat = 280
    var onClose: ((TerminalWindowController) -> Void)?

    /// `cols`/`rows` override the config's window size (benchmarks pass them).
    convenience init(config: Config, fontSize: CGFloat? = nil, cols: Int? = nil, rows: Int? = nil) throws {
        let cols = cols ?? config.windowColumns, rows = rows ?? config.windowRows
        let first = try Self.makePane(config: config, cols: cols, rows: rows)
        if let fontSize { first.fontSize = fontSize }
        self.init(config: config, tabs: [TerminalTab(pane: first)], selected: 0,
                  grid: first.contentSize(cols: cols, rows: rows), frame: nil,
                  showSidebar: config.windowSidebar, showInspector: config.windowInspector)
    }

    /// A saved window (see Restoration).
    convenience init(restoring tabs: [TerminalTab], selected: Int, frame: NSRect?,
                     showSidebar: Bool, showInspector: Bool, config: Config) {
        let probe = tabs[selected].focusedPane ?? tabs.first(where: \.isTerminal)!.focusedPane!
        self.init(config: config, tabs: tabs, selected: selected,
                  grid: probe.contentSize(cols: config.windowColumns, rows: config.windowRows), frame: frame,
                  showSidebar: showSidebar, showInspector: showInspector)
    }

    func markRestored(unstarted: [(TerminalView, String?)]) {
        restored = true
        self.unstarted = unstarted.map { (pane: $0.0, directory: $0.1) }
    }

    /// Panes restored without a live session: their shells start in these
    /// directories once the window is laid out (`start`).
    private var unstarted: [(pane: TerminalView, directory: String?)] = []
    /// Where the window was before full screen (what a saved layout keeps).
    var savedNonFullScreenFrame: NSRect?

    /// The quick terminal (a panel that drops down from a screen edge), not a window.
    let isQuick: Bool

    /// The machine this window's sessions run on (File ▸ Connect to Host…);
    /// nil for this Mac. Every tab and split of the window is there too.
    var host: RemoteHost?

    /// Set before `start()`.
    func bind(to host: RemoteHost) {
        self.host = host
        updateTitle()
    }

    /// The quick terminal's controller: one pane on a borderless panel.
    static func makeQuick(config: Config, pane: TerminalView) -> TerminalWindowController {
        TerminalWindowController(config: config, tabs: [TerminalTab(pane: pane)], selected: 0,
                                 grid: pane.contentSize(cols: config.windowColumns, rows: config.windowRows), frame: nil,
                                 showSidebar: false, showInspector: false, quick: true)
    }

    private init(config: Config, tabs: [TerminalTab], selected: Int, grid: NSSize, frame: NSRect?,
                 showSidebar: Bool, showInspector: Bool, quick: Bool = false) {
        isQuick = quick
        self.config = config
        // A saved window's tabs come grouped by workspace (a window made
        // fresh has the one); the one showing is where the selected tab is.
        let chosen = tabs[selected]
        var groups: [Workspace] = []
        for tab in tabs {
            let name = tab.restoredWorkspace ?? Self.defaultWorkspaceName
            if let g = groups.firstIndex(where: { $0.name == name }) {
                groups[g].tabs.append(tab)
                if tab.restoredSelected { groups[g].selected = tab }
            } else {
                groups.append(Workspace(name: name, tabs: [tab], selected: tab, terminal: tab))
            }
        }
        // Each needs a terminal tab (documents alone don't make a workspace).
        groups = groups.compactMap { g in
            guard let terminal = g.tabs.first(where: \.isTerminal) else { return nil }
            var g = g
            g.terminal = g.selected.isTerminal ? g.selected : terminal
            return g
        }
        let shown = groups.firstIndex { $0.tabs.contains { $0 === chosen } } ?? 0
        activeWorkspace = shown
        workspaces = groups
        self.tabs = groups[shown].tabs
        selectedTab = groups[shown].tabs.contains { $0 === chosen } ? chosen : groups[shown].selected
        terminalTab = selectedTab.isTerminal ? selectedTab : groups[shown].terminal

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 460
        sidebarItem.canCollapse = true
        // With the tabs along the top, a sidebar without its files has nothing to show.
        sidebarItem.isCollapsed = !showSidebar || (config.tabBar == .top && !config.sidebarFiles)
        let contentItem = NSSplitViewItem(viewController: areaController)
        contentItem.minimumThickness = 240
        // The terminals take what the window gains or loses (its edge dragged).
        contentItem.holdingPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue - 1)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 420
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = !showInspector

        // No line between the columns: the window is one surface. (Its own
        // split view, given before the controller's view loads, and the
        // items before that view is laid out.)
        let columns = FrameSplitView()
        columns.isVertical = true
        columns.dividerStyle = .thin
        splitController.splitView = columns
        // The side columns' widths before they join (they keep them).
        sidebar.view.frame.size.width = Self.sidebarWidth
        inspector.view.frame.size.width = Self.inspectorWidth
        splitController.splitViewItems = [sidebarItem, contentItem, inspectorItem]
        // The grid gets exactly cols × rows; the columns are added around it.
        let width = grid.width + (sidebarItem.isCollapsed ? 0 : Self.sidebarWidth) + (showInspector ? Self.inspectorWidth : 0)
        splitController.view.frame = NSRect(x: 0, y: 0, width: width, height: grid.height)

        let window: NSWindow = quick
            ? QuickPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: grid.height),
                         styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            : TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: grid.height),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // Tabs live in the sidebar, not in macOS's tab bar.
        window.tabbingMode = .disallowed
        window.title = "Libertty"
        window.contentViewController = splitController
        window.isReleasedWhenClosed = false
        // A window appears as it is: AppKit's document-window animation
        // draws it scaled (about 98%, growing to full over 0.4 s), so the
        // terminal's text seemed to change size each time one opened.
        if !quick { window.animationBehavior = .none }
        if UserDefaults.standard.bool(forKey: Self.floatDefaultsKey) { window.level = .floating }

        super.init(window: window)
        installToolbar()
        window.delegate = self
        sidebar.controller = self
        inspector.controller = self
        area.findBar.onChange = { [weak self] text in self?.find(text) }
        area.findBar.onNavigate = { [weak self] older in self?.findNext(older: older) }
        area.findBar.onArrow = { [weak self] up in
            guard let self else { return }
            // A document's next match is down the page; a terminal's older one is up.
            self.findNext(older: self.searchDocument == nil ? up : !up)
        }
        area.findBar.onClose = { [weak self] in _ = self?.endSearch() }

        workspaces.flatMap(\.tabs).forEach(adoptAll)
        firstResponderObservation = window.observe(\.firstResponder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.firstResponderChanged() }
        }
        area.show(selectedTab.content)
        applyWindowStyle()

        // Size: the toolbar sits over the content, so add its height.
        let probe = focusedTerminal
        let titlebar = window.frame.height - window.contentLayoutRect.height
        window.setContentSize(NSSize(width: width, height: grid.height + titlebar))
        let minimum = probe.contentSize(cols: 20, rows: 4)
        window.contentMinSize = NSSize(width: minimum.width, height: minimum.height + titlebar)
        if let frame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }

        layoutObservation = window.observe(\.contentLayoutRect) { [weak self] _, _ in self?.area.needsLayout = true }
        foldedForTabBar = showSidebar && sidebarItem.isCollapsed
        sidebarObservation = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] item, _ in
            MainActor.assumeIsolated {
                // Shown by anyone but us: it's the user's now.
                if !item.isCollapsed { self?.foldedForTabBar = false }
                self?.updateTitleVisibility()
            }
        }
        // Its panes were made with this config and theme already.
        appliedTheme = config.resolvedTheme
        splitController.toggle = { [weak self] sidebar in
            if sidebar { self?.toggleSidebar() } else { self?.toggleInspector() }
        }
        configToken = ConfigStore.shared.observe { [weak self] config in self?.configDidChange(config) }
        updateDimming()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `workingDirectory`: a folder asked for (Finder, a Service, `--cwd`):
    /// it, whatever `working-directory` says; `inherited`: the window it was
    /// made from's, which `working-directory` may overrule.
    func start(command: String? = nil, workingDirectory: String? = nil, inherited: String? = nil) throws {
        // Lay out first so the pty is born with the window's real grid size.
        window?.contentView?.layoutSubtreeIfNeeded()
        area.layoutSubtreeIfNeeded()
        everyTab.forEach { $0.container?.layoutPanes() }
        if restored {
            // Restored panes whose program is gone get a new shell where it was.
            // (Where each was, whatever `working-directory` says for new ones.)
            for (pane, directory) in unstarted {
                try? startSession(of: pane, command: nil, workingDirectory: directory, keepDirectory: directory != nil)
            }
            unstarted = []
        } else {
            try startSession(of: focusedTerminal, command: command, workingDirectory: workingDirectory ?? inherited,
                             keepDirectory: workingDirectory != nil)
        }
        window?.makeFirstResponder(selectedTab.focusTarget)
        updateBroadcastBorders()
        updateTitle()
        updateSidebar(force: true)
    }

    /// Made from a saved layout (`restore`), not with one new shell.
    private var restored = false
    /// `start()` ran (the quick terminal starts on first show).
    var hasStarted = false

    /// The directory a new window, tab or split should start in.
    var focusedWorkingDirectory: String? { focusedTerminal.session.workingDirectory }

    /// The pane keyboard input goes to (in the last terminal tab, while a
    /// document is in front).
    var focusedTerminal: TerminalView { (selectedTab.focusedPane ?? terminalTab.focusedPane)! }

    /// The selected tab's panes (diagnostics).
    var activeContainer: SplitContainerView? { selectedTab.container }

    /// The document in front, if the selected tab is one.
    var selectedDocument: DocumentView? { selectedTab.document ?? focusedDocumentPane }

    /// Every terminal the window runs, parked ones too.
    var allPanes: [TerminalView] { everyTab.flatMap(\.everyPane) }

    func adoptAll(_ tab: TerminalTab) {
        // A card made by another window acts on that one: syncCard makes ours.
        tab.container?.hideCard()
        tab.everyPane.forEach(adopt)
        tab.document.map(adopt)
        tab.documentPanes.forEach(adopt)
    }

    /// Where this window's terminals are (Go to Directory).
    var workingDirectories: [String] { allPanes.compactMap(\.session.workingDirectory) }

    /// The liberttyd sessions this window shows.
    var persistentSessionIDs: [String] { allPanes.compactMap(\.session.persistentID) }

    func endAllSessions() { allPanes.forEach { $0.session.terminate() } }

    /// `keepDirectory`: `workingDirectory` is where the pane was (Restart
    /// Shell in Pane), kept whatever `working-directory` says for new panes.
    func startSession(of pane: TerminalView, command: String?, workingDirectory: String?,
                              keepDirectory: Bool = false) throws {
        let command = command ?? (config.command.isEmpty ? nil : config.command)
        if let host {
            // A directory there (inherited from the focused pane), or its home.
            pane.session.start(on: host, workingDirectory: workingDirectory, command: command)
            pane.updateLinkBanner()
            return
        }
        let directory = keepDirectory ? workingDirectory : nil
        try pane.session.start(workingDirectory: directory ?? Self.directory(config.workingDirectory, inherited: workingDirectory),
                               command: command)
    }

    /// `working-directory`: `inherit` uses the given directory (the focused
    /// pane's), `home` the home directory, anything else is a path.
    static func directory(_ setting: String, inherited: String?) -> String {
        let home = NSHomeDirectory()
        switch setting {
        case "inherit": return inherited ?? home
        case "home": return home
        default:
            let path = (setting as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue ? path : home
        }
    }

    static func makePane(config: Config, cols: Int, rows: Int) throws -> TerminalView {
        let session = try TerminalSession(size: GridSize(
            cols: UInt16(clamping: cols), rows: UInt16(clamping: rows), widthPx: 0, heightPx: 0), config: config)
        return try TerminalView(session: session, config: config)
    }

    func adopt(_ pane: TerminalView) {
        pane.session.delegate = self
        pane.broadcastPeers = { [weak self, weak pane] in
            guard let self, let pane, let tab = self.tab(containing: pane), tab.broadcasting else { return [] }
            return tab.panes.filter { $0 !== pane }
        }
        pane.onOpenDocument = { [weak self] url, line, beside in
            if beside { self?.openDocumentInSplit(url, line: line) } else { self?.openDocument(url, line: line) }
        }
        pane.onRequestClose = { [weak self] pane in self?.closeTerminalPane(pane) }
        pane.onDragPane = { [weak self] pane, event in self?.dragPane(pane, from: event) }
        pane.onSubmit = { [weak self] pane in self?.promptSubmitted(in: pane) }
        pane.session.programStatus.onChange = { [weak self] in self?.updateTitle() }
        if pane.session.host != nil { pane.updateLinkBanner() }
        pane.onFocus = { [weak self] pane in self?.paneDidFocus(pane) }
        pane.onGridResize = { [weak self] pane in
            self?.everyTab.first { $0.panes.contains { $0 === pane } }?.container?.updateHeaders()
        }
    }

    /// The tab showing `pane` in its split, in any workspace.
    func tab(containing pane: TerminalView) -> TerminalTab? {
        everyTab.first { $0.panes.contains { $0 === pane } }
    }

    /// The tab `pane` belongs to, shown or parked, in any workspace.
    func owningTab(of pane: TerminalView) -> TerminalTab? {
        everyTab.first { $0.everyPane.contains { $0 === pane } }
    }

    func pane(for session: TerminalSession) -> TerminalView? {
        allPanes.first { $0.session === session }
    }

    /// The theme the panes last took (its file may change under its name).
    var appliedTheme: Theme?

    /// A one-off run (`Libertty -e`, a measurement): a pane goes with its
    /// program, so the run ends with it (bench scripts wait on that).
    static var oneShot = false

    /// Who opens a window for a tab: the app, or (`--ui-probe`) a probe, off screen.
    static var openWindowForTab: (TerminalTab, TerminalWindowController, NSPoint?) -> TerminalWindowController? = { tab, source, origin in
        (NSApp.delegate as? AppDelegate)?.openWindow(with: tab, like: source, at: origin)
    }

    /// Save each in turn; `done(false)` at the first that can't be saved.
    static func saveAll(_ docs: [DocumentView], done: @escaping (Bool) -> Void) {
        guard let first = docs.first else { return done(true) }
        first.save { ok in ok ? saveAll(Array(docs.dropFirst()), done: done) : done(false) }
    }

    private var firstResponderObservation: NSKeyValueObservation?

    static func fills(_ frame: NSRect, visible: NSRect) -> Bool { frame.width >= visible.width - 1 }

    /// `frame` kept on the screen's `visible` part when the window (`old`)
    /// was within it, by moving it; past the screen's width, the terminals
    /// give up the rest.
    static func onScreen(_ frame: NSRect, from old: NSRect, visible: NSRect?) -> NSRect {
        guard let visible, old.minX >= visible.minX, old.maxX <= visible.maxX else { return frame }
        var f = frame
        f.size.width = min(f.width, visible.width)
        if f.minX < visible.minX { f.origin.x = visible.minX }
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width }
        return f
    }

    /// What each session's foreground program is, as of the last poll.
    var programs: [ObjectIdentifier: ProgramTile] = [:]
    /// Which process each answer was about. While the same group leads
    /// under the same name, the answer stands — unless it only named the
    /// runtime itself: the program it starts may not be up yet.
    var identified: [ObjectIdentifier: Identified] = [:]
    var tilesScheduled = false

    var overview: TabOverviewView?

    /// The terminal the find bar's search is in (its highlights are there).
    weak var searchedPane: TerminalView?

    /// Panes where something finished or rang while you weren't looking:
    /// their tab carries a ring until you focus the pane.
    var attention: Set<ObjectIdentifier> = []
    /// Each tab's news as the sidebar shows it now.
    var shownNews: [TabNews] = []

    /// How long after a program's last output its tab still shows it
    /// printing (the pane's dot, too).
    static let printingFor: CFTimeInterval = 1.5

    /// OSC 7501: a program that now needs you (or is done) while you're elsewhere.
    /// Its most urgent record decides; each way of telling you follows its own
    /// setting and its own memory: a notification and the pane's lit edge
    /// (`program-status-notify`), a sound (`program-status-sound`).
    var notifiedRecords: [ObjectIdentifier: String] = [:]
    var soundedRecords: [ObjectIdentifier: String] = [:]

    static func signature(_ record: ProgramStatusStore.Record) -> String {
        "\(record.id)|\(record.state)|\(record.title)|\(record.message)"
    }

    static func title(ofPane pane: TerminalView) -> String {
        let program = ProgramStatusStore.sanitize(pane.session.title)
        if !program.isEmpty { return program }
        return pane.session.workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Libertty"
    }
    var onAttentionChange: (() -> Void)?
    /// Tabs, splits, names or focus changed: the saved layout should follow
    /// soon, so a crash right after a split doesn't bring the panes back as
    /// separate tabs (GoRex saves within a second of a change).
    var onLayoutChange: (() -> Void)?

    /// A title a shell sets at its prompt names the shell ("zsh") or where
    /// it is: "~/src", "prince@mac: ~/src", the folder's name, fish's
    /// "~/D/src". Programs' titles may hold paths too ("main.rs (~/src) -
    /// NVIM", "me@mail: inbox"), so only those forms count, against the
    /// folder the shell is in.
    static func isShellTitle(_ title: String, directory: String?) -> Bool {
        let bare = title.hasPrefix("-") ? String(title.dropFirst()) : title  // a login shell: "-zsh"
        if ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "nu", "xonsh", "pwsh"].contains(bare.lowercased()) {
            return true
        }
        let place = place(inShellTitle: title)
        if place.isEmpty { return true }
        let pathLike = (place.hasPrefix("~") || place.hasPrefix("/") || place.hasPrefix("…")) && !place.contains(" ")
        guard let directory, !directory.isEmpty else {
            // Where it is isn't known yet: a lone path is most likely that.
            return pathLike
        }
        let full = (directory as NSString).standardizingPath
        let tilde = (full as NSString).abbreviatingWithTildeInPath
        let name = (full as NSString).lastPathComponent
        // (A host's home isn't this Mac's: "~/src" there is any …/src. A
        // shortened path — fish's "~/D/src", "…/a/src" — ends in the folder.)
        return place == tilde || (place as NSString).expandingTildeInPath == full || place == name
            || place == "~" || place.hasPrefix("~/") && full.hasSuffix(String(place.dropFirst()))
            || pathLike && (place as NSString).lastPathComponent == name
    }

    /// What a shell's title says after any "user@host:" (bash's default
    /// and many prompts' titles).
    static func place(inShellTitle title: String) -> String {
        guard let at = title.firstIndex(of: "@"), let colon = title[at...].firstIndex(of: ":"),
              !title[..<colon].contains(" ") else { return title }
        return title[title.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    /// A directory as shells show it, from ~, and only its last two parts
    /// when it's deep ("…/src/app").
    static func shortDirectory(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        let tilde = (path as NSString).abbreviatingWithTildeInPath
        let parts = tilde.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count > 5 || (tilde.count > 40 && parts.count > 3) {
            return "…/" + parts.suffix(2).joined(separator: "/")
        }
        return tilde
    }

    static func label(for state: ProgramStatusStore.State) -> String {
        switch state {
        case .idle: "Idle"
        case .working: "Working"
        case .done: "Done"
        case .error: "Failed"
        case .blocked: "Waiting for you"
        }
    }

    static func label(for record: ProgramStatusStore.Record) -> String {
        switch record.state {
        case .idle: "Idle"
        case .working: "Working"
        case .done: "Done"
        case .error: "Failed"
        case .blocked:
            switch record.kind {
            case .permission: "Needs approval"
            case .question: "Needs an answer"
            case .auth: "Needs sign-in"
            case .none: "Waiting for you"
            }
        }
    }

    static func color(for state: ProgramStatusStore.State) -> NSColor {
        switch state {
        case .idle: .secondaryLabelColor
        case .working: .systemBlue
        case .done: .systemGreen
        case .error: .systemRed
        case .blocked: .systemOrange
        }
    }

    static let defaultWorkspaceName = "Default"

    /// Set when the user already confirmed closing (a whole window or all of them).
    var skipCloseConfirmation = false

    /// Unsaved documents were saved or let go for this close.
    var unsavedConfirmed = false

    /// The window was hidden for undo / brought back (the app keeps its list).
    var onHide: ((TerminalWindowController) -> Void)?
    var onUnhide: ((TerminalWindowController) -> Void)?

    static let newTabItem = NSToolbarItem.Identifier("libertty.newTab")
    static let splitRightItem = NSToolbarItem.Identifier("libertty.splitRight")
    static let splitDownItem = NSToolbarItem.Identifier("libertty.splitDown")
    static let findItem = NSToolbarItem.Identifier("libertty.find")
    static let inboxItem = NSToolbarItem.Identifier("libertty.inbox")
    static let hostItem = NSToolbarItem.Identifier("libertty.host")
    static let paletteItem = NSToolbarItem.Identifier("libertty.palette")
    static let tabsItem = NSToolbarItem.Identifier("libertty.tabs")
    /// One toolbar per `tab-bar` mode, so each keeps its own customization.
    static let sidebarToolbar = "libertty.window.2", topToolbar = "libertty.window.top"
    lazy var hostChip = HostChip()
    lazy var tabStrip: TabStrip = {
        let strip = TabStrip()
        strip.controller = self
        // As wide as the bar lets it be: the toolbar stretches an item
        // whose view may grow (as it does a search field).
        strip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            strip.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            strip.widthAnchor.constraint(lessThanOrEqualToConstant: 10_000),
            strip.heightAnchor.constraint(equalToConstant: TabStrip.height),
        ])
        return strip
    }()
    lazy var inboxPopover: NSPopover = {
        let popover = NSPopover()
        let inbox = InboxViewController()
        inbox.onReveal = { [weak self] pane in
            self?.inboxPopover.performClose(nil)
            _ = (NSApp.delegate as? AppDelegate)?.reveal(paneID: pane)
        }
        popover.contentViewController = inbox
        popover.behavior = .transient
        return popover
    }()
    var inboxObserver: AnyObject?

    /// "Split Right (⌘D)": a control's name and its keys as bound now.
    static func tip(_ label: String, _ action: Action) -> String {
        guard let keys = ConfigStore.shared.keybinds.trigger(for: action)?.displayString else { return label }
        return "\(label) (\(keys))"
    }
}
