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

/// One terminal window, laid out like Tern and Otty: tabs and files in a
/// sidebar, the selected tab's panes in the middle, an inspector on the
/// right, and the common actions in the toolbar.
final class TerminalWindowController: NSWindowController, NSWindowDelegate, TerminalSessionDelegate, NSToolbarDelegate {
    private(set) var tabs: [TerminalTab] = [] {
        // The overview's cards are by index: tabs coming or going end it.
        didSet { dismissOverview() }
    }
    private(set) var selectedTab: TerminalTab

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
    private var workspaces: [Workspace] = []
    private(set) var activeWorkspace = 0
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
    private var terminalTab: TerminalTab
    private var config: Config
    private var configToken: AnyObject?
    private var layoutObservation: NSKeyValueObservation?
    private var sidebarObservation: NSKeyValueObservation?
    /// The sidebar was folded because the tabs moved to the top and it had no files to show.
    private var foldedForTabBar = false

    private let splitController = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private let areaController = TerminalAreaViewController()
    private let inspector = InspectorViewController()
    private let sidebarItem: NSSplitViewItem
    private let inspectorItem: NSSplitViewItem
    private var area: TerminalAreaView { areaController.area }

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
    private(set) var savedNonFullScreenFrame: NSRect?

    /// The quick terminal (a panel that drops down from a screen edge), not a window.
    let isQuick: Bool

    /// The machine this window's sessions run on (File ▸ Connect to Host…);
    /// nil for this Mac. Every tab and split of the window is there too.
    private(set) var host: RemoteHost?

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
            : NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: grid.height),
                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                       backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // Tabs live in the sidebar, not in macOS's tab bar.
        window.tabbingMode = .disallowed
        window.title = "Libertty"
        window.contentViewController = splitController
        window.isReleasedWhenClosed = false
        if UserDefaults.standard.bool(forKey: Self.floatDefaultsKey) { window.level = .floating }

        super.init(window: window)
        installToolbar()
        window.delegate = self
        sidebar.controller = self
        inspector.controller = self
        area.findBar.onChange = { [weak self] text in self?.find(text) }
        area.findBar.onNavigate = { [weak self] older in self?.findNext(older: older) }
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
        configToken = ConfigStore.shared.observe { [weak self] config in self?.configDidChange(config) }
        updateDimming()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func start(command: String? = nil, workingDirectory: String? = nil) throws {
        // Lay out first so the pty is born with the window's real grid size.
        window?.contentView?.layoutSubtreeIfNeeded()
        area.layoutSubtreeIfNeeded()
        everyTab.forEach { $0.container?.layoutPanes() }
        if restored {
            // Restored panes whose program is gone get a new shell where it was.
            for (pane, directory) in unstarted {
                try? startSession(of: pane, command: nil, workingDirectory: directory)
            }
            unstarted = []
        } else {
            try startSession(of: focusedTerminal, command: command, workingDirectory: workingDirectory)
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
    private var allPanes: [TerminalView] { everyTab.flatMap(\.everyPane) }

    private func adoptAll(_ tab: TerminalTab) {
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
    private func startSession(of pane: TerminalView, command: String?, workingDirectory: String?,
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

    private func adopt(_ pane: TerminalView) {
        pane.session.delegate = self
        pane.broadcastPeers = { [weak self, weak pane] in
            guard let self, let pane, let tab = self.tab(containing: pane), tab.broadcasting else { return [] }
            return tab.panes.filter { $0 !== pane }
        }
        pane.onOpenDocument = { [weak self] url, line, beside in
            if beside { self?.openDocumentInSplit(url, line: line) } else { self?.openDocument(url, line: line) }
        }
        pane.onRequestClose = { [weak self] pane in self?.closeTerminalPane(pane) }
        pane.session.programStatus.onChange = { [weak self] in self?.updateTitle() }
        if pane.session.host != nil { pane.updateLinkBanner() }
        pane.onFocus = { [weak self] pane in self?.paneDidFocus(pane) }
        pane.onGridResize = { [weak self] pane in
            self?.everyTab.first { $0.panes.contains { $0 === pane } }?.container?.updateHeaders()
        }
    }

    /// The tab showing `pane` in its split, in any workspace.
    private func tab(containing pane: TerminalView) -> TerminalTab? {
        everyTab.first { $0.panes.contains { $0 === pane } }
    }

    /// The tab `pane` belongs to, shown or parked, in any workspace.
    private func owningTab(of pane: TerminalView) -> TerminalTab? {
        everyTab.first { $0.everyPane.contains { $0 === pane } }
    }

    private func pane(for session: TerminalSession) -> TerminalView? {
        allPanes.first { $0.session === session }
    }

    // MARK: Settings

    /// The theme the panes last took (its file may change under its name).
    private var appliedTheme: Theme?

    private func configDidChange(_ config: Config) {
        let old = self.config
        self.config = config
        // The panes take it when it changed — or its theme did (the theme's
        // file, the system's appearance), or Reload Configuration asked.
        let theme = config.resolvedTheme
        let requested = ConfigStore.shared.reloadingByRequest
        if config != old || theme != appliedTheme || requested {
            allPanes.forEach { $0.apply(config, resetFontSize: requested) }
        }
        let themeChanged = theme != appliedTheme
        appliedTheme = theme
        // Which program states tabs show and the Dock counts.
        if config.programStatusIndicator != old.programStatusIndicator { updateTitle() }
        if config.programStatusDockBadge != old.programStatusDockBadge { onAttentionChange?() }
        if config.programStatusNotify != old.programStatusNotify || config.programStatusSound != old.programStatusSound {
            rememberProgramStates()
        }
        // Editors follow their keys and the text size (documents get the
        // theme from applyWindowStyle).
        if config.editorKeymap != old.editorKeymap || config.fontSize != old.fontSize {
            documents(in: everyTab).forEach { $0.applyEditorSettings() }
        }
        applyWindowStyle()
        // Pane headers and dimmed documents are in the theme's colors.
        if themeChanged { updateDimming() }
        // The sidebar and inspector follow their settings when those change.
        if config.windowSidebar != old.windowSidebar {
            (Motion.reduced ? sidebarItem : sidebarItem.animator()).isCollapsed = !config.windowSidebar
        }
        if config.windowInspector != old.windowInspector {
            (Motion.reduced ? inspectorItem : inspectorItem.animator()).isCollapsed = !config.windowInspector
        }
        if config.sidebarShowHiddenFiles != old.sidebarShowHiddenFiles || config.sidebarFiles != old.sidebarFiles {
            updateSidebar(force: true)
        }
        if config.tabBar != old.tabBar {
            installToolbar()
            updateTitleVisibility()
            updateSidebar()
        }
        // Tabs along the top and the files folded away: the sidebar has nothing
        // left, and comes back with the tabs (unless the user folded it).
        if config.tabBar == .top, !config.sidebarFiles, config.tabBar != old.tabBar || old.sidebarFiles, isSidebarShown {
            foldedForTabBar = true
            (Motion.reduced ? sidebarItem : sidebarItem.animator()).isCollapsed = true
        } else if config.tabBar == .sidebar, foldedForTabBar {
            foldedForTabBar = false
            (Motion.reduced ? sidebarItem : sidebarItem.animator()).isCollapsed = false
        }
    }

    /// The bar carries only controls while the tabs are named elsewhere
    /// (the sidebar, the top; Tern's); with the sidebar folded away and
    /// no tabs on top, the title says which tab is in front.
    private func updateTitleVisibility() {
        window?.titleVisibility = config.tabBar == .top || isSidebarShown ? .hidden : .visible
    }

    private func applyWindowStyle() {
        guard let window else { return }
        let theme = config.resolvedTheme
        let opaque = config.backgroundOpacity >= 1
        window.isOpaque = opaque
        // One surface around the panes (toolbar, side columns, gaps), lit
        // below them in a dark theme (Tern's look).
        let frame = opaque ? theme.chrome : theme.background
        window.backgroundColor = opaque ? frame.nsColor : .clear
        // Controls follow the terminal's theme.
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        area.apply(background: frame, opacity: config.backgroundOpacity, blurred: config.backgroundBlur)
        (splitController.splitView as? FrameSplitView)?.frameColor = frame.nsColor.withAlphaComponent(config.backgroundOpacity)
        sidebar.apply(frame: frame, opacity: config.backgroundOpacity)
        inspector.apply(frame: frame, opacity: config.backgroundOpacity)
        everyTab.forEach { $0.document?.apply(theme: theme, renderMarkdown: config.markdownRendered) }
        everyTab.flatMap(\.documentPanes).forEach { $0.apply(theme: theme, renderMarkdown: config.markdownRendered) }
    }

    // MARK: Tabs

    /// ⌘T: a new tab after the selected one, in the focused pane's directory.
    @discardableResult
    func newTab(command: String? = nil, workingDirectory: String? = nil) -> TerminalTab? {
        do {
            let s = focusedTerminal.session.size
            let pane = try Self.makePane(config: config, cols: Int(s.cols), rows: Int(s.rows))
            pane.fontSize = focusedTerminal.fontSize
            adopt(pane)
            // Its shell first — in the folder of the pane focused until now,
            // and one that can't start leaves no dead tab behind.
            try startSession(of: pane, command: command, workingDirectory: workingDirectory ?? focusedWorkingDirectory)
            let tab = TerminalTab(pane: pane)
            let index = (tabs.firstIndex { $0 === selectedTab } ?? tabs.count - 1) + 1
            tabs.insert(tab, at: index)
            select(tab)
            return tab
        } catch {
            showError(error)
            return nil
        }
    }

    /// A tab showing a session liberttyd already runs (`libertty +attach`); shown
    /// elsewhere too, it mirrors.
    func attachTab(_ id: String) {
        do {
            let session = try TerminalSession.attach(id, config: config)
            let pane = try TerminalView(session: session, config: config)
            pane.fontSize = focusedTerminal.fontSize
            adopt(pane)
            let tab = TerminalTab(pane: pane)
            let index = (tabs.firstIndex { $0 === selectedTab } ?? tabs.count - 1) + 1
            tabs.insert(tab, at: index)
            select(tab)
        } catch {
            showError(error)
        }
    }

    func duplicateTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        if let doc = tabs[index].document { return openDocument(doc.url, reuse: false) }
        newTab(workingDirectory: tabs[index].focusedPane?.session.workingDirectory)
    }

    /// A file from the sidebar or a link: shown in a tab (one per file).
    /// `edit`: in the editor whatever the file (`+open --wait`); `waitToken`:
    /// who to tell when it closes.
    func openDocument(_ url: URL, reuse: Bool = true, line: Int? = nil, edit: Bool? = nil, waitToken: String? = nil) {
        // A file a block edits (a drawing) opens in it, unless it's asked for as text.
        let url = edit == true ? url : Blocks.address(forFile: url) ?? url
        if reuse, let open = tabs.first(where: { $0.document?.url.standardizedFileURL == url.standardizedFileURL }) {
            select(open)
            if edit == true { open.document?.setEditing(true) }
            // Someone else may wait on it already: each hears when it closes.
            open.document?.addWaiter(waitToken)
            if let line { open.document?.reveal(line: line) }
            return
        }
        let doc = makeDocument(url, edit: edit)
        doc.addWaiter(waitToken)
        if let line { doc.reveal(line: line) }
        let tab = TerminalTab(document: doc)
        let index = (tabs.firstIndex { $0 === selectedTab } ?? tabs.count - 1) + 1
        tabs.insert(tab, at: index)
        select(tab)
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    /// Tab N (1-based), or the last with nil.
    func selectTab(_ n: Int?) {
        let i = n.map { $0 - 1 } ?? tabs.count - 1
        selectTab(at: i)
    }

    func selectTab(offset: Int) {
        guard let i = tabs.firstIndex(where: { $0 === selectedTab }), tabs.count > 1 else { return }
        selectTab(at: (i + offset + tabs.count) % tabs.count)
    }

    func select(_ tab: TerminalTab) {
        dismissOverview()
        let changed = tab !== selectedTab
        tab.rang = false
        if changed, area.findBar.isHidden == false { _ = endSearch() }
        selectedTab = tab
        if tab.isTerminal { terminalTab = tab }
        area.show(tab.content)
        tab.container?.layoutPanes()
        window?.makeFirstResponder(tab.focusTarget)
        tab.panes.forEach { $0.setNeedsRender(force: true) }
        updateDimming()
        updateTitle()
        updateSidebar(force: changed)
    }

    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: max(0, min(tabs.count, to)))
        updateSidebar()
    }

    /// The name a tab was given (empty: it names itself).
    func tabNameOverride(at index: Int) -> String {
        tabs.indices.contains(index) ? tabs[index].titleOverride : ""
    }

    func tab(at index: Int) -> TerminalTab? { tabs.indices.contains(index) ? tabs[index] : nil }

    /// Name a tab; empty goes back to the automatic name.
    func renameTab(at index: Int, to name: String) {
        guard tabs.indices.contains(index) else { return }
        rename(tabs[index], to: name)
    }

    func rename(_ tab: TerminalTab, to name: String) {
        guard everyTab.contains(where: { $0 === tab }) else { return }  // closed meanwhile
        tab.titleOverride = ProgramStatusStore.sanitize(name)
        updateTitle()
    }

    /// The keyboard back to the tab in front, after the sidebar had it.
    func focusTerminal() {
        if let target = selectedTab.focusTarget { window?.makeFirstResponder(target) }
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        confirmUnsaved(documentsClosing(with: tab)) { [weak self] in
            self?.confirmIfBusy(tab.everyPane, noun: "tab") { [weak self] in self?.removeTab(tab, unsavedAsked: true) }
        }
    }

    /// Close Tab (close_tab).
    func closeSelectedTab() {
        guard let i = tabs.firstIndex(where: { $0 === selectedTab }) else { return }
        closeTab(at: i)
    }

    func closeOtherTabs(keeping index: Int) {
        guard tabs.indices.contains(index) else { return }
        let keep = tabs[index]
        // A document can't hold the window (or workspace) on its own: the
        // terminal tab it was opened from stays with it.
        let others = tabs.filter { $0 !== keep && (keep.isTerminal || $0 !== terminalTab) }
        confirmUnsaved(documents(in: others)) { [weak self] in
            self?.confirmIfBusy(others.flatMap(\.everyPane), noun: "tabs") { [weak self] in
                others.forEach { self?.removeTab($0, unsavedAsked: true) }
            }
        }
    }

    private func removeTab(_ tab: TerminalTab, undoable: Bool = true, unsavedAsked: Bool = false) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        // A program ending by itself takes no unsaved text along without asking.
        if !unsavedAsked, documentsClosing(with: tab).contains(where: \.hasUnsavedChanges) {
            return confirmUnsaved(documentsClosing(with: tab)) { [weak self] in
                self?.removeTab(tab, undoable: undoable, unsavedAsked: true)
            }
        }
        // Documents ride along with terminals: the last terminal tab closes the window.
        guard tabs.contains(where: { $0 !== tab && $0.isTerminal }) else {
            // Its workspace ends with it, when the window has others.
            if workspaces.count > 1 { return endWorkspace(workspaces[activeWorkspace].id, undoable: undoable) }
            // (Its documents were asked about: the window doesn't ask again.)
            unsavedConfirmed = true
            if undoable {
                window?.performClose(nil)
            } else {
                skipCloseConfirmation = true
                window?.close()
            }
            return
        }
        let home = workspaces[activeWorkspace].id
        tabs.remove(at: i)
        if tab === terminalTab, let other = tabs.last(where: \.isTerminal) { terminalTab = other }
        if tab === selectedTab { select(tabs[min(i, tabs.count - 1)]) } else { updateSidebar() }
        tab.content.removeFromSuperview()
        tab.everyPane.forEach { PictureInPicture.paneClosed($0) }
        documentsClosed(documents(in: [tab]))
        let ending = tab.everyPane.filter { !$0.session.hasExited }
        guard undoable, CloseUndo.shared.enabled, !ending.isEmpty || tab.document != nil else {
            ending.forEach { $0.session.terminate() }
            return
        }
        CloseUndo.shared.closed("Close Tab", restore: { [weak self] in
            guard let self, self.window?.isVisible == true,
                  tab.document != nil || tab.everyPane.contains(where: { !$0.session.hasExited }) else { return nil }
            // Back in the workspace it was closed in, if that's still here.
            if let w = self.workspaces.firstIndex(where: { $0.id == home }) { self.switchWorkspace(to: w) }
            self.tabs.insert(tab, at: min(i, self.tabs.count))
            self.select(tab)
            // Programs that ended meanwhile take their panes with them.
            self.clearExited(in: tab)
            return { [weak self] in self?.removeTab(tab) }
        }, expire: { ending.forEach { $0.session.terminate() } })
    }

    // MARK: Panes

    @objc func splitRight(_ sender: Any?) { split(.right) }
    @objc func splitDown(_ sender: Any?) { split(.down) }

    func split(_ direction: SplitContainerView.Direction) {
        // A document in front: split the terminal tab instead.
        if !selectedTab.isTerminal { select(terminalTab) }
        guard let focused = selectedTab.focusedPane else { return }
        split(focused, toward: direction)
    }

    /// A new terminal beside `pane`, with `share` of its space, running
    /// `command` (else a shell) in `workingDirectory` (else `pane`'s).
    /// `focus`: the keyboard goes to it. An error shows on the window.
    @discardableResult
    func split(_ pane: TerminalView, toward direction: SplitContainerView.Direction, share: CGFloat = 0.5,
               command: String? = nil, workingDirectory: String? = nil, focus: Bool = true) -> TerminalView? {
        do {
            return try makeSplit(beside: pane, toward: direction, share: share, command: command,
                                 workingDirectory: workingDirectory, focus: focus)
        } catch {
            showError(error)
            return nil
        }
    }

    /// The same, the error to the caller (`libertty +split` hears it; no alert waits on anyone).
    func makeSplit(beside pane: TerminalView, toward direction: SplitContainerView.Direction, share: CGFloat = 0.5,
                   command: String? = nil, workingDirectory: String? = nil, focus: Bool = true,
                   keepOpen: Bool = false) throws -> TerminalView? {
        guard let tab = tab(containing: pane), let container = tab.container else { return nil }
        do {
            // The new pane buds out from zero size, so give its shell the
            // size it will settle at rather than a default.
            let s = pane.session.size
            let (cols, rows) = direction == .left || direction == .right
                ? (max(1, Int((CGFloat(Int(s.cols) - 1) * share).rounded(.down))), Int(s.rows))
                : (Int(s.cols), max(1, Int((CGFloat(Int(s.rows) - 1) * share).rounded(.down))))
            let new = try Self.makePane(config: config, cols: cols, rows: rows)
            new.fontSize = pane.fontSize
            new.session.keepsPaneAfterExit = keepOpen
            adopt(new)
            // Its shell first: one that can't start leaves no dead pane behind.
            try startSession(of: new, command: command, workingDirectory: workingDirectory ?? pane.session.workingDirectory,
                             keepDirectory: workingDirectory != nil)
            container.split(pane, with: new, toward: direction, share: share)
            if focus {
                if tab !== selectedTab { reveal(new, in: tab) } else { window?.makeFirstResponder(new) }
            }
            updateSidebar()
            return new
        }
    }

    enum MoveTarget { case newTab, newWindow, tab(Int) }

    /// Why `pane` can't go to `target`, or nil when it can — asked before
    /// anything is brought forward (`libertty +move-pane`). Tab N is of the
    /// workspace `pane` is in.
    func whyNotMove(_ pane: TerminalView, to target: MoveTarget) -> String? {
        if isQuick { return "the Quick Terminal's pane stays there" }
        guard let tab = tab(containing: pane) else { return "it's parked (unpark it first)" }
        switch target {
        case .newTab, .newWindow:
            return tab.panes.count > 1 ? nil : "it's the only pane of its tab"
        case .tab(let n):
            let list = workspaceTabs.first { $0.contains { $0 === tab } } ?? tabs
            guard list.indices.contains(n - 1) else { return "its window has no tab \(n)" }
            let other = list[n - 1]
            if other === tab { return "it's in tab \(n) already" }
            guard other.isTerminal else { return "tab \(n) shows a document" }
            let alone = tab.container?.views.count == 1 && tab.parked.isEmpty
            return tab.panes.count > 1 || alone ? nil : "documents beside it would be left without a terminal"
        }
    }

    /// The pane showing session `id` in this window, in a split or parked.
    func pane(showing id: String) -> TerminalView? {
        allPanes.first { $0.paneID == id }
    }

    /// Whether `pane` is out of its split (parked).
    func isOutOfSplit(_ pane: TerminalView) -> Bool { tab(containing: pane) == nil }

    /// After `reveal`: whether the focused pane can go to `target` now —
    /// any split changing under way (a pane closing) settled first.
    func canMoveFocusedPane(to target: MoveTarget) -> Bool {
        guard let pane = selectedTab.focusedPane, selectedTab.container?.contains(pane) == true else { return false }
        switch target {
        case .newTab, .newWindow: return canMoveFocusedPaneOut
        case .tab(let n): return canMoveFocusedPane(toTab: n)
        }
    }

    /// A pane couldn't start: a sheet on this window, not an alert that
    /// stops every window of the app until it's dismissed.
    func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// ⌘W closes the focused pane; the last pane closes its tab, the last
    /// tab the window.
    @objc func closePane(_ sender: Any?) {
        if let doc = focusedDocumentPane { return closeDocumentPane(doc) }
        guard let pane = selectedTab.focusedPane else { return closeSelectedTab() }
        closeTerminalPane(pane)
    }

    /// The focused pane is a terminal to restart: with a document focused
    /// there's none to name.
    var canRestartFocusedPane: Bool { selectedTab.isTerminal && selectedTab.focusedDocument == nil }

    /// Restart Shell in Pane: a hung program or a terminal left in a bad
    /// state ends, and a fresh shell starts in the same place, size and
    /// folder (GoRex). Asks first when something is running.
    func restartFocusedPane() {
        guard canRestartFocusedPane, let old = selectedTab.focusedPane else { return }
        confirmIfBusy([old], noun: "pane", verb: "Restart") { [weak self] in
            // The answer may come later: the pane, its tab or its split may
            // be gone by then — or going (`contains` lets a pane shrinking
            // away finish), and then there's nothing to restart.
            guard let self, let tab = self.tab(containing: old), let container = tab.container,
                  container.contains(old), !old.session.hasExited || old.closesOnKey else { return }
            // Where it was, whatever `working-directory` says for new panes
            // (that's for when where it was is unknown, or gone).
            var isDirectory: ObjCBool = false
            let directory = old.session.workingDirectory.flatMap {
                self.host != nil || FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue
                    ? $0 : nil
            }
            let pane: TerminalView
            do {
                let s = old.session.size
                pane = try Self.makePane(config: self.config, cols: Int(s.cols), rows: Int(s.rows))
                pane.fontSize = old.fontSize
                self.adopt(pane)
                // The new shell first: if it can't start, the old one stays.
                try self.startSession(of: pane, command: nil, workingDirectory: directory, keepDirectory: true)
            } catch {
                return self.showError(error)
            }
            // The keyboard goes to the new pane only if the old one had it.
            let hadKeyboard = self.window?.firstResponder === old
            guard container.replace(old, with: pane) else { return pane.session.terminate() }
            old.session.terminate()
            // What the old shell's programs posted has nowhere to lead now.
            Notifier.shared.clear(pane: old.paneID)
            if tab.focusedPane === old { tab.focusedPane = pane }
            tab.noteFocus(pane)
            if hadKeyboard { self.window?.makeFirstResponder(pane) }
            self.updateBroadcastBorders()
            self.updateDimming()
            self.updateSidebar()
        }
    }

    /// `parking`: the pane leaves the split but its program keeps running
    /// (Park Pane), instead of ending.
    /// `asCard`: parked to show as the tab's floating card (Float Pane).
    /// `unsavedAsked`: the documents its tab would take along were asked about.
    private func removePane(_ pane: TerminalView, undoable: Bool = true, parking: Bool = false, asCard: Bool = false,
                            unsavedAsked: Bool = false) {
        guard let tab = tab(containing: pane), let container = tab.container else { return }
        // Documents beside it don't keep a tab open on their own. A tab
        // with parked panes behind it shows the latest of them in its place.
        guard tab.panes.count > 1 else {
            guard !parking, let entry = tab.parked.last, container.replace(pane, with: entry.pane) else {
                return parking ? () : removeTab(tab, undoable: undoable, unsavedAsked: unsavedAsked)
            }
            tab.parked.removeLast()
            entry.pane.isParked = false
            pane.session.terminate()
            Notifier.shared.clear(pane: pane.paneID)
            if tab.focusedPane === pane { tab.focusedPane = entry.pane }
            tab.noteFocus(entry.pane)
            if tab === selectedTab { window?.makeFirstResponder(entry.pane) }
            updateBroadcastBorders()
            updateDimming()
            updateSidebar()
            return
        }
        // Where the pane stood: for putting it back with Undo, or from the parking.
        let next = container.neighbor(of: pane, .left) ?? container.neighbor(of: pane, .up)
            ?? container.views.first { $0 !== pane }
        // Focus moves only if the closing pane had it — a pane exiting in
        // the background doesn't take your keyboard elsewhere — and then
        // back to the pane you were in before, not to a neighbor (GoRex).
        let hadFocus = tab.focusedPane === pane && tab.focusedDocument == nil
        let successor: NSView? = tab.previouslyFocused(besides: pane) ?? next
        // Where it was, relative to the pane that takes its place.
        func side(of next: NSView) -> SplitContainerView.Direction {
            let a = pane.frame, b = next.frame
            return a.minX >= b.maxX - 1 ? .right : a.maxX <= b.minX + 1 ? .left : a.minY >= b.maxY - 1 ? .down : .up
        }
        if parking {
            guard let next, !tab.parked.contains(where: { $0.pane === pane }) else { return }
            // One card a tab: another pane's stays parked, out of sight. The
            // card shows once the pane is out of the split (the sidebar's update).
            if asCard { for j in tab.parked.indices { tab.parked[j].showsCard = false } }
            tab.parked.append(TerminalTab.Parked(pane: pane, anchor: next, side: side(of: next), showsCard: asCard))
            pane.isParked = true
        } else if undoable, !pane.session.hasExited, CloseUndo.shared.enabled, let next {
            let side = side(of: next)
            CloseUndo.shared.closed("Close Pane", restore: { [weak self, weak tab] in
                guard let self, let tab, self.tabs.contains(where: { $0 === tab }), let container = tab.container,
                      !pane.session.hasExited else { return nil }
                let anchor = container.views.contains { $0 === next } ? next : (tab.focusedPane ?? container.views.first!)
                if tab !== self.selectedTab { self.select(tab) }
                container.split(anchor, with: pane, toward: side)
                self.window?.makeFirstResponder(pane)
                self.updateDimming()
                self.updateSidebar()
                return { [weak self] in self?.removePane(pane) }
            }, expire: { pane.session.terminate() })
        } else {
            pane.session.terminate()
        }
        container.remove(pane) { [weak self] in
            guard let self else { return }
            guard hadFocus else {
                // Somewhere else had the focus; it stays there.
                self.updateDimming()
                self.updateSidebar()
                return
            }
            if let terminal = successor as? TerminalView {
                tab.focusedPane = terminal
            } else if tab.focusedPane === pane {
                tab.focusedPane = tab.panes.first
            }
            if tab === self.selectedTab, let successor { self.focusLeaf(successor) }
            self.updateDimming()
            self.updateSidebar()
        }
    }

    // MARK: Parking

    /// The focused pane can be parked: another terminal stays in view.
    var canParkFocusedPane: Bool {
        selectedTab.isTerminal && selectedTab.focusedDocument == nil && selectedTab.panes.count > 1
            && selectedTab.focusedPane?.session.hasExited != true
            && !(selectedTab.focusedPane.map { pane in selectedTab.parked.contains { $0.pane === pane } } ?? false)
    }

    /// Park Pane: the focused pane leaves the split, its program running
    /// on (Tern's park). Unpark Pane puts it back where it stood.
    func parkFocusedPane() {
        guard canParkFocusedPane, let pane = selectedTab.focusedPane else { return }
        removePane(pane, undoable: false, parking: true)
    }

    /// The parked panes of the tab in front, or failing that of any tab, latest last.
    var parkedPanes: [TerminalView] {
        let here = selectedTab.parked.map(\.pane)
        return here.isEmpty ? tabs.flatMap { $0.parked.map(\.pane) } : here
    }

    /// Every parked pane of the window: its tab's number and the pane.
    var allParked: [(tab: TerminalTab, number: Int, pane: TerminalView)] {
        tabs.enumerated().flatMap { n, tab in tab.parked.map { (tab, n + 1, $0.pane) } }
    }

    /// Put the latest parked pane back (Unpark Pane).
    func unparkLatest() {
        if let pane = parkedPanes.last { unpark(pane) }
    }

    /// Put a parked pane back in its tab, beside the pane it stood by
    /// (or the focused one, if that is gone).
    func unpark(_ pane: TerminalView) {
        guard let tab = tabs.first(where: { $0.parked.contains { $0.pane === pane } }),
              let entry = tab.parked.first(where: { $0.pane === pane }), let container = tab.container else { return }
        guard !pane.session.hasExited else {
            tab.parked.removeAll { $0.pane === pane }
            pane.isParked = false
            return updateSidebar()
        }
        tab.parked.removeAll { $0.pane === pane }
        pane.isParked = false
        if tab !== selectedTab { select(tab) }
        if let zoomed = container.zoomed { container.toggleZoom(zoomed) }
        let anchor = entry.anchor.flatMap { a in container.views.contains { $0 === a } ? a : nil }
            ?? tab.focusedLeaf ?? container.views.first!
        container.split(anchor, with: pane, toward: entry.side)
        tab.focusedPane = pane
        tab.focusedDocument = nil
        tab.noteFocus(pane)
        window?.makeFirstResponder(pane)
        updateBroadcastBorders()
        updateDimming()
        updateSidebar()
    }

    // MARK: Moving panes and tabs (after Rex)

    /// The focused pane can leave for a tab or a window of its own: a
    /// terminal in a split, with another terminal staying there.
    var canMoveFocusedPaneOut: Bool {
        !isQuick && selectedTab.isTerminal && selectedTab.focusedDocument == nil && selectedTab.panes.count > 1
            && !isParked(selectedTab.focusedPane)
    }

    private func isParked(_ pane: TerminalView?) -> Bool {
        pane.map { pane in selectedTab.parked.contains { $0.pane === pane } } ?? false
    }

    /// The focused pane can join tab `n` (1-based) of the workspace in front:
    /// another terminal tab. A pane alone in its tab takes the tab's place
    /// there; one beside documents stays (they'd be left without a terminal).
    func canMoveFocusedPane(toTab n: Int) -> Bool {
        guard !isQuick, selectedTab.isTerminal, selectedTab.focusedDocument == nil, selectedTab.focusedPane != nil,
              !isParked(selectedTab.focusedPane), tabs.indices.contains(n - 1), let container = selectedTab.container
        else { return false }
        let target = tabs[n - 1]
        guard target !== selectedTab, target.isTerminal, target.container != nil else { return false }
        return selectedTab.panes.count > 1 || (container.views.count == 1 && selectedTab.parked.isEmpty)
    }

    /// `tab` can go to another window: a terminal tab of the workspace in
    /// front, with another terminal tab staying behind.
    func canMoveTabOut(_ tab: TerminalTab) -> Bool {
        !isQuick && tab.isTerminal && tabs.contains { $0 === tab } && tabs.contains { $0 !== tab && $0.isTerminal }
    }

    var canMoveSelectedTabOut: Bool { canMoveTabOut(selectedTab) }

    /// Move Pane to New Tab: the focused pane gets a tab of its own after this one.
    func moveFocusedPaneToNewTab() {
        guard canMoveFocusedPaneOut, let pane = selectedTab.focusedPane else { return }
        let source = selectedTab
        takeOut(pane, from: source) { [weak self] in
            guard let self else { return }
            let tab = TerminalTab(pane: pane)
            let index = (self.tabs.firstIndex { $0 === source } ?? self.tabs.count - 1) + 1
            self.tabs.insert(tab, at: index)
            self.select(tab)
        }
    }

    /// Move Pane to Tab: the focused pane joins tab `n`'s split, beside its focused pane.
    func moveFocusedPane(toTab n: Int) {
        guard canMoveFocusedPane(toTab: n), let pane = selectedTab.focusedPane else { return }
        let source = selectedTab, target = tabs[n - 1]
        let join = { [weak self] in
            guard let self else { return }
            // Gone meanwhile (it closed while the pane slid out): a tab of its own then.
            guard self.tabs.contains(where: { $0 === target }), let container = target.container,
                  let anchor = target.focusedLeaf ?? container.views.first else {
                let tab = TerminalTab(pane: pane)
                self.tabs.append(tab)
                return self.select(tab)
            }
            if let zoomed = container.zoomed { container.toggleZoom(zoomed) }
            container.split(anchor, with: pane, toward: .right)
            target.focusedPane = pane
            target.focusedDocument = nil
            target.noteFocus(pane)
            self.select(target)
            self.window?.makeFirstResponder(pane)
            self.updateBroadcastBorders()
        }
        if source.panes.count > 1 {
            takeOut(pane, from: source, then: join)
        } else {
            // Alone in its tab: the tab goes, the pane lives on in the other.
            guard source.container?.contains(pane) == true else { return }
            detach(source)
            pane.removeFromSuperview()
            join()
        }
    }

    /// A one-off run (`Libertty -e`, a measurement): a pane goes with its
    /// program, so the run ends with it (bench scripts wait on that).
    static var oneShot = false

    /// Who opens a window for a tab: the app, or (`--ui-probe`) a probe, off screen.
    static var openWindowForTab: (TerminalTab, TerminalWindowController, NSPoint?) -> TerminalWindowController? = { tab, source, origin in
        (NSApp.delegate as? AppDelegate)?.openWindow(with: tab, like: source, at: origin)
    }

    /// What this window knew of `panes`, come from `other`: news unseen
    /// (the tab's ring), and what was already notified or sounded — so
    /// the move doesn't announce it again.
    private func takeNews(of panes: [TerminalView], from other: TerminalWindowController) {
        for pane in panes {
            let id = ObjectIdentifier(pane), key = ObjectIdentifier(pane.session)
            if other.attention.remove(id) != nil { attention.insert(id) }
            if let n = other.notifiedRecords.removeValue(forKey: key) { notifiedRecords[key] = n }
            if let s = other.soundedRecords.removeValue(forKey: key) { soundedRecords[key] = s }
        }
        updateSidebar()
    }

    /// Move Pane to New Window: the focused pane in a window of its own.
    func moveFocusedPaneToNewWindow() {
        guard canMoveFocusedPaneOut, let pane = selectedTab.focusedPane else { return }
        takeOut(pane, from: selectedTab) { [weak self] in
            guard let self else { return }
            Self.openWindowForTab(TerminalTab(pane: pane), self, nil)?.takeNews(of: [pane], from: self)
        }
    }

    /// Move Tab to New Window: the tab in front, or `tab`, in a window of its
    /// own, with its top left at `origin` (a screen point; nil: cascaded from this one).
    func moveTabToNewWindow(_ tab: TerminalTab? = nil, at origin: NSPoint? = nil) {
        let tab = tab ?? selectedTab
        guard canMoveTabOut(tab) else { return }
        detach(tab)
        Self.openWindowForTab(tab, self, origin)?.takeNews(of: tab.everyPane, from: self)
    }

    /// `other`'s tab may come here: both windows on the same machine. Its
    /// window's only tab may too; that window closes then (as browsers do).
    func canTake(_ tab: TerminalTab, from other: TerminalWindowController) -> Bool {
        other !== self && !isQuick && other.host?.destination == host?.destination
            && (other.canMoveTabOut(tab) || other.isOnlyTab(tab))
    }

    /// A tab of `other` moves to this window at `index` (dropped on this sidebar).
    func take(_ tab: TerminalTab, from other: TerminalWindowController, at index: Int) {
        guard canTake(tab, from: other) else { return }
        if other.canMoveTabOut(tab) { other.detach(tab) } else { other.closeGivingAway(tab) }
        tab.restoredWorkspace = nil
        adoptAll(tab)
        takeNews(of: tab.everyPane, from: other)
        tabs.insert(tab, at: max(0, min(tabs.count, index)))
        select(tab)
        updateBroadcastBorders()
        window?.makeKeyAndOrderFront(nil)
    }

    /// `pane` leaves `tab`'s split, its program running on; the focus goes
    /// where closing it would send it. `then` once it's out of the split.
    private func takeOut(_ pane: TerminalView, from tab: TerminalTab, then: @escaping () -> Void) {
        // Still there: a move asked for twice, or a park just before, already took it
        // (`contains` lets a removal under way finish first).
        guard let container = tab.container, container.contains(pane), tab.panes.count > 1 else { return }
        let hadFocus = tab.focusedPane === pane && tab.focusedDocument == nil
        let successor: NSView? = tab.previouslyFocused(besides: pane)
            ?? container.neighbor(of: pane, .left) ?? container.neighbor(of: pane, .up) ?? container.views.first { $0 !== pane }
        container.remove(pane) { [weak self] in
            guard let self else { return }
            if hadFocus {
                if let terminal = successor as? TerminalView {
                    tab.focusedPane = terminal
                } else if tab.focusedPane === pane {
                    tab.focusedPane = tab.panes.first
                }
                if tab === self.selectedTab, let successor { self.focusLeaf(successor) }
            }
            pane.layer?.borderWidth = 0  // a broadcast's border is this split's
            then()
            self.updateBroadcastBorders()
            self.updateDimming()
            self.updateSidebar()
        }
    }

    /// `tab` is all this window has, in every workspace.
    private func isOnlyTab(_ tab: TerminalTab) -> Bool {
        !isQuick && everyTab.count == 1 && everyTab.first === tab
    }

    /// The window's only tab went to another: the window closes, nothing
    /// in it ending (closing ends only what its tabs still hold: none).
    private func closeGivingAway(_ tab: TerminalTab) {
        guard isOnlyTab(tab) else { return }
        tabs = []
        tab.content.removeFromSuperview()
        skipCloseConfirmation = true
        // Not inside the drag that took it: its sidebar is that drag's source.
        DispatchQueue.main.async { [weak self] in self?.window?.close() }
    }

    /// `tab` leaves this window as it is, programs and all: it's going
    /// elsewhere. Another terminal tab stays (the callers make sure).
    private func detach(_ tab: TerminalTab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }), tabs.contains(where: { $0 !== tab && $0.isTerminal }) else { return }
        tabs.remove(at: i)
        if tab === terminalTab, let other = tabs.last(where: \.isTerminal) { terminalTab = other }
        if tab === selectedTab { select(tabs[min(i, tabs.count - 1)]) } else { updateSidebar() }
        tab.content.removeFromSuperview()
    }

    /// Float Pane: park the focused pane and show it live in a corner of the
    /// split (Tern's in-window picture in picture). With a card showing,
    /// the card's pane comes back instead.
    func toggleFloatingPane() {
        if let entry = selectedTab.parked.first(where: { $0.showsCard }) { return unpark(entry.pane) }
        guard canParkFocusedPane, let pane = selectedTab.focusedPane else { return }
        removePane(pane, undoable: false, parking: true, asCard: true)
    }

    /// Float this pane (its header's button): it becomes the card, whatever card showed before.
    func floatPane(_ pane: TerminalView) {
        guard let tab = tab(containing: pane), tab === selectedTab else { return }
        reveal(pane, in: tab)
        guard canParkFocusedPane, selectedTab.focusedPane === pane else { return }
        removePane(pane, undoable: false, parking: true, asCard: true)
    }

    var hasFloatingPane: Bool { selectedTab.parked.contains { $0.showsCard } }
    /// The tab in front has its card on screen (`--ui-probe`).
    var showsFloatingCard: Bool { selectedTab.container?.card?.superview != nil }

    /// Make a tab's card match its parked panes: the pane that wants one gets it.
    private func syncCard(of tab: TerminalTab) {
        guard let container = tab.container else { return }
        guard let entry = tab.parked.first(where: { $0.showsCard }) else {
            if container.card != nil { container.hideCard() }
            return
        }
        guard container.card?.pane !== entry.pane else { return }
        let pane = entry.pane
        container.showCard(for: pane, corner: entry.cardCorner.flatMap(FloatingPaneCard.Corner.init(rawValue:)) ?? .bottomRight,
                           title: { [weak self, weak pane] in
                               guard let self, let pane else { return "" }
                               return self.title(ofPane: pane)
                           },
                           expand: { [weak self, weak pane] in pane.map { self?.unpark($0) } },
                           putAway: { [weak self, weak tab, weak pane] in
                               guard let tab, let pane, let i = tab.parked.firstIndex(where: { $0.pane === pane }) else { return }
                               tab.parked[i].showsCard = false
                               self?.updateSidebar()
                           },
                           moved: { [weak tab, weak pane] corner in
                               // Kept, so the card comes back where it was put.
                               guard let tab, let pane, let i = tab.parked.firstIndex(where: { $0.pane === pane }) else { return }
                               tab.parked[i].cardCorner = corner.rawValue
                           })
    }

    /// A document pane goes without asking (nothing runs in it).
    private func removeDocumentPane(_ doc: DocumentView) {
        guard let tab = tabs.first(where: { $0.documentPanes.contains { $0 === doc } }), let container = tab.container else { return }
        documentsClosed([doc])
        if tab.focusedDocument === doc { tab.focusedDocument = nil }
        let next = tab.focusedLeaf ?? container.views.first { $0 !== doc }
        container.remove(doc) { [weak self] in
            guard let self else { return }
            if tab === self.selectedTab, let next { self.focusLeaf(next) }
            self.updateDimming()
            self.updateSidebar()
        }
    }

    /// The document pane holding the keyboard focus, if one does.
    private var focusedDocumentPane: DocumentView? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        return selectedTab.documentPanes.first { responder.isDescendant(of: $0) }
    }

    /// Where focus is in the split: a document pane or the focused terminal.
    private var focusedLeaf: NSView? { focusedDocumentPane ?? selectedTab.focusedLeaf }

    private func focusLeaf(_ view: NSView) {
        if let doc = view as? DocumentView { window?.makeFirstResponder(doc.focusTarget) } else { window?.makeFirstResponder(view) }
    }

    /// Show a file as a pane beside the focused terminal (⌥-click in the
    /// sidebar, Open in Split): a Markdown preview next to its editor's shell.
    func openDocumentInSplit(_ url: URL, toward direction: SplitContainerView.Direction = .right, line: Int? = nil,
                             displayName: String? = nil, edit: Bool? = nil, waitToken: String? = nil) {
        let url = edit == true ? url : Blocks.address(forFile: url) ?? url
        if !selectedTab.isTerminal { select(terminalTab) }
        guard let container = selectedTab.container, let focused = selectedTab.focusedPane else { return }
        if let open = selectedTab.documentPanes.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            if edit == true { open.setEditing(true) }
            open.addWaiter(waitToken)
            if let line { open.reveal(line: line) }
            // Shown again: a web page or a diff is likely newer.
            if open.kind == .web || displayName != nil { open.reload() }
            return move(to: open)
        }
        let doc = makeDocument(url, edit: edit)
        doc.addWaiter(waitToken)
        if let displayName { doc.displayName = displayName }
        if let line { doc.reveal(line: line) }
        container.split(focused, with: doc, toward: direction)
        focusLeaf(doc)
        updateSidebar()
    }

    func makeDocument(_ url: URL, edit: Bool? = nil) -> DocumentView {
        let doc = DocumentView(url: url, theme: config.resolvedTheme, renderMarkdown: config.markdownRendered, edit: edit)
        doc.displayName = (NSApp.delegate as? AppDelegate)?.takeDisplayName(for: url)
        adopt(doc)
        return doc
    }

    private func adopt(_ doc: DocumentView) {
        doc.onOpenDocument = { [weak self] url in self?.openDocument(url) }
        doc.onTitleChange = { [weak self] in
            self?.updateTitle()
            self?.updateSidebar()
        }
        doc.onRequestClose = { [weak self] doc in self?.closeDocumentPane(doc) }
        doc.onOpenDocumentAt = { [weak self] url, line in self?.openDocument(url, line: line) }
        doc.onEditDocument = { [weak self] url in self?.openDocument(url, edit: true) }
        doc.onOpenBrowser = { [weak self] url in self?.openBrowser(url) }
        doc.onRevealPane = { [weak self] id in
            if (NSApp.delegate as? AppDelegate)?.reveal(paneID: id) != true { _ = self?.reveal(paneID: id) }
        }
        doc.onListTerminals = { [weak self] in
            // Every window's (the app's list; a probe has only this one).
            let windows = (NSApp.delegate as? AppDelegate)?.windowControllers ?? (self.map { [$0] } ?? [])
            return windows.flatMap(\.blockTerminals)
        }
        // Unsaved changes coming or going: the tab's name (a dot) and the header say so.
        doc.onEditingStateChange = { [weak self] _ in
            self?.updateTitle()
            self?.updateSidebar()
        }
    }

    // MARK: Blocks

    /// The Git block for the focused pane's repository (one tab per
    /// repository: opening it again shows that tab). Local only: a host's
    /// repositories aren't this Mac's git's.
    func openGit(beside: Bool = false) {
        guard host == nil else { return NSSound.beep() }
        let dir = focusedWorkingDirectory ?? NSHomeDirectory()
        let url = Blocks.url("git", ["root": GitCLI.root(of: dir) ?? dir])
        if beside { openDocumentInSplit(url) } else { openDocument(url) }
    }

    /// A browser (the browser block): `url` in a tab, or beside the terminal.
    /// Opening one already open shows it.
    func openBrowser(_ url: URL = URL(string: "about:blank")!, beside: Bool = false) {
        if beside { openDocumentInSplit(url) } else { openDocument(url, reuse: url.absoluteString != "about:blank") }
        // A fresh one starts at its address bar.
        if url.absoluteString == "about:blank" { DispatchQueue.main.async { self.frontBrowser?.focusAddress() } }
    }

    /// The browser `+browser` acts on: the one in front, or the window's last one.
    var frontBrowser: DocumentView? {
        if let doc = selectedDocument, doc.kind == .web { return doc }
        if let doc = selectedTab.documentPanes.last(where: { $0.kind == .web }) { return doc }
        return documents(in: everyTab).last { $0.kind == .web }
    }

    /// This window's terminals, for blocks (the task manager): shells and names.
    var blockTerminals: [BlockTerminal] {
        allPanes.compactMap { pane in
            // An exited pane's shell pid may be someone else's by now.
            guard pane.session.host == nil, !pane.session.hasExited, let pid = pane.session.shellPID else { return nil }
            let label = label(of: pane)
            return BlockTerminal(shell: pid, name: label.detail.isEmpty ? label.name : "\(label.name) — \(label.detail)",
                                 paneID: pane.paneID)
        }
    }

    /// The board of the focused pane's repository (or folder): its BOARD.md.
    func openBoard() {
        guard host == nil else { return NSSound.beep() }
        let file = BoardBlock.file(for: focusedWorkingDirectory ?? NSHomeDirectory())
        openDocument(Blocks.url("board", ["file": file.path]))
    }

    /// The task manager (one per window).
    func openTasks(beside: Bool = false) {
        let url = Blocks.url("tasks")
        if beside { openDocumentInSplit(url) } else { openDocument(url) }
    }

    /// Every block in the window, in any workspace (prompts reach them all).
    private var blocks: [DocumentView] { documents(in: everyTab).filter { $0.kind == .block } }

    // MARK: Unsaved changes (the editor)

    /// The editors among `tabs` (their documents, beside terminals or in tabs of their own).
    private func documents(in tabs: [TerminalTab]) -> [DocumentView] {
        tabs.flatMap { tab in (tab.document.map { [$0] } ?? []) + tab.documentPanes }
    }

    /// Before closing documents with unsaved changes: Save, Don't Save or
    /// Cancel. `proceed` runs once they're saved or let go.
    func confirmUnsaved(_ docs: [DocumentView], then proceed: @escaping () -> Void) {
        let dirty = docs.filter(\.hasUnsavedChanges)
        guard !dirty.isEmpty, let window else { return proceed() }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1 ? "Save changes to “\(dirty[0].url.lastPathComponent)”?"
            : "Save changes to \(dirty.count) files?"
        alert.informativeText = "Your changes are lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                Self.saveAll(dirty) { ok in if ok { proceed() } }
            case .alertThirdButtonReturn:
                proceed()
            default:
                break
            }
        }
    }

    /// Save each in turn; `done(false)` at the first that can't be saved.
    static func saveAll(_ docs: [DocumentView], done: @escaping (Bool) -> Void) {
        guard let first = docs.first else { return done(true) }
        first.save { ok in ok ? saveAll(Array(docs.dropFirst()), done: done) : done(false) }
    }

    /// Every document of the window with unsaved changes (quitting asks about them).
    var unsavedDocuments: [DocumentView] { documents(in: everyTab).filter(\.hasUnsavedChanges) }

    /// Documents that closed: whoever waits on them (`+open --wait`) goes on.
    private func documentsClosed(_ docs: [DocumentView]) {
        for doc in docs {
            doc.takeWaiters().forEach(EditorWait.post)
            doc.service?.suspend()
        }
    }

    /// A document pane's × or ⌘W (or vim's :q): asks first when it has
    /// unsaved changes. A document tab closes its tab.
    func closeDocumentPane(_ doc: DocumentView) {
        if let i = tabs.firstIndex(where: { $0.document === doc }) { return closeTab(at: i) }
        confirmUnsaved([doc]) { [weak self] in self?.removeDocumentPane(doc) }
    }

    /// What closing `tab` takes with it: its documents, or — the last
    /// terminal tab, which ends its workspace or the window — every
    /// document of the workspace.
    private func documentsClosing(with tab: TerminalTab) -> [DocumentView] {
        tabs.contains(where: { $0 !== tab && $0.isTerminal }) ? documents(in: [tab]) : documents(in: tabs)
    }

    /// ⌘W, the pane's × or its header's: a terminal pane closes (asking about
    /// a running program, and about the documents beside it when it's the
    /// last terminal and its tab goes with it).
    func closeTerminalPane(_ pane: TerminalView) {
        guard let tab = tab(containing: pane) else { return }
        let tabCloses = tab.panes.count == 1 && tab.parked.isEmpty
        confirmUnsaved(tabCloses ? documentsClosing(with: tab) : []) { [weak self] in
            self?.confirmIfBusy([pane], noun: "pane") { self?.removePane(pane, unsavedAsked: true) }
        }
    }

    private var firstResponderObservation: NSKeyValueObservation?

    /// Clicking into a document pane focuses it (a terminal reports its own
    /// focus through paneDidFocus).
    private func firstResponderChanged() {
        guard let responder = window?.firstResponder as? NSView,
              let doc = selectedTab.documentPanes.first(where: { responder.isDescendant(of: $0) }),
              selectedTab.focusedDocument !== doc else { return }
        selectedTab.focusedDocument = doc
        updateDimming()
        updateTitle()
    }

    @objc func equalizeSplits(_ sender: Any?) { selectedTab.container?.equalize() }

    func focus(_ direction: SplitContainerView.Direction) {
        guard let container = selectedTab.container, let focused = focusedLeaf else { return }
        if let next = container.neighbor(of: focused, direction) { move(to: next) }
    }

    func focusCycling(forward: Bool) {
        guard let container = selectedTab.container, let focused = focusedLeaf else { return }
        if let next = container.cycle(from: focused, forward: forward) { move(to: next) }
    }

    private func move(to pane: NSView) {
        // Moving to another pane leaves zoom, so it can be seen.
        if let container = selectedTab.container, let zoomed = container.zoomed { container.toggleZoom(zoomed) }
        focusLeaf(pane)
    }

    func resizeSplit(_ direction: SplitContainerView.Direction, by points: Int) {
        guard let focused = focusedLeaf else { return }
        selectedTab.container?.resize(focused, toward: direction, by: CGFloat(points))
    }

    func toggleZoom() {
        guard let focused = focusedLeaf else { return }
        selectedTab.container?.toggleZoom(focused)
        focusLeaf(focused)
        updateSidebar()  // the row says "zoomed"
    }

    /// Sidebar ▸ cd Here: type the command at the focused pane's prompt.
    func changeDirectory(to path: String) {
        if !selectedTab.isTerminal { select(terminalTab) }
        focusedTerminal.sendInput(" cd " + ShellQuote.quote(path) + "\n")
        window?.makeFirstResponder(focusedTerminal)
    }

    /// Sidebar ▸ Insert Path: into the terminal, bringing it forward.
    func insertInTerminal(_ text: String) {
        if !selectedTab.isTerminal { select(terminalTab) }
        focusedTerminal.sendInput(text)
        window?.makeFirstResponder(focusedTerminal)
    }

    private func paneDidFocus(_ pane: TerminalView) {
        Notifier.shared.clear(pane: pane.paneID)
        attention.remove(ObjectIdentifier(pane))
        guard let tab = tab(containing: pane) else { return }
        tab.focusedPane = pane
        tab.focusedDocument = nil
        tab.noteFocus(pane)
        if tab !== selectedTab { select(tab) }
        updateDimming()
        updateTitle()
        updateSidebar()
    }

    /// Split panes' hover tags follow what runs in them — beside other
    /// terminals or beside documents (one pane alone shows none) — and so
    /// do pane headers, where they show (`pane-headers`).
    private func updateNameTags(of tab: TerminalTab) {
        if let container = tab.container {
            container.headerSource = self
            container.headers = config.paneHeaders
            container.cardColor = config.resolvedTheme.background.nsColor.withAlphaComponent(config.backgroundOpacity)
            container.updateHeaders()
        }
        guard (tab.container?.views.count ?? 0) > 1 else { return }
        for pane in tab.panes {
            // A header already says it.
            if tab.container?.showsHeader(for: pane) == true { pane.nameTag = ""; continue }
            let label = label(of: pane)
            pane.nameTag = label.detail.isEmpty ? label.name : "\(label.name) — \(label.detail)"
        }
    }

    private func updateDimming() {
        for tab in everyTab {
            let split = (tab.container?.views.count ?? 0) > 1
            let focused = tab.focusedLeaf
            for pane in tab.panes {
                pane.setDimmed(split && pane !== focused)
                // A header has its own close button and says the pane's name.
                pane.showsCloseButton = split && tab.container?.showsHeader(for: pane) != true
                // Under a header, the header's top carries the mark.
                pane.showsFocusLine = split && pane === focused && tab.container?.showsHeader(for: pane) != true
            }
            updateNameTags(of: tab)
            for doc in tab.documentPanes {
                doc.setDimmed(split && doc !== focused, opacity: config.unfocusedSplitOpacity,
                              color: config.resolvedTheme.background.nsColor)
                doc.showsCloseButton = split && tab.container?.showsHeader(for: doc) != true
                doc.showsFocusLine = split && doc === focused && tab.container?.showsHeader(for: doc) != true
            }
        }
    }

    // MARK: Sidebar and inspector

    /// The side columns slide in and out — unless the user asked for less
    /// motion: then they just appear and go.
    func toggleSidebar() {
        if Motion.reduced { sidebarItem.isCollapsed.toggle() } else { splitController.toggleSidebar(nil) }
    }

    func toggleInspector() {
        if Motion.reduced { inspectorItem.isCollapsed.toggle() } else { splitController.toggleInspector(nil) }
    }

    var isSidebarShown: Bool { !sidebarItem.isCollapsed }

    /// show_tabs: the sidebar lists the tabs doing `activity`, or all of
    /// them again if it does already. The sidebar comes out for it.
    func showTabs(_ activity: TabActivity) {
        guard config.tabBar == .sidebar else { return }
        // Again while it shows: every tab. While the sidebar is away: it comes out with them.
        sidebar.show(activity: sidebar.activity == activity && isSidebarShown ? .all : activity)
        if !isSidebarShown, sidebar.activity != .all { toggleSidebar() }
    }

    /// Which tabs the sidebar lists; nil when the tabs are along the top.
    var sidebarActivity: TabActivity? { config.tabBar == .sidebar ? sidebar.activity : nil }

    /// The sidebar rows its filters leave showing (`--ui-probe`).
    var shownSidebarRows: [String] {
        let rows = sidebarRows
        return sidebar.shownRows.filter(rows.indices.contains).map { rows[$0] }
    }
    var isInspectorShown: Bool { !inspectorItem.isCollapsed }
    /// A pane of the tab in front fills it (toggle_split_zoom).
    var isZoomed: Bool { selectedTab.container?.zoomed != nil }

    /// Program states as they show (`--ui-probe`): the tab in front's mark,
    /// the Dock badge's count, the notification inbox, the sounds played.
    var statusSummary: String {
        "tab=\(status(of: selectedTab)?.state.name ?? "none") dock=\(attentionCount) "
            + "inbox=\(Notifier.shared.inbox.count) sounds=\(StatusSound.played.joined(separator: ","))"
    }

    /// What each sidebar row says (`--ui-probe` checks it).
    var sidebarRows: [String] {
        tabs.map { tab in
            let label = label(of: tab)
            var parts = [label.name]
            if !label.detail.isEmpty { parts.append(label.detail) }
            let count = tab.container?.views.count ?? 0
            if count > 1 { parts.append(tab.container?.zoomed != nil ? "\(count) panes, zoomed" : "\(count) panes") }
            if !tab.parked.isEmpty { parts.append("\(tab.parked.count) parked") }
            return parts.joined(separator: " · ")
        }
    }
    /// The top tabs' names as drawn, if they're in the window's bar (`--ui-probe`).
    var tabStripTitles: [String]? {
        guard config.tabBar == .top, window?.toolbar?.items.contains(where: { $0.view === tabStrip }) == true else { return nil }
        return tabStrip.shownNames
    }
    /// Panes (terminals and documents) in the tab in front.
    var selectedPaneCount: Int { selectedTab.container?.views.count ?? 0 }

    /// Push tab titles, statuses, and the focused pane's directory to the
    /// side columns. `force` re-roots the file tree even if unchanged.
    func updateSidebar(force: Bool = false) {
        // News of panes that are gone goes with them (whichever way they went).
        let live = Set(allPanes.map(ObjectIdentifier.init))
        attention.formIntersection(live)
        let infos = tabs.map { tab -> SidebarTabInfo in
            let label = self.label(of: tab)
            // The row's ring says it rang; no bell glyph in its name.
            return SidebarTabInfo(title: label.name, detail: label.detail, status: status(of: tab)?.state,
                                  paneCount: tab.container?.views.count ?? 0, parked: tab.parked.count,
                                  zoomed: tab.container?.zoomed != nil,
                                  documentURL: tab.document?.url, progress: progress(of: tab), tiles: tiles(of: tab),
                                  news: news(of: tab))
        }
        shownNews = infos.map(\.news)
        everyTab.forEach(updateNameTags(of:))
        everyTab.forEach(syncCard(of:))
        onLayoutChange?()
        scheduleTileRefresh()
        let selected = tabs.firstIndex { $0 === selectedTab } ?? 0
        sidebar.show(workspace: workspaces[activeWorkspace].name, of: workspaces.count)
        tabStrip.show(workspace: workspaces[activeWorkspace].name, of: workspaces.count)
        sidebar.show(tabsShown: config.tabBar == .sidebar)
        sidebar.show(tabs: infos, selected: selected)
        if config.tabBar == .top { tabStrip.show(tabs: infos, selected: selected) }
        // A host's directories aren't this Mac's: no file tree, no git status for them.
        let local = host == nil
        let dir = (local ? focusedWorkingDirectory : nil) ?? NSHomeDirectory()
        sidebar.show(filesShown: config.sidebarFiles && local)
        if local { sidebar.show(directory: dir, showHidden: config.sidebarShowHiddenFiles) }
        inspector.show(directory: local ? focusedWorkingDirectory : nil, shellPID: focusedTerminal.session.shellPID)
    }

    /// The tiles of a tab's panes: each pane's program (Claude Code,
    /// lazygit…), focused pane's last so it sits in front (Rex). A pane
    /// sitting at its prompt, and a document, have no program to show:
    /// the sidebar draws the tab's own glyph instead.
    ///
    /// Reads the cache only — updateSidebar runs on every focus change,
    /// title change and burst of output, and asking the kernel about a
    /// process is not something to do on the main thread that often.
    private func tiles(of tab: TerminalTab) -> [ProgramTile] {
        guard tab.document == nil else { return [] }
        let panes = tab.panes
        let focused = tab.focusedPane
        let ordered = panes.filter { $0 !== focused } + panes.filter { $0 === focused }
        return ordered.compactMap { programs[ObjectIdentifier($0.session)] }
    }

    /// What each session's foreground program is, as of the last poll.
    private var programs: [ObjectIdentifier: ProgramTile] = [:]
    /// Which process each answer was about. While the same group leads
    /// under the same name, the answer stands — unless it only named the
    /// runtime itself: the program it starts may not be up yet.
    private var identified: [ObjectIdentifier: Identified] = [:]
    private struct Identified {
        var pgid: pid_t
        var name: String
        var settled: Bool
    }
    private var tilesScheduled = false

    /// A program coming or going changes a tile without any callback, so
    /// a light poll keeps them current (GoRex's cadence). The kernel calls
    /// happen off the main thread; only the result comes back to it.
    private func scheduleTileRefresh() {
        guard !tilesScheduled else { return }
        // Local panes only: another machine's process table isn't ours to
        // read. With nothing to poll the chain stops, and whatever adds a
        // pane calls updateSidebar, which starts it again.
        let wanted: [(ObjectIdentifier, pid_t)] = everyTab.flatMap(\.everyPane).compactMap { pane in
            guard pane.session.host == nil, !pane.session.hasExited, let pid = pane.session.shellPID else { return nil }
            return (ObjectIdentifier(pane.session), pid)
        }
        guard !wanted.isEmpty else {
            programs.removeAll()
            identified.removeAll()
            return
        }
        tilesScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.tilesScheduled = false
            guard self.window?.isVisible == true else { return self.scheduleTileRefresh() }
            let known = self.programs, seen = self.identified
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var tiles: [ObjectIdentifier: ProgramTile] = [:]
                var about: [ObjectIdentifier: Identified] = [:]
                for (id, shell) in wanted {
                    guard let process = TerminalSession.foregroundProcess(ofShell: shell) else { continue }
                    if let last = seen[id], last.settled, last.pgid == process.pgid, last.name == process.name,
                       let tile = known[id] {
                        tiles[id] = tile
                        about[id] = last
                        continue
                    }
                    let program = TerminalSession.identify(process)
                    let badge = ProgramBadge.forProcess(program.name, arguments: program.arguments)
                    let plain = ProgramBadge.forProcess(process.name)
                    let isSSH = ["ssh", "mosh", "mosh-client"].contains(process.name.lowercased())
                    tiles[id] = ProgramTile(badge, host: isSSH ? ProgramTile.sshHost(program.arguments) : nil)
                    about[id] = Identified(pgid: process.pgid, name: process.name,
                                           settled: !ProgramBadge.runsAnotherProgram(process.name) || badge.name != plain.name)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    let changed = tiles != self.programs
                    self.programs = tiles
                    self.identified = about
                    // A background tab started or stopped printing: that's
                    // news its row shows, whether or not a tile changed.
                    let news = self.tabs.map(self.news(of:))
                    let newsChanged = news != self.shownNews
                    // updateSidebar schedules the next poll; with nothing
                    // new to draw, only the poll needs doing.
                    if changed || newsChanged { self.updateSidebar() } else { self.scheduleTileRefresh() }
                }
            }
        }
    }

    // MARK: Broadcast input, export, command output

    /// Window ▸ Broadcast Input: every pane of the tab gets what's typed in
    /// any of them (a fleet of servers over ssh). Their edges turn orange.
    func toggleBroadcastInput() {
        guard selectedTab.isTerminal else { return }
        selectedTab.broadcasting.toggle()
        updateBroadcastBorders()
        updateTitle()
    }

    var isBroadcasting: Bool { selectedTab.broadcasting }

    private func updateBroadcastBorders() {
        for tab in everyTab {
            for pane in tab.panes {
                pane.layer?.borderWidth = tab.broadcasting && tab.panes.count > 1 ? 2 : 0
                pane.layer?.borderColor = NSColor.systemOrange.cgColor
            }
        }
    }

    /// Ghostty's write_scrollback_file / write_selection_file: the text in a
    /// file, then `open` it (a Libertty tab), `copy` its path or `paste` it
    /// here; `save` asks where (File ▸ Export Text As…).
    func writeTextFile(selection: Bool, then: String) {
        let pane = focusedTerminal
        guard let text = selection ? pane.session.selectedText() : pane.session.scrollbackText(), !text.isEmpty else {
            return NSSound.beep()
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = (selection ? "selection" : "scrollback") + "-\(stamp).txt"
        if then == "save" {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.allowedContentTypes = [.plainText]
            guard let window else { return }
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Libertty", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return NSSound.beep() }
        switch then {
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        case "paste":
            pane.sendInput(ShellQuote.quote(url.path))
        default:
            openDocument(url)
        }
    }

    /// Edit ▸ Copy Output of Last Command (needs shell integration).
    func copyLastCommandOutput() {
        let pane = focusedTerminal
        guard pane.session.selectLastCommandOutput() else { return NSSound.beep() }
        pane.copy(nil)
        pane.setNeedsRender(force: true)
    }

    // MARK: Tab overview

    private var overview: TabOverviewView?

    /// ⌘⇧\ (Ghostty's toggle_tab_overview): every tab as a thumbnail.
    func toggleTabOverview() {
        if let overview { return closeOverview(overview, pick: nil) }
        guard tabs.count > 1 else { return }
        let cards = tabs.map { tab -> TabOverviewView.Card in
            TabOverviewView.Card(title: title(of: tab), image: thumbnail(of: tab),
                                 symbol: tab.document?.symbol ?? "apple.terminal",
                                 status: status(of: tab)?.state)
        }
        let view = TabOverviewView(cards: cards, selected: tabs.firstIndex { $0 === selectedTab } ?? 0)
        view.onPick = { [weak self, weak view] index in
            guard let self, let view else { return }
            self.closeOverview(view, pick: index)
        }
        view.frame = area.bounds
        view.autoresizingMask = [.width, .height]
        area.addSubview(view)
        overview = view
        for (i, tab) in tabs.enumerated() {
            if let doc = tab.document {
                doc.snapshot { [weak view] image in if let image { view?.setImage(image, at: i) } }
                continue
            }
            // Document panes render asynchronously: the card is redrawn with them.
            let docs = tab.documentPanes.filter { !$0.isHidden }
            guard !docs.isEmpty else { continue }
            var images: [ObjectIdentifier: CGImage] = [:]
            var remaining = docs.count
            for doc in docs {
                doc.snapshot { [weak self, weak view] image in
                    if let image { images[ObjectIdentifier(doc)] = image }
                    remaining -= 1
                    guard remaining == 0, let self, let view,
                          let card = self.thumbnail(of: tab, documents: images) else { return }
                    view.setImage(card, at: i)
                }
            }
        }
        window?.makeFirstResponder(view)
        view.animateIn()
    }

    /// Without animation, when what it shows is out of date.
    private func dismissOverview() {
        guard let overview else { return }
        overview.removeFromSuperview()
        self.overview = nil
    }

    private func closeOverview(_ view: TabOverviewView, pick: Int?) {
        view.removeFromSuperview()
        overview = nil
        if let pick { selectTab(at: pick) } else { window?.makeFirstResponder(selectedTab.focusTarget) }
    }

    /// A tab's panes composited as they're laid out (documents have none).
    private func thumbnail(of tab: TerminalTab, documents: [ObjectIdentifier: CGImage] = [:]) -> CGImage? {
        guard let container = tab.container else { return nil }
        // Only tabs laid out at today's size: laying one out just for a
        // picture would resize its programs (and a pane never on screen
        // doesn't know its backing scale yet). Those show their icon.
        let size = selectedTab.content.frame.size
        guard container.frame.size == size, container.panes.allSatisfy({ $0.window != nil || $0.renderedOnce }) else {
            return nil
        }
        let scale = window?.backingScaleFactor ?? 2
        guard size.width > 0, size.height > 0,
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setFillColor(config.resolvedTheme.background.nsColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        for view in container.views where !view.isHidden {
            let image: CGImage?
            if let pane = view as? TerminalView { image = pane.thumbnail() } else { image = documents[ObjectIdentifier(view)] }
            guard let image else { continue }
            let pane = view
            // The container is flipped; CoreGraphics' origin is bottom-left.
            let f = pane.frame
            ctx.draw(image, in: CGRect(x: f.minX * scale, y: (size.height - f.maxY) * scale,
                                       width: f.width * scale, height: f.height * scale))
        }
        return ctx.makeImage()
    }

    // MARK: Find in scrollback

    func startSearch(with text: String? = nil) {
        if let doc = searchDocument, doc.isEditing { return doc.openEditorFind() }
        area.findBar.field.placeholderString = searchDocument == nil ? "Find in scrollback" : "Find in document"
        area.findBar.isHidden = false
        area.needsLayout = true
        if let text { area.findBar.field.stringValue = text }
        window?.makeFirstResponder(area.findBar.field)
        area.findBar.field.currentEditor()?.selectAll(nil)
        find(area.findBar.field.stringValue)
    }

    /// Ghostty's search_selection: find what is selected.
    func searchSelection() {
        guard let text = focusedTerminal.session.selectedText(), !text.isEmpty else { return startSearch() }
        startSearch(with: text)
    }

    /// What ⌘F searches: the document in front, or the split's focused document pane.
    private var searchDocument: DocumentView? { selectedTab.document ?? selectedTab.focusedDocument }

    private func find(_ text: String) {
        if let doc = searchDocument {
            doc.find(text, backwards: false) { [weak self] found in
                self?.area.findBar.show(result: SearchResult(total: found ? 1 : 0, active: true))
                self?.area.findBar.showDocument(found: found, empty: text.isEmpty)
            }
            return
        }
        focusedTerminal.session.find(text)
        focusedTerminal.setNeedsRender(force: true)
        area.findBar.show(result: focusedTerminal.session.searchResult)
    }

    func findNext(older: Bool) {
        if area.findBar.isHidden { return startSearch() }
        if let doc = searchDocument {
            // The document's natural direction: older is up the page.
            doc.find(area.findBar.field.stringValue, backwards: !older) { [weak self] found in
                self?.area.findBar.showDocument(found: found, empty: false)
            }
            return
        }
        focusedTerminal.session.findNext(older: older)
        focusedTerminal.setNeedsRender(force: true)
        area.findBar.show(result: focusedTerminal.session.searchResult)
    }

    /// Returns false when no search was open (so Escape reaches the program).
    func endSearch() -> Bool {
        guard !area.findBar.isHidden else { return false }
        area.findBar.isHidden = true
        if let doc = searchDocument {
            window?.makeFirstResponder(doc.focusTarget)
            return true
        }
        focusedTerminal.session.endSearch()
        focusedTerminal.setNeedsRender(force: true)
        window?.makeFirstResponder(focusedTerminal)
        return true
    }

    var isSearching: Bool { !area.findBar.isHidden }

    // MARK: TerminalSessionDelegate

    func sessionLinkChanged(_ session: TerminalSession) {
        pane(for: session)?.updateLinkBanner()
        updateTitle()
    }

    func sessionNeedsRender(_ session: TerminalSession) {
        guard let pane = pane(for: session) else { return }
        pane.setNeedsRender()
        pane.announceOutputIfNeeded()
        // A program printing, not the shell echoing what you type at its
        // prompt (GoRex). The tile poll knows who's in front; a host's pane
        // has its prompt marks to say.
        if programs[ObjectIdentifier(session)] != nil || (session.host != nil && session.hasForegroundProgram) {
            pane.noteActivity()
        }
        if isSearching, pane === focusedTerminal {
            // New output may add matches; the count follows on the next frame.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.area.findBar.show(result: self.focusedTerminal.session.searchResult)
            }
        }
    }

    func sessionTitleChanged(_ session: TerminalSession, title: String) {
        updateTitle()
    }

    func sessionLabelChanged(_ session: TerminalSession) {
        updateTitle()
    }

    /// `bell-features`, as in Ghostty.
    func sessionBell(_ session: TerminalSession) {
        let features = config.bellFeatures
        let pane = pane(for: session)
        let looking = pane.map(isLookedAt) ?? false
        if features.contains("system") || features.contains("audio") { NSSound.beep() }
        if features.contains("attention"), !(NSApp.isActive && window?.isKeyWindow == true) {
            NSApp.requestUserAttention(.informationalRequest)
        }
        if features.contains("border"), let pane { pane.flashHalo(.systemYellow) }
        if features.contains("title"), !looking, let pane, let tab = owningTab(of: pane) {
            tab.rang = true
            updateTitle()
        }
        if !looking, let pane { markAttention(pane) }
    }

    // MARK: Tab news (GoRex): printing now, or something happened unseen

    /// Panes where something finished or rang while you weren't looking:
    /// their tab carries a ring until you focus the pane.
    private var attention: Set<ObjectIdentifier> = []
    /// Each tab's news as the sidebar shows it now.
    private var shownNews: [TabNews] = []

    private func markAttention(_ pane: TerminalView) {
        guard attention.insert(ObjectIdentifier(pane)).inserted else { return }
        updateSidebar()
    }

    /// How long after a program's last output its tab still shows it
    /// printing (the pane's dot, too).
    private static let printingFor: CFTimeInterval = 1.5

    /// What a tab did that you haven't seen. The tab in front shows none:
    /// you're looking at it.
    private func news(of tab: TerminalTab) -> TabNews {
        guard tab !== selectedTab || window?.isVisible != true else { return .none }
        // A parked build finishing counts: it's the reason to look.
        let panes = tab.everyPane
        if panes.contains(where: { attention.contains(ObjectIdentifier($0)) }) { return .attention }
        // The output clock, not render requests: a hidden tab never draws,
        // so after its first frame it stops asking to.
        let now = CACurrentMediaTime()
        let printing = panes.contains { pane in
            programs[ObjectIdentifier(pane.session)] != nil && now - pane.session.outputMark.time < Self.printingFor
        }
        return printing ? .printing : .none
    }

    func sessionProgramStatusChanged(_ session: TerminalSession) {
        updateTitle()
        notifyIfNeeded(session)
        onAttentionChange?()
        // Back at a prompt: the sidebar tree follows the focused pane's
        // folder, and the command may have changed files anywhere in it.
        if session === focusedTerminal.session {
            sidebar.refreshFilesAtPrompt()
            inspector.refreshGitAtPrompt()
        }
    }

    func sessionProgressChanged(_ session: TerminalSession) {
        updateSidebar()
        onAttentionChange?()
    }

    func sessionDesktopNotification(_ session: TerminalSession, title: String, body: String) {
        guard config.desktopNotifications, let pane = pane(for: session), !isLookedAt(pane) else { return }
        Notifier.shared.post(title: title.isEmpty ? self.title(ofPane: pane) : title, body: body, pane: pane.paneID)
    }

    func sessionCommandFinished(_ session: TerminalSession, command: String, exitCode: Int32?, duration: TimeInterval) {
        // It may have changed what a block shows (a commit, a branch), in any window.
        NotificationCenter.default.post(name: Blocks.commandFinished, object: nil)
        guard let pane = pane(for: session) else { return }
        PluginHost.shared.emit("commandFinished", ["command": command, "exitCode": exitCode.map { Int($0) } as Any? ?? NSNull(),
                                                   "duration": duration, "cwd": session.workingDirectory ?? ""])
        // A command that ran a while finished out of sight: its tab says so
        // until you look (a quick one isn't news).
        if duration >= 3, !isLookedAt(pane) { markAttention(pane) }
        guard duration >= config.notifyOnCommandFinishAfter else { return }
        switch config.notifyOnCommandFinish {
        case .never: return
        case .unfocused: if isLookedAt(pane) { return }
        case .always: break
        }
        let failed = (exitCode ?? 0) != 0
        let what = command.isEmpty ? "Command" : command
        let outcome = failed ? "failed (exit \(exitCode!))" : "finished"
        Notifier.shared.post(title: "\(what) \(outcome)",
                             body: "after \(Notifier.duration(duration)) · \(title(ofPane: pane))", pane: pane.paneID)
    }

    /// OSC 7501: a program that now needs you (or is done) while you're elsewhere.
    /// Its most urgent record decides; each way of telling you follows its own
    /// setting and its own memory: a notification and the pane's lit edge
    /// (`program-status-notify`), a sound (`program-status-sound`).
    private var notifiedRecords: [ObjectIdentifier: String] = [:]
    private var soundedRecords: [ObjectIdentifier: String] = [:]
    private func notifyIfNeeded(_ session: TerminalSession) {
        guard let pane = pane(for: session) else { return }
        let key = ObjectIdentifier(session)
        let top = session.programStatus.headline
        let looked = isLookedAt(pane)
        // Once per state change, not per report.
        let sound = top.flatMap { config.programStatusSound[$0.state] }
        if let top, let sound {
            if soundedRecords[key] != Self.signature(top) {
                soundedRecords[key] = Self.signature(top)
                if !looked { StatusSound.play(sound, for: pane.paneID) }
            }
        } else {
            soundedRecords[key] = nil
        }
        guard let top, config.programStatusNotify.contains(top.state) else { notifiedRecords[key] = nil; return }
        guard notifiedRecords[key] != Self.signature(top) else { return }
        notifiedRecords[key] = Self.signature(top)
        // In the window: the pane's edge lights up (unless you're typing in it).
        if pane !== focusedTerminal || !(window?.isKeyWindow ?? false) {
            pane.flashHalo(Self.color(for: top.state))
        }
        guard !looked, config.desktopNotifications else { return }
        let app = session.programStatus.effectiveApp(of: top)
        let what = [app, top.title].filter { !$0.isEmpty }.joined(separator: " · ")
        Notifier.shared.post(title: "\(Self.label(for: top))\(what.isEmpty ? "" : ": " + what)",
                             body: top.message.isEmpty ? title(ofPane: pane) : top.message, pane: pane.paneID,
                             sound: sound == nil)
    }

    private static func signature(_ record: ProgramStatusStore.Record) -> String {
        "\(record.id)|\(record.state)|\(record.title)|\(record.message)"
    }

    /// The settings changed: what programs are in now isn't news, even in a
    /// state a setting just took in — only what they go on to do is.
    private func rememberProgramStates() {
        for pane in allPanes {
            let key = ObjectIdentifier(pane.session)
            let top = pane.session.programStatus.headline
            notifiedRecords[key] = top.flatMap { config.programStatusNotify.contains($0.state) ? Self.signature($0) : nil }
            soundedRecords[key] = top.flatMap { config.programStatusSound[$0.state] != nil ? Self.signature($0) : nil }
        }
    }

    /// The user can see this pane right now: Libertty is active, its window key,
    /// its tab selected.
    private func isLookedAt(_ pane: TerminalView) -> Bool {
        NSApp.isActive && window?.isKeyWindow == true
            && (selectedTab.panes.contains { $0 === pane } || selectedTab.parked.contains { $0.showsCard && $0.pane === pane })
    }

    /// Window ▸ Picture in Picture: the focused pane in a floating window.
    func togglePictureInPicture() {
        if !selectedTab.isTerminal { select(terminalTab) }
        let pane = focusedTerminal
        MainActor.assumeIsolated {
            // Whichever window has the pane by then (it may move to another).
            PictureInPicture.toggle(pane, title: { [weak pane] in
                pane.map(Self.title(ofPane:)) ?? ""
            }, reveal: { [weak self, weak pane] in
                guard let pane else { return }
                Probe.activateApp()
                if let app = NSApp.delegate as? AppDelegate { _ = app.reveal(paneID: pane.paneID) } else { _ = self?.reveal(paneID: pane.paneID) }
            })
        }
    }

    /// This window's panes, for Web Access.
    var webPanes: [WebPane] {
        let name = window?.title ?? "Libertty"
        return workspaces.enumerated().flatMap { w, workspace in
            let tabs = w == activeWorkspace ? self.tabs : workspace.tabs
            let place = workspaces.count > 1 ? "\(name) · \(workspace.name)" : name
            return tabs.enumerated().flatMap { index, tab in
                tab.everyPane.map { pane in
                    WebPane(id: pane.paneID, title: title(ofPane: pane), place: tabs.count > 1 ? "\(place), tab \(index + 1)" : place,
                            host: host?.destination, session: pane.session)
                }
            }
        }
    }

    private func title(ofPane pane: TerminalView) -> String { Self.title(ofPane: pane) }

    private static func title(ofPane pane: TerminalView) -> String {
        let program = ProgramStatusStore.sanitize(pane.session.title)
        if !program.isEmpty { return program }
        return pane.session.workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Libertty"
    }

    /// A notification was clicked: bring its pane forward. Returns whether it is here.
    func reveal(paneID: String) -> Bool {
        guard let pane = allPanes.first(where: { $0.paneID == paneID }),
              let tab = everyTab.first(where: { $0.panes.contains { $0 === pane } || $0.parked.contains { $0.pane === pane } })
        else { return false }
        return reveal(pane, in: tab)
    }

    /// Bring a tab forward, and in a split one of its panes, a terminal or
    /// a document (Go to Pane): behind a zoomed pane it couldn't be seen, so
    /// back to the split.
    @discardableResult
    func reveal(_ leaf: NSView?, in tab: TerminalTab) -> Bool {
        // A tab of another workspace brings its workspace forward.
        if !tabs.contains(where: { $0 === tab }), let i = workspaces.firstIndex(where: { $0.tabs.contains { $0 === tab } }) {
            switchWorkspace(to: i)
        }
        guard tabs.contains(where: { $0 === tab }) else { return false }
        // A parked pane comes back to be seen (a notification names it).
        if let pane = leaf as? TerminalView, tab.parked.contains(where: { $0.pane === pane }) {
            select(tab)
            unpark(pane)
            window?.makeKeyAndOrderFront(nil)
            return true
        }
        select(tab)
        if let leaf, let container = tab.container, container.views.contains(where: { $0 === leaf }) {
            if let zoomed = container.zoomed, zoomed !== leaf { container.toggleZoom(zoomed) }
            focusLeaf(leaf)
        }
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    /// The glyph for what a pane runs (its tab's icon, for the palette).
    func symbol(of pane: TerminalView) -> String {
        programs[ObjectIdentifier(pane.session)]?.symbol ?? "apple.terminal"
    }

    /// How many panes have a program in a state the Dock badge counts
    /// (`program-status-dock-badge`; by default, waiting for you).
    var attentionCount: Int {
        allPanes.filter { $0.session.programStatus.headline(among: config.programStatusDockBadge) != nil }.count
    }
    var onAttentionChange: (() -> Void)?
    /// Tabs, splits, names or focus changed: the saved layout should follow
    /// soon, so a crash right after a split doesn't bring the panes back as
    /// separate tabs (GoRex saves within a second of a change).
    var onLayoutChange: (() -> Void)?

    func sessionExited(_ session: TerminalSession, status: Int32) {
        guard let pane = pane(for: session) else { return }
        // In a workspace that isn't showing: its panes are cleared away when
        // it comes back — unless nothing of it is left running.
        if let i = workspaces.indices.first(where: {
            $0 != activeWorkspace && workspaces[$0].tabs.contains { $0.everyPane.contains { $0 === pane } }
        }) {
            // All its programs gone: it goes too — unless it holds unsaved text.
            if workspaces[i].tabs.flatMap(\.everyPane).allSatisfy({ $0.session.hasExited }),
               !documents(in: workspaces[i].tabs).contains(where: \.hasUnsavedChanges) {
                endWorkspace(workspaces[i].id, undoable: false)
            }
            return
        }
        // A parked program ended: nothing to bring back.
        if let tab = everyTab.first(where: { $0.parked.contains { $0.pane === pane } }) {
            tab.parked.removeAll { $0.pane === pane }
            pane.isParked = false
            PictureInPicture.paneClosed(pane)
            Notifier.shared.clear(pane: pane.paneID)
            updateSidebar()
            return
        }
        // A program that failed at once (or any, with wait-after-command or
        // --keep-open) leaves its pane, so what it said can be read; a key
        // in it closes it (Ghostty, Rex).
        let ran = session.startedAt.map { CACurrentMediaTime() - $0 }
        let code = PTY.exitCode(fromWaitStatus: status)
        let failedAtOnce = code != 0 && config.abnormalCommandExitRuntime > 0
            && (ran.map { $0 * 1000 < Double(config.abnormalCommandExitRuntime) } ?? false)
        if !Self.oneShot, failedAtOnce || config.waitAfterCommand || session.keepsPaneAfterExit, tab(containing: pane) != nil {
            let after = ran.map { String(format: " after %.2f s", $0) } ?? ""
            session.note("[Exited with status \(code)\(after). Press any key to close this pane.]")
            pane.closesOnKey = true
            updateSidebar()
            return
        }
        // The program ended by itself: nothing to bring back.
        removePane(pane, undoable: false)
    }

    func sessionWorkingDirectoryChanged(_ session: TerminalSession) {
        // This Mac's folders, for Go to Directory (a host's are that machine's).
        if session.host == nil, let directory = session.workingDirectory { RecentFolders.shared.record(directory) }
        updateTitle()
        if session === focusedTerminal.session { updateSidebar() } else { updateSidebar(force: false) }
    }

    // MARK: Title & program status

    /// A tab's name: its override, else the focused program's title (OSC
    /// 0/2), else its directory.
    private func title(of tab: TerminalTab) -> String {
        let name = plainTitle(of: tab)
        return tab.rang ? "🔔 " + name : name
    }

    private func plainTitle(of tab: TerminalTab) -> String {
        let label = self.label(of: tab)
        return label.detail.isEmpty ? label.name : "\(label.name) — \(label.detail)"
    }

    /// How a tab names itself (GoRex): what runs in its focused pane, and
    /// where. A program's own title wins (an editor names its file); a
    /// title the shell set ("user@host:~/src") says less than the program
    /// and its folder do. ssh says where it went. Overrides win over all.
    func label(of tab: TerminalTab) -> (name: String, detail: String) {
        if !tab.titleOverride.isEmpty { return (tab.titleOverride, "") }
        if !tab.paneTitleOverride.isEmpty { return (tab.paneTitleOverride, "") }
        guard let pane = tab.focusedPane else { return (tab.document?.title ?? "Libertty", "") }
        return label(of: pane)
    }

    func label(of pane: TerminalView) -> (name: String, detail: String) {
        let session = pane.session
        let directory = Self.shortDirectory(session.workingDirectory)
        // Named (`+rename-session`, an agent naming its task): that, and what runs there.
        if !session.label.isEmpty {
            return (session.label, programs[ObjectIdentifier(session)]?.name ?? directory)
        }
        let title = ProgramStatusStore.sanitize(session.title).trimmingCharacters(in: .whitespaces)
        let ownTitle = !title.isEmpty && !Self.isShellTitle(title, directory: session.workingDirectory)
        if let tile = programs[ObjectIdentifier(session)] {
            if let host = tile.host { return ("SSH", host) }
            if ownTitle { return (title, "") }
            return (tile.name, directory)
        }
        // At a prompt: the shell's own title says no more than the folder —
        // unless where it is isn't known, when it's the best name there is.
        if ownTitle { return (title, "") }
        if !directory.isEmpty { return (directory, "") }
        return (title.isEmpty ? "Libertty" : Self.place(inShellTitle: title), "")
    }

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
    private static func place(inShellTitle title: String) -> String {
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

    /// A tab's progress: a pane's OSC 9;4 report, else an OSC 7501 record's.
    private func progress(of tab: TerminalTab) -> TerminalProgress? {
        if let p = tab.everyPane.compactMap(\.session.progress).first { return p }
        if let record = status(of: tab), record.state == .working, let percent = record.progress {
            return TerminalProgress(state: .normal, percent: percent)
        }
        return nil
    }

    /// The most urgent OSC 7501 record among a tab's panes, of the states
    /// tabs show (`program-status-indicator`).
    private func status(of tab: TerminalTab) -> ProgramStatusStore.Record? {
        tab.everyPane.compactMap { $0.session.programStatus.headline(among: config.programStatusIndicator) }
            .max { $0.state < $1.state }
    }

    /// The window title is the selected tab's. The subtitle shows the most
    /// urgent OSC 7501 record across every tab, so an agent waiting in a
    /// background tab still shows. Program text is untrusted, so it is
    /// sanitized by the store and shown as plain text.
    private func updateTitle() {
        guard let window else { return }
        let tab = selectedTab
        window.title = tab.paneTitleOverride.isEmpty ? title(of: tab) : tab.paneTitleOverride
        // A document tab gets the proxy icon (⌘-click for its folders).
        window.representedURL = tab.document?.url

        if selectedTab.broadcasting {
            window.subtitle = "Broadcasting input to \(selectedTab.panes.count) panes"
            updateSidebar()
            return
        }
        if let host {
            // Which machine this is, always.
            let down = allPanes.contains { !$0.session.linkUp }
            window.subtitle = host.destination + (down ? " · reconnecting…" : "")
            hostChip.refresh(host: host, linkUp: !down)
            updateSidebar()
            return
        }
        hostChip.refresh(host: nil, linkUp: true)
        let candidates = allPanes.compactMap { pane in
            pane.session.programStatus.headline(among: config.programStatusIndicator).map { (pane.session.programStatus, $0) }
        }
        if let (store, record) = candidates.max(by: { $0.1.state < $1.1.state }) {
            let app = store.effectiveApp(of: record)
            var parts: [String] = [Self.label(for: record)]
            if !app.isEmpty { parts.append(app) }
            if !record.title.isEmpty { parts.append(record.title) }
            if !record.message.isEmpty { parts.append(record.message) }
            if let progress = record.progress { parts.append("\(progress)%") }
            window.subtitle = parts.joined(separator: " · ")
        } else {
            window.subtitle = ""
        }
        updateSidebar()
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

    private static func label(for record: ProgramStatusStore.Record) -> String {
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

    /// View ▸ Change Terminal Title / Change Tab Title (Ghostty's
    /// prompt_surface_title / prompt_tab_title). Empty goes back to the
    /// program's title.
    func promptTitle(tab isTab: Bool) {
        guard let window else { return }
        // A tab is renamed in place where it's listed, when that shows.
        if isTab, let i = tabs.firstIndex(where: { $0 === selectedTab }) {
            if config.tabBar == .top, tabStripTitles != nil { return tabStrip.beginRename(at: i) }
            // (Not a tab the sidebar's filters fold away: the alert, then.)
            if config.tabBar == .sidebar, isSidebarShown, sidebar.shows(row: i) { return sidebar.beginRename(row: i) }
        }
        let tab = selectedTab
        let alert = NSAlert()
        alert.messageText = isTab ? "Change Tab Title" : "Change Terminal Title"
        alert.informativeText = "Leave empty to use the title the program sets."
        let field = NSTextField(string: isTab ? tab.titleOverride : tab.paneTitleOverride)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = window.title
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let text = ProgramStatusStore.sanitize(field.stringValue)
            if isTab { tab.titleOverride = text } else { tab.paneTitleOverride = text }
            self.updateTitle()
            self.window?.makeFirstResponder(tab.focusTarget)
        }
    }

    // MARK: Workspaces (named sessions per window)

    static let defaultWorkspaceName = "Default"

    func syncActiveWorkspace() {
        guard workspaces.indices.contains(activeWorkspace) else { return }
        workspaces[activeWorkspace].tabs = tabs
        workspaces[activeWorkspace].selected = selectedTab
        workspaces[activeWorkspace].terminal = terminalTab
    }

    /// Show workspace `index`: its tabs replace the ones showing; the
    /// programs of both keep running.
    func switchWorkspace(to index: Int) {
        guard workspaces.indices.contains(index), index != activeWorkspace else { return }
        dismissOverview()
        if area.findBar.isHidden == false { _ = endSearch() }
        syncActiveWorkspace()
        activeWorkspace = index
        let next = workspaces[index]
        tabs = next.tabs
        selectedTab = next.selected
        terminalTab = next.terminal
        area.show(selectedTab.content)
        selectedTab.container?.layoutPanes()
        selectedTab.panes.forEach { $0.setNeedsRender(force: true) }
        window?.makeFirstResponder(selectedTab.focusTarget)
        // Programs that ended while it was away take their panes with them.
        tabs.forEach(clearExited(in:))
        updateDimming()
        updateTitle()
        updateSidebar(force: true)
    }

    /// Panes whose programs ended while nobody was watching (another
    /// workspace, a closed tab waiting for Undo): parked ones go quietly,
    /// shown ones as if they had exited just now.
    private func clearExited(in tab: TerminalTab) {
        for entry in tab.parked where entry.pane.session.hasExited {
            entry.pane.isParked = false
            PictureInPicture.paneClosed(entry.pane)
            Notifier.shared.clear(pane: entry.pane.paneID)
        }
        tab.parked.removeAll { $0.pane.session.hasExited }
        // A pane kept to show how its program ended stays until a key closes it.
        for pane in tab.panes where pane.session.hasExited && !pane.closesOnKey { removePane(pane, undoable: false) }
    }

    func switchWorkspace(offset: Int) {
        guard workspaces.count > 1 else { return }
        switchWorkspace(to: (activeWorkspace + offset + workspaces.count) % workspaces.count)
    }

    /// A workspace of its own: a new shell in the focused pane's folder.
    /// `name` empty: "Workspace N".
    @discardableResult
    func newWorkspace(named name: String = "") -> Bool {
        do {
            let s = focusedTerminal.session.size
            let pane = try Self.makePane(config: config, cols: Int(s.cols), rows: Int(s.rows))
            pane.fontSize = focusedTerminal.fontSize
            adopt(pane)
            try startSession(of: pane, command: nil, workingDirectory: focusedWorkingDirectory)
            let tab = TerminalTab(pane: pane)
            syncActiveWorkspace()
            let taken = Set(workspaceNames)
            var label = ProgramStatusStore.sanitize(name)
            if label.isEmpty {
                var n = workspaces.count + 1
                while taken.contains("Workspace \(n)") { n += 1 }
                label = "Workspace \(n)"
            } else if taken.contains(label) {
                var n = 2
                while taken.contains("\(label) \(n)") { n += 1 }
                label = "\(label) \(n)"
            }
            workspaces.insert(Workspace(name: label, tabs: [tab], selected: tab, terminal: tab), at: activeWorkspace + 1)
            switchWorkspace(to: activeWorkspace + 1)
            return true
        } catch {
            showError(error)
            return false
        }
    }

    func renameWorkspace(at index: Int, to name: String) {
        guard workspaces.indices.contains(index) else { return }
        let label = ProgramStatusStore.sanitize(name)
        guard !label.isEmpty, !workspaces.enumerated().contains(where: { $0.offset != index && $0.element.name == label }) else { return }
        workspaces[index].name = label
        updateSidebar()
    }

    /// Ask for a workspace's name (a sheet), then rename it.
    func promptWorkspaceName(creating: Bool) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = creating ? "New Workspace" : "Rename Workspace"
        alert.informativeText = "A workspace is a named set of tabs in this window; the others keep running."
        let field = NSTextField(string: creating ? "" : workspaces[activeWorkspace].name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = creating ? "Workspace \(workspaces.count + 1)" : ""
        alert.accessoryView = field
        alert.addButton(withTitle: creating ? "Create" : "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if creating { self.newWorkspace(named: field.stringValue) } else { self.renameWorkspace(at: self.activeWorkspace, to: field.stringValue) }
        }
    }

    func closeWorkspace(at index: Int) {
        guard workspaces.count > 1, workspaces.indices.contains(index) else { return }
        let doomed = index == activeWorkspace ? tabs : workspaces[index].tabs
        let id = workspaces[index].id
        confirmUnsaved(documents(in: doomed)) { [weak self] in
            self?.confirmIfBusy(doomed.flatMap(\.everyPane), noun: "workspace") { [weak self] in self?.endWorkspace(id) }
        }
    }

    /// It goes and the window shows a neighbor; its programs end — at
    /// once, or with `undoable` once Undo can't bring it back (undo-timeout).
    private func endWorkspace(_ id: UUID, undoable: Bool = true) {
        guard workspaces.count > 1, let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        if index == activeWorkspace { switchWorkspace(to: index > 0 ? index - 1 : 1) }
        let gone = workspaces.remove(at: index)
        if index < activeWorkspace { activeWorkspace -= 1 }
        for tab in gone.tabs {
            tab.content.removeFromSuperview()
            tab.everyPane.forEach { PictureInPicture.paneClosed($0) }
        }
        documentsClosed(documents(in: gone.tabs))
        updateSidebar(force: true)
        let panes = gone.tabs.flatMap(\.everyPane)
        func end() {
            panes.forEach {
                Notifier.shared.clear(pane: $0.paneID)
                $0.session.terminate()
            }
        }
        guard undoable, CloseUndo.shared.enabled, panes.contains(where: { !$0.session.hasExited }) else { return end() }
        CloseUndo.shared.closed("Close Workspace", restore: { [weak self] in
            guard let self, self.window?.isVisible == true, panes.contains(where: { !$0.session.hasExited }) else { return nil }
            self.syncActiveWorkspace()
            self.workspaces.insert(gone, at: min(index, self.workspaces.count))
            if index <= self.activeWorkspace { self.activeWorkspace += 1 }
            self.switchWorkspace(to: min(index, self.workspaces.count - 1))
            return { [weak self] in self?.endWorkspace(gone.id) }
        }, expire: { end() })
    }

    /// The workspace menu (the sidebar's header, the top bar's chip).
    func workspaceMenu() -> NSMenu {
        let menu = NSMenu()
        syncActiveWorkspace()
        for (i, w) in workspaces.enumerated() {
            let item = ClosureMenuItem(title: w.name) { [weak self] in self?.switchWorkspace(to: i) }
            let count = i == activeWorkspace ? tabs.count : w.tabs.count
            item.state = i == activeWorkspace ? .on : .off
            item.toolTip = "\(count) tab\(count == 1 ? "" : "s")"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "New Workspace…") { [weak self] in self?.promptWorkspaceName(creating: true) })
        menu.addItem(ClosureMenuItem(title: "Rename Workspace…") { [weak self] in self?.promptWorkspaceName(creating: false) })
        let close = ClosureMenuItem(title: "Close Workspace") { [weak self] in
            guard let self else { return }
            self.closeWorkspace(at: self.activeWorkspace)
        }
        close.isEnabled = workspaces.count > 1
        menu.addItem(close)
        return menu
    }

    /// Pop the workspace menu under `view`.
    func showWorkspaceMenu(from view: NSView) {
        workspaceMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 2 : -2), in: view)
    }

    // MARK: Window

    func toggleFloatOnTop() {
        guard let window else { return }
        window.level = window.level == .floating ? .normal : .floating
    }

    var isFloatingOnTop: Bool { window?.level == .floating }

    /// Window ▸ Return To Default Size: the grid back to `window-columns` ×
    /// `window-rows`, keeping the side columns as they are.
    func resetWindowSize() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let grid = focusedTerminal.contentSize(cols: config.windowColumns, rows: config.windowRows)
        let sides = window.frame.width - area.frame.width
        let titlebar = window.frame.height - window.contentLayoutRect.height
        var frame = window.frame
        let size = NSSize(width: grid.width + sides, height: grid.height + titlebar)
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true, animate: !Motion.reduced)
    }

    /// Close Window (close_window): the window and all its tabs.
    func closeWindowAndTabs() { window?.performClose(nil) }

    /// Set when the user already confirmed closing (a whole window or all of them).
    var skipCloseConfirmation = false
    var hasRunningPrograms: Bool { allPanes.contains { $0.session.hasForegroundProgram } }

    // MARK: Closing

    private func confirmIfBusy(_ panes: [TerminalView], noun: String, verb: String = "Close",
                               then proceed: @escaping () -> Void) {
        guard config.confirmClose, let window, panes.contains(where: { $0.session.hasForegroundProgram }) else {
            proceed()
            return
        }
        let alert = NSAlert()
        alert.messageText = "\(verb) this \(noun)?"
        alert.informativeText = "A program is still running and will be ended."
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        focusedTerminal.session.setFocused(true)
        selectedTab.panes.forEach { $0.setNeedsRender(force: true) }
        updateSidebar()
    }

    func windowWillEnterFullScreen(_ notification: Notification) { savedNonFullScreenFrame = window?.frame }
    func windowDidEnterFullScreen(_ notification: Notification) { allPanes.forEach { $0.updateDisplaySync() } }
    func windowDidExitFullScreen(_ notification: Notification) { allPanes.forEach { $0.updateDisplaySync() } }

    func windowDidResignKey(_ notification: Notification) {
        selectedTab.panes.forEach { $0.setNeedsRender(force: true) }
        // The quick terminal goes away when you click elsewhere (not for its own sheets).
        if isQuick, config.quickTerminalAutohide, window?.attachedSheet == nil, window?.isVisible == true {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.isKeyWindow == false, NSApp.modalWindow == nil else { return }
                QuickTerminal.shared.hide(restoreFocus: false)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !skipCloseConfirmation, !unsavedConfirmed, !unsavedDocuments.isEmpty {
            confirmUnsaved(unsavedDocuments) { [weak self] in
                self?.unsavedConfirmed = true
                sender.performClose(nil)
            }
            return false
        }
        // Asked once for this close; the next close asks again.
        unsavedConfirmed = false
        if !skipCloseConfirmation, config.confirmClose, hasRunningPrograms {
            confirmIfBusy(allPanes, noun: "window") { [weak self] in
                self?.skipCloseConfirmation = true
                _ = self?.windowShouldClose(sender)
            }
            return false
        }
        // Undoable: hide it for `undo-timeout`, then really close it.
        guard CloseUndo.shared.enabled, !isQuick, allPanes.contains(where: { !$0.session.hasExited }) else {
            if skipCloseConfirmation { sender.close() }
            return !skipCloseConfirmation
        }
        sender.orderOut(nil)
        onHide?(self)
        // Strong: while it can come back, nothing else keeps this controller alive.
        CloseUndo.shared.closed("Close Window", restore: { [self] in
            guard let window = self.window else { return nil }
            // Back as it was: its next close asks as any close does.
            self.skipCloseConfirmation = false
            self.onUnhide?(self)
            window.makeKeyAndOrderFront(nil)
            // Redo closes it again, the usual way; it doesn't keep the window alive.
            return { [weak self] in
                guard let self, let window = self.window else { return }
                _ = self.windowShouldClose(window)
            }
        }, expire: {
            self.skipCloseConfirmation = true
            self.window?.close()
        })
        return false
    }

    /// Unsaved documents were saved or let go for this close.
    private var unsavedConfirmed = false

    /// The window was hidden for undo / brought back (the app keeps its list).
    var onHide: ((TerminalWindowController) -> Void)?
    var onUnhide: ((TerminalWindowController) -> Void)?

    /// Every window shares the close-undo stack (Edit ▸ Undo Close Window).
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        MainActor.assumeIsolated { CloseUndo.shared.manager }
    }

    func windowWillClose(_ notification: Notification) {
        documentsClosed(documents(in: everyTab))
        if let observer = inboxObserver { NotificationCenter.default.removeObserver(observer) }
        inboxObserver = nil
        allPanes.forEach { $0.session.terminate() }
        onClose?(self)
    }

    // MARK: Toolbar (Tern: actions on the right; Otty: + and the sidebar toggle over the sidebar)

    private static let newTabItem = NSToolbarItem.Identifier("libertty.newTab")
    private static let splitRightItem = NSToolbarItem.Identifier("libertty.splitRight")
    private static let splitDownItem = NSToolbarItem.Identifier("libertty.splitDown")
    private static let findItem = NSToolbarItem.Identifier("libertty.find")
    private static let inboxItem = NSToolbarItem.Identifier("libertty.inbox")
    private static let hostItem = NSToolbarItem.Identifier("libertty.host")
    private static let paletteItem = NSToolbarItem.Identifier("libertty.palette")
    private static let tabsItem = NSToolbarItem.Identifier("libertty.tabs")
    /// One toolbar per `tab-bar` mode, so each keeps its own customization.
    private static let sidebarToolbar = "libertty.window.2", topToolbar = "libertty.window.top"
    private lazy var hostChip = HostChip()
    private lazy var tabStrip: TabStrip = {
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

    /// The toolbar for the `tab-bar` mode, unless it's already there. The
    /// delegate is set before it joins the window: that's when it asks for
    /// its items.
    private func installToolbar() {
        guard let window, !isQuick else { return }
        let id = config.tabBar == .top ? Self.topToolbar : Self.sidebarToolbar
        guard window.toolbar?.identifier != id else { return }
        let toolbar = NSToolbar(identifier: id)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        // A slim bar, as Tern's (40 points): it's controls, not a title.
        window.toolbarStyle = .unifiedCompact
    }
    private lazy var inboxPopover: NSPopover = {
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
    private var inboxObserver: AnyObject?

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if toolbar.identifier == Self.topToolbar {
            // The tabs take the bar's middle (their + after the last), the
            // controls the right (Tern's horizontal tabs).
            return [.toggleSidebar, .sidebarTrackingSeparator, Self.tabsItem,
                    Self.splitRightItem, Self.splitDownItem, Self.findItem, Self.inboxItem,
                    .inspectorTrackingSeparator, .flexibleSpace, Self.hostItem, .toggleInspector]
        }
        return [.flexibleSpace, Self.newTabItem, .toggleSidebar, .sidebarTrackingSeparator,
                .flexibleSpace, Self.splitRightItem, Self.splitDownItem, Self.findItem, Self.inboxItem,
                .inspectorTrackingSeparator, .flexibleSpace, Self.hostItem, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The palette's button is there for Customize Toolbar, not by default.
        var extra: [NSToolbarItem.Identifier] = [.space, .flexibleSpace, Self.paletteItem]
        if toolbar.identifier == Self.topToolbar { extra.append(Self.newTabItem) }
        return toolbarDefaultItemIdentifiers(toolbar) + extra
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func item(_ label: String, _ symbol: String, _ action: Selector, keys: Action? = nil) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            // The keys too, as the user has them bound (GoRex's tooltips).
            item.toolTip = keys.map { Self.tip(label, $0) } ?? label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        }
        switch id {
        case Self.tabsItem:
            let tabs = NSToolbarItem(itemIdentifier: id)
            tabs.label = "Tabs"
            tabs.visibilityPriority = .high
            // The strip is one view: Customize Toolbar's palette gets a picture of it.
            if flag {
                tabs.view = tabStrip
            } else {
                tabs.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Tabs")
            }
            return tabs
        case Self.hostItem:
            let chip = NSToolbarItem(itemIdentifier: id)
            chip.label = "Host"
            chip.view = hostChip.view
            return chip
        case Self.newTabItem: return item("New Tab", "plus", #selector(toolbarNewTab(_:)), keys: .newTab)
        case Self.splitRightItem: return item("Split Right", "rectangle.split.2x1", #selector(splitRight(_:)), keys: .newSplit(.right))
        case Self.splitDownItem: return item("Split Down", "rectangle.split.1x2", #selector(splitDown(_:)), keys: .newSplit(.down))
        case Self.findItem: return item("Find", "magnifyingglass", #selector(toolbarFind(_:)), keys: .startSearch)
        case Self.paletteItem:
            return item("Command Palette", "filemenu.and.selection", #selector(toolbarPalette(_:)), keys: .toggleCommandPalette)
        case Self.inboxItem:
            let bell = item("Notifications", "bell", #selector(toolbarInbox(_:)))
            // The bar's own bell (not Customize Toolbar's picture of it)
            // follows the inbox; a new bar's replaces the old one's.
            guard flag else { return bell }
            if Notifier.shared.unread > 0 {
                bell.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "Notifications")
            }
            if let old = inboxObserver { NotificationCenter.default.removeObserver(old) }
            inboxObserver = NotificationCenter.default.addObserver(forName: Notifier.inboxChanged, object: nil,
                                                                   queue: .main) { [weak bell] _ in
                let unread = Notifier.shared.unread > 0
                bell?.image = NSImage(systemSymbolName: unread ? "bell.badge" : "bell", accessibilityDescription: "Notifications")
            }
            return bell
        default: return nil
        }
    }

    @objc private func toolbarNewTab(_ sender: Any?) { newTab() }

    @objc private func toolbarPalette(_ sender: Any?) { CommandPalette.toggle(in: self) }

    /// "Split Right (⌘D)": a control's name and its keys as bound now.
    static func tip(_ label: String, _ action: Action) -> String {
        guard let keys = ConfigStore.shared.keybinds.trigger(for: action)?.displayString else { return label }
        return "\(label) (\(keys))"
    }

    @objc private func toolbarInbox(_ sender: Any?) {
        guard let button = (window?.toolbar?.items.first { $0.itemIdentifier == Self.inboxItem })?.view
            ?? findToolbarView(for: Self.inboxItem) else { return }
        if inboxPopover.isShown { inboxPopover.performClose(nil) } else {
            inboxPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }

    /// The view an icon-only toolbar item draws in (items made with an
    /// image have no `view` of their own).
    private func findToolbarView(for id: NSToolbarItem.Identifier) -> NSView? {
        guard let frame = window?.contentView?.superview else { return nil }
        func search(_ v: NSView) -> NSView? {
            if let button = v as? NSButton, button.action == #selector(toolbarInbox(_:)) { return button }
            for sub in v.subviews { if let hit = search(sub) { return hit } }
            return nil
        }
        return search(frame)
    }
    @objc private func toolbarFind(_ sender: Any?) { isSearching ? _ = endSearch() : startSearch() }
}

// MARK: - Pane headers

extension TerminalWindowController: PaneHeaderSource {
    func headerInfo(for leaf: NSView) -> PaneHeader.Info {
        let tab = everyTab.first { $0.container?.views.contains { $0 === leaf } == true }
        let focused = tab.map { leaf === $0.focusedLeaf } ?? false
        let split = (tab?.container?.views.count ?? 0) > 1
        if let pane = leaf as? TerminalView {
            let label = label(of: pane)
            let size = "\(pane.session.size.cols)×\(pane.session.size.rows)"
            let directory = Self.shortDirectory(pane.session.workingDirectory)
            // At a prompt the label is the folder: the header names it by its
            // last part, then says where it is (Tern's "cwd  lumen-test/…/cwd").
            var name = label.name, detail = label.detail.isEmpty ? directory : label.detail
            if label.detail.isEmpty, label.name == directory, let path = pane.session.workingDirectory {
                name = path == NSHomeDirectory() ? "~" : (path as NSString).lastPathComponent
            }
            return PaneHeader.Info(name: name, detail: detail, size: size, focused: focused,
                                   marked: split && focused, floats: true, parks: split)
        }
        if let doc = leaf as? DocumentView {
            let folder = doc.url.isFileURL ? Self.shortDirectory(doc.url.deletingLastPathComponent().path) : (doc.url.host ?? "")
            return PaneHeader.Info(name: doc.title, detail: folder, focused: focused, marked: split && focused, floats: false)
        }
        return PaneHeader.Info(name: "", detail: "")
    }

    func header(_ action: PaneHeader.Action, for leaf: NSView) {
        guard let tab = everyTab.first(where: { $0.container?.views.contains { $0 === leaf } == true }) else { return }
        switch action {
        case .focus:
            reveal(leaf, in: tab)
        case .zoom:
            reveal(leaf, in: tab)
            toggleZoom()
        case .pictureInPicture:
            if let pane = leaf as? TerminalView { floatPane(pane) }
        case .park:
            reveal(leaf, in: tab)
            parkFocusedPane()
        case .close:
            if let doc = leaf as? DocumentView { return closeDocumentPane(doc) }
            guard let pane = leaf as? TerminalView else { return }
            closeTerminalPane(pane)
        }
    }

}
