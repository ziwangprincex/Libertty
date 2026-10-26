import AppKit
import LiberttyCore

/// Moving panes and tabs to other tabs and windows, and arranging a split (drags, +swap-pane, +resize-pane).
extension TerminalWindowController {
    // MARK: Moving panes and tabs (after Rex)

    /// The focused pane can leave for a tab or a window of its own: a
    /// terminal in a split, with another terminal staying there.
    var canMoveFocusedPaneOut: Bool {
        !isQuick && selectedTab.isTerminal && selectedTab.focusedDocument == nil && selectedTab.panes.count > 1
            && !isParked(selectedTab.focusedPane)
    }

    func isParked(_ pane: TerminalView?) -> Bool {
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
    func syncCard(of tab: TerminalTab) {
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
    func removeDocumentPane(_ doc: DocumentView) {
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
    var focusedDocumentPane: DocumentView? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        return selectedTab.documentPanes.first { responder.isDescendant(of: $0) }
    }

    /// Where focus is in the split: a document pane or the focused terminal.
    var focusedLeaf: NSView? { focusedDocumentPane ?? selectedTab.focusedLeaf }

    func focusLeaf(_ view: NSView) {
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

    func adopt(_ doc: DocumentView) {
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
}
