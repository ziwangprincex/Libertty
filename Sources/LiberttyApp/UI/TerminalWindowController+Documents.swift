import AppKit
import LiberttyCore

/// Blocks and documents in tabs and beside terminals, and their unsaved changes.
extension TerminalWindowController {
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

    /// Every browser of the window, with where it is: "tab 2", "tab 1 beside
    /// SESSION" (its tab's terminal), "workspace 2 tab 1" (`+browser list`).
    var browsers: [(page: DocumentView, place: String, beside: String?)] {
        let groups = workspaceTabs
        return groups.enumerated().flatMap { w, group in
            group.enumerated().flatMap { t, tab -> [(page: DocumentView, place: String, beside: String?)] in
                let workspace = groups.count > 1 ? "workspace \(w + 1) " : ""
                if let doc = tab.document, doc.kind == .web { return [(doc, "\(workspace)tab \(t + 1)", nil)] }
                let beside = (tab.focusedPane ?? tab.panes.first)?.session.persistentID
                return tab.documentPanes.filter { $0.kind == .web }.map { doc in
                    (doc, "\(workspace)tab \(t + 1)" + (beside.map { " beside \($0)" } ?? ""), beside)
                }
            }
        }
    }

    /// The browser beside the pane showing session `id`: one in its tab.
    func browser(besideSession id: String) -> DocumentView? {
        guard let pane = pane(showing: id), let tab = owningTab(of: pane) else { return nil }
        return tab.documentPanes.last { $0.kind == .web }
    }

    /// `+browser open`: a browser on `url` in a tab of its own, or with
    /// `split` beside a terminal (`pane`, in its own tab, whichever that is;
    /// else the focused one) — or the one already showing it there. With
    /// `focus` it comes forward with the keyboard in it; without, nothing in
    /// front changes (an agent's page beside its terminal while you type).
    func openBrowserPage(_ url: URL, beside pane: TerminalView?, split: Bool, focus: Bool) -> DocumentView? {
        let fresh = url.absoluteString == "about:blank"
        if split {
            let anchor = pane ?? (selectedTab.isTerminal ? selectedTab : terminalTab).focusedPane
            guard let anchor, let tab = tab(containing: anchor), let container = tab.container else { return nil }
            if !fresh, let open = tab.documentPanes.first(where: { $0.kind == .web && $0.url.standardizedFileURL == url.standardizedFileURL }) {
                open.reload()
                if focus { reveal(open, in: tab) }
                return open
            }
            let doc = makeDocument(url)
            container.split(anchor, with: doc, toward: .right)
            if focus {
                reveal(doc, in: tab)
                if fresh { DispatchQueue.main.async { doc.focusAddress() } }
            }
            updateSidebar()
            return doc
        }
        if !fresh, let open = tabs.first(where: { $0.document?.kind == .web && $0.document?.url.standardizedFileURL == url.standardizedFileURL }) {
            if focus { select(open) }
            return open.document
        }
        let doc = makeDocument(url)
        let tab = TerminalTab(document: doc)
        tabs.insert(tab, at: (tabs.firstIndex { $0 === selectedTab } ?? tabs.count - 1) + 1)
        if focus {
            select(tab)
            if fresh { DispatchQueue.main.async { doc.focusAddress() } }
        } else {
            // Laid out as it will be shown, while it loads unseen.
            doc.lendSize(pageSize)
            updateSidebar()
        }
        return doc
    }

    /// What a page in a tab of this window has to draw in.
    var pageSize: NSSize {
        let size = area.bounds.size
        return size.width >= 1 && size.height >= 1 ? size : NSSize(width: 1280, height: 800)
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
    func documents(in tabs: [TerminalTab]) -> [DocumentView] {
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

    /// Every document of the window with unsaved changes (quitting asks about them).
    var unsavedDocuments: [DocumentView] { documents(in: everyTab).filter(\.hasUnsavedChanges) }

    /// Documents that closed: whoever waits on them (`+open --wait`) goes on.
    func documentsClosed(_ docs: [DocumentView]) {
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
    func documentsClosing(with tab: TerminalTab) -> [DocumentView] {
        tabs.contains(where: { $0 !== tab && $0.isTerminal }) ? documents(in: [tab]) : documents(in: tabs)
    }

    /// ⌘W, the pane's × or its header's: a terminal pane closes (asking about
    /// a running program, and about the documents beside it when it's the
    /// last terminal and its tab goes with it).
    func closeTerminalPane(_ pane: TerminalView) {
        guard let tab = tab(containing: pane) else { return }
        let tabCloses = tab.panes.count == 1 && tab.parked.isEmpty
        confirmUnsaved(tabCloses ? documentsClosing(with: tab) : []) { [weak self] in
            self?.confirmIfBusy([pane], noun: "pane") {
                guard tabCloses else { self?.removePane(pane, unsavedAsked: true); return }
                // Its tab goes with it: a worktree's asks whether that goes too.
                self?.confirmWorktree(tab) { removing in
                    if removing { self?.removeTab(tab, undoable: false, unsavedAsked: true) } else { self?.removePane(pane, unsavedAsked: true) }
                }
            }
        }
    }

    /// Clicking into a document pane focuses it (a terminal reports its own
    /// focus through paneDidFocus).
    func firstResponderChanged() {
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

    func move(to pane: NSView) {
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

    /// Two fingers spread over `pane` (it's focused, then fills its tab) or
    /// pinched (its tab's panes come back): `trackpad-gestures`.
    func pinch(_ pane: TerminalView, total: CGFloat) -> Bool {
        guard let tab = tab(containing: pane), tab === selectedTab else { return false }
        let zoomed = tab.container?.zoomed != nil
        switch TrackpadGestures.pinch(total, zoomed: zoomed, panes: tab.container?.views.count ?? 0) {
        case .zoom?:
            focusLeaf(pane)
            toggleZoom()
        case .restore?:
            toggleZoom()
        case nil:
            return false
        }
        return true
    }

    /// A sideways swipe over a terminal (`sidebar-swipe`): the sidebar
    /// comes or goes.
    func swipeSidebar(dx: CGFloat, dy: CGFloat) -> Bool {
        guard config.tabBar.inSidebar || config.sidebarFiles, TrackpadGestures.isSidebarSwipe(dx: dx, dy: dy) else { return false }
        toggleSidebar()
        return true
    }

    /// Sidebar ▸ cd Here, Go to Directory's ⌥↵: type the command at the
    /// focused pane's prompt (a space first keeps it out of the history; the
    /// line there cleared first, as ⌃U does). With a program in front of the
    /// shell, typing would go to the program: a new tab opens there instead.
    func changeDirectory(to path: String) {
        if !selectedTab.isTerminal { select(terminalTab) }
        guard !focusedTerminal.session.hasForegroundProgram else {
            newTab(workingDirectory: path)
            return
        }
        focusedTerminal.sendInput("\u{15} cd " + ShellQuote.quote(path) + "\n")
        window?.makeFirstResponder(focusedTerminal)
    }

    /// Sidebar ▸ Insert Path: into the terminal, bringing it forward.
    func insertInTerminal(_ text: String) {
        if !selectedTab.isTerminal { select(terminalTab) }
        focusedTerminal.sendInput(text)
        window?.makeFirstResponder(focusedTerminal)
    }

    func paneDidFocus(_ pane: TerminalView) {
        Notifier.shared.clear(pane: pane.paneID)
        attention.remove(ObjectIdentifier(pane))
        guard let tab = tab(containing: pane) else { return }
        tab.focusedPane = pane
        tab.focusedDocument = nil
        tab.noteFocus(pane)
        // The find bar searches the focused pane: another one focused (a
        // click, a pane closed, parked or unparked), the search — its
        // highlights, its count — moves along with it.
        if tab === selectedTab, isSearching, searchDocument == nil, let old = searchedPane, old !== pane {
            old.session.endSearch()
            old.setNeedsRender(force: true)
            find(area.findBar.field.stringValue)
        }
        if tab !== selectedTab { select(tab) }
        updateDimming()
        updateTitle()
        updateSidebar()
    }

    /// Split panes' hover tags follow what runs in them — beside other
    /// terminals or beside documents (one pane alone shows none) — and so
    /// do pane headers, where they show (`pane-headers`).
    func updateNameTags(of tab: TerminalTab) {
        if let container = tab.container {
            container.headerSource = self
            container.headers = config.paneHeaders
            container.autobalance = config.splitAutobalance
            container.cardColor = config.resolvedTheme.background.nsColor.withAlphaComponent(config.paneOpacity)
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

    /// `active-border`'s look now, or nil when it's off: fainter while the
    /// window isn't in front.
    var activeBorderLook: ActiveBorderView.Look? {
        guard config.activeBorder else { return nil }
        let color: NSColor = switch config.activeBorderColor {
        case "accent": Accent.color
        case "text": config.resolvedTheme.foreground.nsColor
        default: RGB(string: config.activeBorderColor)?.nsColor ?? Accent.color
        }
        let front = window?.isKeyWindow ?? false
        return .init(color: color, opacity: config.activeBorderOpacity * (front ? 1 : 0.5), animation: config.activeBorderAnimation)
    }

    func updateDimming() {
        for tab in everyTab {
            let split = (tab.container?.views.count ?? 0) > 1
            let focused = tab.focusedLeaf
            for pane in tab.panes {
                pane.setDimmed(split && pane !== focused)
                // A header has its own close button and says the pane's name.
                pane.showsCloseButton = split && tab.container?.showsHeader(for: pane) != true
                // Under a header, the header's top carries the mark.
                pane.showsFocusLine = split && pane === focused && tab.container?.showsHeader(for: pane) != true && !config.activeBorder
            }
            updateNameTags(of: tab)
            tab.container?.showActiveBorder(on: focused, look: activeBorderLook)
            for doc in tab.documentPanes {
                doc.setDimmed(split && doc !== focused, opacity: config.unfocusedSplitOpacity,
                              color: config.resolvedTheme.background.nsColor)
                doc.showsCloseButton = split && tab.container?.showsHeader(for: doc) != true
                doc.showsFocusLine = split && doc === focused && tab.container?.showsHeader(for: doc) != true && !config.activeBorder
            }
        }
    }
}
