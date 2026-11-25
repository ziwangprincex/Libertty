import AppKit

/// Floating panes (Rex's New Floating Pane, zellij's floating panes): a
/// terminal of its own over the tab's split, not in it. It's one of the
/// tab's parked panes (`TerminalTab.Parked.floating`), so it counts as a
/// program the tab runs everywhere that counts them (closing, the sidebar,
/// saving the layout), and the split's own focus, splits and zoom don't
/// change for it. Minimized, it's out of sight and running; Toggle Floating
/// Panes brings the tab's back (or makes one), and each waits meanwhile as
/// a capsule in a corner of the split (`floating-minimized-corner`): a
/// click brings that one back.
extension TerminalWindowController {
    /// New Floating Pane: a shell in the focused pane's folder, floating
    /// over the split, with the keyboard.
    func newFloatingPane(command: String? = nil) {
        if !selectedTab.isTerminal { select(terminalTab) }
        let tab = selectedTab
        guard let container = tab.container, let anchor = tab.focusedPane else { return }
        do {
            // The grid it will have at its frame, so its shell starts at that size.
            let frame = FloatingTerminalView.defaultFraction
            let cell = anchor.cellSizePoints
            let cols = max(20, Int(container.bounds.width * frame.width / max(1, cell.width)) - 2)
            let rows = max(5, Int((container.bounds.height * frame.height - FloatingTerminalView.barHeight) / max(1, cell.height)) - 1)
            let pane = try Self.makePane(config: config, cols: cols, rows: rows)
            pane.fontSize = anchor.fontSize
            adopt(pane)
            try startSession(of: pane, command: command, workingDirectory: anchor.session.workingDirectory, keepDirectory: false)
            pane.isParked = true
            pane.isFloating = true
            tab.parked.append(TerminalTab.Parked(pane: pane, anchor: anchor, side: .right, floating: frame))
            syncFloats(of: tab)
            window?.makeFirstResponder(pane)
            updateSidebar()
        } catch {
            showError(error)
        }
    }

    /// The tab in front's floating panes on screen.
    var shownFloatingPanes: [TerminalView] {
        selectedTab.parked.filter { $0.floating != nil && !$0.floatingMinimized }.map(\.pane)
    }

    /// Toggle Floating Panes: those showing are minimized; else those
    /// minimized come back; a tab with none gets a new one.
    func toggleFloatingPanes() {
        if !selectedTab.isTerminal { select(terminalTab) }
        let tab = selectedTab
        let floating = tab.parked.indices.filter { tab.parked[$0].floating != nil }
        guard !floating.isEmpty else { return newFloatingPane() }
        let anyShown = floating.contains { !tab.parked[$0].floatingMinimized }
        for i in floating { tab.parked[i].floatingMinimized = anyShown }
        syncFloats(of: tab)
        if anyShown {
            if let pane = tab.focusedPane { window?.makeFirstResponder(pane) }
        } else if let last = floating.last {
            window?.makeFirstResponder(tab.parked[last].pane)
        }
        updateSidebar()
    }

    /// Out of sight, its program running on; the keyboard back to the split.
    func minimizeFloating(_ pane: TerminalView) {
        guard let tab = owningTab(of: pane), let i = tab.parked.firstIndex(where: { $0.pane === pane }) else { return }
        tab.parked[i].floatingMinimized = true
        syncFloats(of: tab)
        if tab === selectedTab, let split = tab.focusedPane { window?.makeFirstResponder(split) }
        updateSidebar()
    }

    /// A minimized one back where it was, in front of the others, with the
    /// keyboard (its capsule clicked).
    func restoreFloating(_ pane: TerminalView) {
        guard let tab = owningTab(of: pane), let i = tab.parked.firstIndex(where: { $0.pane === pane }),
              tab.parked[i].floating != nil else { return }
        if tab !== selectedTab { select(tab) }
        tab.parked[i].floatingMinimized = false
        syncFloats(of: tab)
        if let container = tab.container, let float = container.floats.first(where: { $0.pane === pane }) { container.raise(float) }
        window?.makeFirstResponder(pane)
        updateSidebar()
    }

    /// Put it in the split, beside the pane that had the keyboard there.
    func dockFloating(_ pane: TerminalView) {
        guard let tab = owningTab(of: pane), let i = tab.parked.firstIndex(where: { $0.pane === pane }) else { return }
        let floating = tab.parked[i]
        tab.parked[i].floating = nil
        if let anchor = tab.focusedPane { tab.parked[i].anchor = anchor }
        pane.isFloating = false
        syncFloats(of: tab)
        // It couldn't go in the split: it floats on where it was.
        if !unpark(pane), let j = tab.parked.firstIndex(where: { $0.pane === pane }) {
            tab.parked[j] = floating
            syncFloats(of: tab)
        }
    }

    /// Close it, as ⌘W closes a pane: asking first when a program runs,
    /// and kept for Edit ▸ Undo as a split's pane is.
    func closeFloating(_ pane: TerminalView) {
        confirmIfBusy([pane], noun: "pane") { [weak self] in self?.removeFloating(pane) }
    }

    /// Out of its tab, the keyboard back to the split's pane; its program
    /// runs on for `undo-timeout` (Edit ▸ Undo Close Pane brings it back
    /// where it was), then ends.
    func removeFloating(_ pane: TerminalView, undoable: Bool = true) {
        guard let tab = owningTab(of: pane), let i = tab.parked.firstIndex(where: { $0.pane === pane }) else { return }
        let hadKeyboard = window?.firstResponder === pane
        let entry = tab.parked.remove(at: i)
        syncFloats(of: tab)
        if hadKeyboard, tab === selectedTab, let split = tab.focusedPane { window?.makeFirstResponder(split) }
        if undoable, !pane.session.hasExited, CloseUndo.shared.enabled {
            CloseUndo.shared.closed("Close Pane", restore: { [weak self, weak tab] in
                guard let self, let tab, !pane.session.hasExited, self.takeBack(tab) else { return nil }
                if tab !== self.selectedTab { self.select(tab) }
                tab.parked.append(entry)
                self.syncFloats(of: tab)
                // A minimized one (closed from its capsule) back to its capsule; a shown one with the keyboard.
                if !entry.floatingMinimized { self.window?.makeFirstResponder(pane) }
                self.updateSidebar()
                return { [weak self] in self?.removeFloating(pane) }
            }, expire: { pane.session.terminate() })
        } else {
            pane.session.terminate()
        }
        Notifier.shared.clear(pane: pane.paneID)
        updateSidebar()
    }

    /// Make a tab's floating views match its parked panes: one for each
    /// floating pane not minimized, in the split of the tab in front only.
    func syncFloats(of tab: TerminalTab) {
        guard let container = tab.container else { return }
        let wanted = tab.parked.filter { $0.floating != nil && !$0.floatingMinimized && !$0.pane.session.hasExited }
        for float in container.floats where !wanted.contains(where: { $0.pane === float.pane }) {
            container.removeFloat(float)
        }
        for entry in wanted where !container.floats.contains(where: { $0.pane === entry.pane }) {
            let pane = entry.pane
            pane.isFloating = true
            let float = FloatingTerminalView(pane: pane, fraction: entry.floating ?? FloatingTerminalView.defaultFraction)
            float.title = { [weak self, weak pane] in
                guard let self, let pane else { return ("", "") }
                return self.compactLabel(of: pane)
            }
            float.onMinimize = { [weak self, weak pane] in pane.map { self?.minimizeFloating($0) } }
            float.onDock = { [weak self, weak pane] in pane.map { self?.dockFloating($0) } }
            float.onClose = { [weak self, weak pane] in pane.map { self?.closeFloating($0) } }
            float.onActivate = { [weak container, weak float, weak self, weak pane] in
                guard let float else { return }
                container?.raise(float)
                if let pane { self?.window?.makeFirstResponder(pane) }
            }
            float.onChange = { [weak tab, weak pane] fraction in
                // Kept, so it comes back (and is saved) where it was put.
                guard let tab, let pane, let i = tab.parked.firstIndex(where: { $0.pane === pane }) else { return }
                tab.parked[i].floating = fraction
            }
            container.addFloat(float)
        }
        container.floats.forEach { $0.refreshTitle() }
        // The minimized ones, each a capsule in the corner the settings say.
        let minimized = tab.parked.filter { $0.floating != nil && $0.floatingMinimized && !$0.pane.session.hasExited }.map(\.pane)
        container.showMinimized(minimized.map(capsule(for:)), corner: config.floatingMinimizedCorner, restore: { [weak self, weak tab] id in
            guard let pane = tab?.parked.first(where: { ObjectIdentifier($0.pane) == id })?.pane else { return }
            self?.restoreFloating(pane)
        }, close: { [weak self, weak tab] id in
            guard let pane = tab?.parked.first(where: { ObjectIdentifier($0.pane) == id })?.pane else { return }
            self?.closeFloating(pane)
        }, moved: { corner in
            // Every tab's, every window's: it's a setting (Settings ▸ Interface).
            MainActor.assumeIsolated { SettingsModel.shared.write("floating-minimized-corner", corner.rawValue) }
        })
    }

    /// What a minimized floating pane's capsule shows: its program's glyph
    /// (a shell's at a prompt), a short name, and what it reports doing.
    private func capsule(for pane: TerminalView) -> FloatingTaskbar.Entry {
        let session = pane.session
        let tile = programs[ObjectIdentifier(session)]
        let name = !session.label.isEmpty ? session.label : tile.map { $0.host ?? $0.name } ?? compactLabel(of: pane).name
        let state = session.programStatus.headline(among: config.programStatusIndicator)?.state
        return FloatingTaskbar.Entry(pane: ObjectIdentifier(pane), name: name, symbol: tile == nil ? "apple.terminal" : tile?.symbol,
                                     badge: StatusBadge.look(status: state, progress: session.progress, programs: true),
                                     state: state.map { L10n.t(Self.stateWord($0)) } ?? "")
    }

    /// A pane named in a small space (a floating pane's bar, the composer's
    /// header): as its header names it, the folder by its own name alone.
    func compactLabel(of pane: TerminalView) -> (name: String, detail: String) {
        let (name, detail) = label(of: pane)
        // At a prompt the folder is the name.
        if detail.isEmpty, name.contains("/") { return ((name as NSString).lastPathComponent, "") }
        guard detail.contains("/") else { return (name, detail) }
        let folder = (detail as NSString).lastPathComponent
        return (name, folder.isEmpty ? detail : folder)
    }

    /// Every tab's floating views as its parked panes say (the sidebar's update).
    func syncAllFloats() { everyTab.forEach(syncFloats(of:)) }
}
