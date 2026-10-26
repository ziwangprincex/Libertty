import AppKit
import LiberttyCore

/// Workspaces: named sets of tabs in one window.
extension TerminalWindowController {
    // MARK: Workspaces (named sessions per window)

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
    func clearExited(in tab: TerminalTab) {
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
    func endWorkspace(_ id: UUID, undoable: Bool = true) {
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
}
