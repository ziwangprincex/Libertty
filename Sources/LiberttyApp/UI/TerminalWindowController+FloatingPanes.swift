import AppKit

/// Floating panes (Rex's New Floating Pane, zellij's floating panes): a
/// terminal of its own over the tab's split, not in it. It's one of the
/// tab's parked panes (`TerminalTab.Parked.floating`), so it counts as a
/// program the tab runs everywhere that counts them (closing, the sidebar,
/// saving the layout), and the split's own focus, splits and zoom don't
/// change for it. Minimized, it's out of sight and running; Toggle Floating
/// Panes brings the tab's back (or makes one).
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

    /// Put it in the split, beside the pane that had the keyboard there.
    func dockFloating(_ pane: TerminalView) {
        guard let tab = owningTab(of: pane), let i = tab.parked.firstIndex(where: { $0.pane === pane }) else { return }
        tab.parked[i].floating = nil
        if let anchor = tab.focusedPane { tab.parked[i].anchor = anchor }
        pane.isFloating = false
        syncFloats(of: tab)
        unpark(pane)
    }

    /// Close it, as ⌘W closes a pane (asking first when a program runs).
    func closeFloating(_ pane: TerminalView) {
        confirmIfBusy([pane], noun: "pane") { [weak self] in
            pane.session.terminate()
            // Its end (sessionExited) takes it out of the tab.
            self?.updateSidebar()
        }
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
                guard let self, let pane else { return "" }
                return self.title(ofPane: pane)
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
    }

    /// Every tab's floating views as its parked panes say (the sidebar's update).
    func syncAllFloats() { everyTab.forEach(syncFloats(of:)) }
}
