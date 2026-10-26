import AppKit
import LiberttyCore

/// Splits: new panes, closing them, focus and zoom; parking panes out of the split.
extension TerminalWindowController {
    // MARK: Panes

    @objc func splitRight(_ sender: Any?) { split(.right) }
    @objc func splitDown(_ sender: Any?) { split(.down) }

    func split(_ direction: SplitContainerView.Direction) {
        // A document in front: split the terminal tab instead.
        if !selectedTab.isTerminal { select(terminalTab) }
        guard let focused = selectedTab.focusedPane else { return }
        split(focused, toward: direction)
    }

    /// Split Best Fit (Ghostty's `new_split:auto`): beside a wide pane,
    /// below a tall one — by the space the text has, so the halves read alike.
    func splitBestFit() {
        if !selectedTab.isTerminal { select(terminalTab) }
        guard let focused = selectedTab.focusedPane else { return }
        let size = selectedTab.container?.slot(of: focused).size ?? focused.bounds.size
        split(focused, toward: size.width >= size.height ? .right : .down)
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
            container.autobalance = config.splitAutobalance
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
    func removePane(_ pane: TerminalView, undoable: Bool = true, parking: Bool = false, asCard: Bool = false,
                            unsavedAsked: Bool = false) {
        // (`contains` lets a removal under way finish: the panes are counted after it.)
        guard let tab = tab(containing: pane), let container = tab.container, container.contains(pane) else { return }
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
            // Their slots: a zoomed pane's frame is the whole container.
            let a = container.slot(of: pane), b = container.slot(of: next)
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
}
