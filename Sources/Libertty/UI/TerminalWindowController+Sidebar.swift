import AppKit
import LiberttyCore

/// The sidebar and inspector, broadcast input, export, the tab overview, find in scrollback.
extension TerminalWindowController {
    // MARK: Sidebar and inspector

    /// The side columns slide in and out — unless the user asked for less
    /// motion: then they just appear and go.
    func toggleSidebar() { setCollapsed(sidebarItem, !sidebarItem.isCollapsed) }

    /// Fold a column (the sidebar, the inspector) away or bring it back. The
    /// window gives it its width, or takes it back, on its side, at once:
    /// the terminals keep their size and their place on the screen, and
    /// nothing in them moves or reflows (their programs never hear of it).
    /// Where the window can't grow — full screen, filling its screen (zoomed,
    /// tiled), the Quick Terminal at its edge — the column slides in over the
    /// terminals' width instead (unless the user asked for less motion).
    func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool) {
        guard item.isCollapsed != collapsed else { return }
        guard let window, !isQuick, !window.styleMask.contains(.fullScreen), !window.isZoomed,
              !fillsScreen(window) else {
            return slideColumns { (Motion.reduced ? item : item.animator()).isCollapsed = collapsed }
        }
        let area = areaController.view
        let before = area.window.map { $0.convertToScreen(area.convert(area.bounds, to: nil)) } ?? .zero
        // Its terminals stay as they are while the window catches up: no
        // grid change and no frame drawn at the size they pass through.
        let panes = allPanes.filter { $0.window != nil }
        panes.forEach { $0.freeze() }
        defer { panes.forEach { $0.thaw() } }
        // One picture on the screen: the column and the window's new edge together.
        window.disableScreenUpdatesUntilFlush()
        item.isCollapsed = collapsed
        splitController.view.layoutSubtreeIfNeeded()
        // The window moves its edges by what the terminals' area moved and
        // shrank (whatever AppKit did to fit the column), so the area is
        // where it was.
        let after = window.convertToScreen(area.convert(area.bounds, to: nil))
        guard after != before else { return }
        var frame = window.frame
        frame.origin.x += before.minX - after.minX
        frame.size.width += before.width - after.width
        window.setFrame(Self.onScreen(frame, from: window.frame, visible: window.screen?.visibleFrame), display: true)
        splitController.view.layoutSubtreeIfNeeded()
    }

    /// As wide as its screen allows: growing would push it off.
    private func fillsScreen(_ window: NSWindow) -> Bool {
        guard let visible = window.screen?.visibleFrame else { return false }
        return Self.fills(window.frame, visible: visible)
    }

    /// A column slides in or out over the terminals' width (`change`,
    /// animated): they keep their grid through the slide and take the new
    /// width once, when it's over.
    private func slideColumns(_ change: () -> Void) {
        let panes = allPanes.filter { $0.window != nil }
        panes.forEach { $0.holdGrid() }
        var released = false
        let release = {
            guard !released else { return }
            released = true
            panes.forEach { $0.releaseGrid() }
        }
        NSAnimationContext.runAnimationGroup({ _ in change() }, completionHandler: release)
        // Should the slide never say it ended.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: release)
    }

    func toggleInspector() { setCollapsed(inspectorItem, !inspectorItem.isCollapsed) }

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
    struct Identified {
        var pgid: pid_t
        var name: String
        var settled: Bool
    }

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

    func updateBroadcastBorders() {
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
    func dismissOverview() {
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
    var searchDocument: DocumentView? { selectedTab.document ?? selectedTab.focusedDocument }

    func find(_ text: String) {
        if let doc = searchDocument {
            doc.find(text, backwards: false) { [weak self] found in
                self?.area.findBar.show(result: SearchResult(total: found ? 1 : 0, active: true))
                self?.area.findBar.showDocument(found: found, empty: text.isEmpty)
            }
            return
        }
        searchedPane = focusedTerminal
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
        let searched = searchedPane ?? focusedTerminal
        searched.session.endSearch()
        searched.setNeedsRender(force: true)
        searchedPane = nil
        window?.makeFirstResponder(focusedTerminal)
        return true
    }

    var isSearching: Bool { !area.findBar.isHidden }
}
