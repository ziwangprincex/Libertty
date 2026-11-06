import AppKit
import LiberttyCore

/// The window itself: its frame, closing it, NSWindowDelegate, the toolbar.
extension TerminalWindowController {
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
    var hasRunningPrograms: Bool { allPanes.contains { $0.session.hasForegroundProgram } }
    /// Running programs that quitting would end even with persistence: those
    /// in panes liberttyd doesn't hold (it was slow to start, or refused one).
    var hasRunningLocalPrograms: Bool {
        allPanes.contains { $0.session.persistentID == nil && $0.session.host == nil && $0.session.hasForegroundProgram }
    }

    // MARK: Closing

    func confirmIfBusy(_ panes: [TerminalView], noun: String, verb: String = "Close",
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
        // The pane with the keyboard tells its program (focus reporting).
        (window?.firstResponder as? TerminalView)?.session.reportFocus(true)
        selectedTab.panes.forEach { $0.setNeedsRender(force: true) }
        updateSidebar()
    }

    func windowWillEnterFullScreen(_ notification: Notification) { savedNonFullScreenFrame = window?.frame }
    func windowDidEnterFullScreen(_ notification: Notification) { allPanes.forEach { $0.updateDisplaySync() } }
    func windowDidExitFullScreen(_ notification: Notification) { allPanes.forEach { $0.updateDisplaySync() } }

    func windowDidResignKey(_ notification: Notification) {
        (window?.firstResponder as? TerminalView)?.session.reportFocus(false)
        selectedTab.panes.forEach { $0.setNeedsRender(force: true) }
        autohideIfAway()
    }

    /// The quick terminal goes away when you click elsewhere — not for its
    /// own sheets, nor for a window of its own on top (the palette opened over
    /// it: that one asks again when it closes).
    func autohideIfAway() {
        guard isQuick, config.quickTerminalAutohide, window?.attachedSheet == nil, window?.isVisible == true else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isKeyWindow == false, NSApp.modalWindow == nil,
                  NSApp.keyWindow?.parent !== self.window else { return }
            QuickTerminal.shared.hide(restoreFocus: false)
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
        // Its worktrees: whether they go too, asked once the rest is settled
        // (Cancel keeps the window as it was). Quitting and Close All don't
        // come here: their sessions' worktrees stay.
        if worktreesOnClose == nil, confirmWindowWorktrees(cancelled: { [weak self] in self?.skipCloseConfirmation = false }, then: { [weak self] in
            // Again from the top, with what was asked already answered.
            self?.unsavedConfirmed = true
            _ = self?.windowShouldClose(sender)
        }) {
            return false
        }
        // Undoable: hide it for `undo-timeout`, then really close it — not
        // when its worktrees are to go with it.
        guard CloseUndo.shared.enabled, !isQuick, (worktreesOnClose ?? []).isEmpty,
              allPanes.contains(where: { !$0.session.hasExited }) else {
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
            self.worktreesOnClose = nil
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

    /// Every window shares the close-undo stack (Edit ▸ Undo Close Window).
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        MainActor.assumeIsolated { CloseUndo.shared.manager }
    }

    func windowWillClose(_ notification: Notification) {
        documentsClosed(documents(in: everyTab))
        // The worktrees it was asked to take with it, once its programs end.
        removeWorktreesOnClose()
        if let observer = inboxObserver { NotificationCenter.default.removeObserver(observer) }
        inboxObserver = nil
        allPanes.forEach { $0.session.terminate() }
        onClose?(self)
    }

    // MARK: Chrome (Rex's: no toolbar items, the window's own buttons)

    static let chromeToolbar = "libertty.window.rex"

    /// An empty toolbar: it only puts the traffic lights where Rex has
    /// them, in a 46-point band; the buttons are the window's (`chrome`).
    func installToolbar() {
        guard let window, !isQuick, window.toolbar?.identifier != Self.chromeToolbar else { return }
        let toolbar = NSToolbar(identifier: Self.chromeToolbar)
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // The activity button lights up with unread news.
        if let old = inboxObserver { NotificationCenter.default.removeObserver(old) }
        inboxObserver = NotificationCenter.default.addObserver(forName: Notifier.inboxChanged, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.chrome.show(unread: Notifier.shared.unread > 0) }
        }
    }

    /// Where things sit for the tab style, the pane style and which columns
    /// show (Rex's layouts): the panes' insets, the band over them, and the
    /// window's buttons — in the sidebar's top row while it's on the left.
    func updateStage() {
        guard !isQuick else { return }
        let sidebarShown = isSidebarShown
        let onRight = config.tabBar == .right
        let leftColumn = sidebarShown && !onRight
        let rightColumn = (sidebarShown && onRight) || !inspectorItem.isCollapsed
        let outer = Layout.stageInset
        // A band only for the tabs along the top; otherwise the traffic
        // lights and buttons share the panes' top row (their headers).
        let band = config.tabBar == .top
        let mid = WindowChrome.trafficLightMid(in: window)
        area.bandHeight = band ? WindowChrome.bandHeight : 0
        area.bandClearance = leftColumn ? 9 : WindowChrome.trafficLightRoom
        area.bandMid = mid
        area.insets = NSEdgeInsets(top: band ? 0 : outer, left: leftColumn ? 0 : outer, bottom: outer, right: rightColumn ? 0 : outer)
        chrome.show(hostChip: host == nil ? nil : hostChip.view)
        chrome.show(unread: Notifier.shared.unread > 0)
        chrome.sidebarToggle.toolTip = Self.tip(sidebarShown ? "Hide Sidebar" : "Show Sidebar", .toggleSidebar)
        let trailingInSidebar = sidebarShown && config.tabBar.inSidebar
        let clearance = leftColumn ? WindowChrome.trafficLightRoom + 10 : 9
        sidebar.setChrome(leading: leftColumn ? chrome.leading : nil, trailing: trailingInSidebar ? chrome.trailing : nil, mid: mid,
                          clearance: clearance)
        // Never narrower than its top row's buttons: at 180 points, Show
        // Activity sat on the sidebar's toggle. (A host's chip makes it wider.)
        let minimum = Self.sidebarMinimum(clearance: clearance, leading: leftColumn ? chrome.leading.fittingSize.width : nil,
                                          trailing: trailingInSidebar ? chrome.trailing.fittingSize.width : nil)
        if sidebarItem.minimumThickness != minimum { sidebarItem.minimumThickness = minimum }
        area.setBand(left: leftColumn ? nil : chrome.leading, middle: config.tabBar == .top ? tabStrip : nil,
                     right: trailingInSidebar ? nil : chrome.trailing)
        (splitController.splitView as? FrameSplitView)?.line = Layout.compact ? Surfaces.current.stroke.nsColor : nil
        everyTab.forEach { $0.container?.glassBehind = config.glass }
    }

    /// The sidebar's least width: 180 points, or what its top row needs for
    /// the buttons it holds, from `clearance` (after the traffic lights):
    /// the leading group, a gap, the trailing group, the edge's margin.
    static func sidebarMinimum(clearance: CGFloat, leading: CGFloat?, trailing: CGFloat?) -> CGFloat {
        guard let trailing else { return 180 }
        let start = clearance + (leading.map { $0 + 8 } ?? 0)
        return max(180, (start + trailing + 9).rounded(.up))
    }

    /// The room around the grid as `updateStage` lays it out: the band or
    /// the top inset, the bottom and side insets, a pane's header.
    func stageExtra() -> NSSize {
        Self.stageExtra(config, sidebar: isSidebarShown, inspector: !inspectorItem.isCollapsed)
    }

    static func stageExtra(_ config: Config, sidebar: Bool, inspector: Bool) -> NSSize {
        let outer: CGFloat = config.paneStyle == .compact ? 0 : 8
        let onRight = config.tabBar == .right
        let leftColumn = sidebar && !onRight
        let rightColumn = (sidebar && onRight) || inspector
        let band = config.tabBar == .top
        let header: CGFloat = config.paneHeaders == .always || (!band && !leftColumn) ? PaneHeader.height : 0
        return NSSize(width: (leftColumn ? 0 : outer) + (rightColumn ? 0 : outer),
                      height: (band ? WindowChrome.bandHeight : outer) + outer + header)
    }

    /// The sidebar goes to the side the tab style says.
    func arrangeColumns() {
        let items = splitController.splitViewItems
        guard let content = items.first(where: { $0.viewController === areaController }) else { return }
        let wanted = config.tabBar == .right ? [content, inspectorItem, sidebarItem] : [sidebarItem, content, inspectorItem]
        guard items.map(ObjectIdentifier.init) != wanted.map(ObjectIdentifier.init) else { return }
        splitController.splitViewItems = wanted
    }

    @objc func chromeToggleSidebar(_ sender: Any?) { toggleSidebar() }
    @objc func chromeNewTab(_ sender: Any?) { newTab() }
    @objc func chromePalette(_ sender: Any?) { CommandPalette.toggle(in: self) }

    @objc func chromeActivity(_ sender: Any?) {
        let button = chrome.activity
        if inboxPopover.isShown { inboxPopover.performClose(nil) } else {
            inboxPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc func toolbarFind(_ sender: Any?) { isSearching ? _ = endSearch() : startSearch() }
}
