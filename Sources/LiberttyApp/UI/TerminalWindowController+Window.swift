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

    /// The toolbar for the `tab-bar` mode, unless it's already there. The
    /// delegate is set before it joins the window: that's when it asks for
    /// its items.
    func installToolbar() {
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
