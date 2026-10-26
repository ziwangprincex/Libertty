import AppKit
import LiberttyCore

/// Settings taking effect, and the window's tabs: new, attached, duplicated, selected, closed.
extension TerminalWindowController {
    // MARK: Settings

    func configDidChange(_ config: Config) {
        let old = self.config
        self.config = config
        // The app's looks (every window sets them alike): the panes' style,
        // the accent, the tab glyphs' colors.
        let accent = config.accent(with: config.resolvedTheme)
        let looksChanged = Layout.compact != (config.paneStyle == .compact) || Accent.custom != accent
            || TileStack.colored != config.tabIconColor || config.paneGlass != old.paneGlass
        Layout.compact = config.paneStyle == .compact
        Accent.custom = accent
        TileStack.colored = config.tabIconColor
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
        if looksChanged { refreshLooks() }
        // The sidebar and inspector follow their settings when those change.
        if config.windowSidebar != old.windowSidebar {
            setCollapsed(sidebarItem, !config.windowSidebar)
        }
        if config.windowInspector != old.windowInspector {
            setCollapsed(inspectorItem, !config.windowInspector)
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
            setCollapsed(sidebarItem, true)
        } else if config.tabBar == .sidebar, foldedForTabBar {
            foldedForTabBar = false
            setCollapsed(sidebarItem, false)
        }
    }

    /// The bar carries only controls while the tabs are named elsewhere
    /// (the sidebar, the top; Tern's); with the sidebar folded away and
    /// no tabs on top, the title says which tab is in front.
    func updateTitleVisibility() {
        window?.titleVisibility = config.tabBar == .top || isSidebarShown ? .hidden : .visible
    }

    func applyWindowStyle() {
        guard let window else { return }
        let theme = config.resolvedTheme
        // Glass panes: the window lets the desktop through, the frame stays as it is.
        let glass = config.paneGlass
        let opaque = config.backgroundOpacity >= 1 && !glass
        window.isOpaque = opaque
        // One surface around the panes (toolbar, side columns, gaps), lit
        // below them in a dark theme (Tern's look).
        let frame = config.backgroundOpacity >= 1 ? theme.chrome : theme.background
        window.backgroundColor = opaque ? frame.nsColor : .clear
        // Controls follow the terminal's theme.
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        area.apply(background: frame, opacity: config.backgroundOpacity, blurred: config.backgroundBlur, glass: glass)
        (splitController.splitView as? FrameSplitView)?.frameColor = frame.nsColor.withAlphaComponent(config.backgroundOpacity)
        sidebar.apply(frame: frame, opacity: config.backgroundOpacity)
        inspector.apply(frame: frame, opacity: config.backgroundOpacity)
        everyTab.forEach { $0.document?.apply(theme: theme, renderMarkdown: config.markdownRendered) }
        everyTab.flatMap(\.documentPanes).forEach { $0.apply(theme: theme, renderMarkdown: config.markdownRendered) }
    }

    /// After `pane-style`, `accent-color`, `tab-icon-color` or `pane-glass`
    /// changed: everything laid out and colored again — views take their
    /// colors when their appearance changes, so that's what they're told.
    private func refreshLooks() {
        guard let content = window?.contentView?.superview ?? window?.contentView else { return }
        func visit(_ view: NSView) {
            // Libertty's own views (AppKit's follow the system's accent).
            if Bundle(for: type(of: view)) == Bundle.main { view.viewDidChangeEffectiveAppearance() }
            view.needsLayout = true
            view.needsDisplay = true
            view.subviews.forEach(visit)
        }
        visit(content)
        everyTab.forEach { $0.container?.layoutPanes() }
        allPanes.forEach { $0.setNeedsRender(force: true) }
        updateDimming()
        updateSidebar(force: true)
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
            // A folder asked for is kept; the focused pane's is `working-directory`'s to overrule.
            try startSession(of: pane, command: command, workingDirectory: workingDirectory ?? focusedWorkingDirectory,
                             keepDirectory: workingDirectory != nil)
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

    func removeTab(_ tab: TerminalTab, undoable: Bool = true, unsavedAsked: Bool = false) {
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
}
