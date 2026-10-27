import AppKit
import LiberttyCore

/// What the sessions report: output, exits, titles, program status, the tabs' news.
extension TerminalWindowController {
    // MARK: TerminalSessionDelegate

    func sessionLinkChanged(_ session: TerminalSession) {
        pane(for: session)?.updateLinkBanner()
        updateTitle()
    }

    func sessionNeedsRender(_ session: TerminalSession) {
        guard let pane = pane(for: session) else { return }
        pane.setNeedsRender()
        pane.announceOutputIfNeeded()
        // A program printing, not the shell echoing what you type at its
        // prompt (GoRex). The tile poll knows who's in front; a host's pane
        // has its prompt marks to say.
        if programs[ObjectIdentifier(session)] != nil || (session.host != nil && session.hasForegroundProgram) {
            pane.noteActivity()
        }
        if isSearching, pane === focusedTerminal {
            // New output may add matches; the count follows on the next frame.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.area.findBar.show(result: self.focusedTerminal.session.searchResult)
            }
        }
    }

    func sessionSearchChanged(_ session: TerminalSession) {
        guard let pane = pane(for: session) else { return }
        // Still going through the output: the next frame goes on with it.
        if session.searchIncomplete { pane.setNeedsRender() }
        if isSearching, pane === focusedTerminal { area.findBar.show(result: session.searchResult) }
    }

    func sessionTitleChanged(_ session: TerminalSession, title: String) {
        updateTitle()
    }

    func sessionLabelChanged(_ session: TerminalSession) {
        updateTitle()
    }

    /// `bell-features`, as in Ghostty.
    func sessionBell(_ session: TerminalSession) {
        let features = config.bellFeatures
        let pane = pane(for: session)
        let looking = pane.map(isLookedAt) ?? false
        if features.contains("system") || features.contains("audio") { NSSound.beep() }
        if features.contains("attention"), !(NSApp.isActive && window?.isKeyWindow == true) {
            NSApp.requestUserAttention(.informationalRequest)
        }
        if features.contains("border"), let pane { pane.flashHalo(.systemYellow) }
        if features.contains("title"), !looking, let pane, let tab = owningTab(of: pane) {
            tab.rang = true
            updateTitle()
        }
        if !looking, let pane { markAttention(pane) }
    }

    // MARK: Tab news (GoRex): printing now, or something happened unseen

    private func markAttention(_ pane: TerminalView) {
        guard attention.insert(ObjectIdentifier(pane)).inserted else { return }
        updateSidebar()
    }

    /// What a tab did that you haven't seen. The tab in front shows none:
    /// you're looking at it.
    func news(of tab: TerminalTab) -> TabNews {
        guard tab !== selectedTab || window?.isVisible != true else { return .none }
        // A parked build finishing counts: it's the reason to look.
        let panes = tab.everyPane
        if panes.contains(where: { attention.contains(ObjectIdentifier($0)) }) { return .attention }
        // The output clock, not render requests: a hidden tab never draws,
        // so after its first frame it stops asking to.
        let now = CACurrentMediaTime()
        let printing = panes.contains { pane in
            programs[ObjectIdentifier(pane.session)] != nil && now - pane.session.outputMark.time < Self.printingFor
        }
        return printing ? .printing : .none
    }

    func sessionProgramStatusChanged(_ session: TerminalSession) {
        updateTitle()
        notifyIfNeeded(session)
        onAttentionChange?()
        // Back at a prompt: the sidebar tree follows the focused pane's
        // folder, and the command may have changed files anywhere in it.
        if session === focusedTerminal.session {
            sidebar.refreshFilesAtPrompt()
            inspector.refreshGitAtPrompt()
        }
    }

    func sessionProgressChanged(_ session: TerminalSession) {
        updateSidebar()
        onAttentionChange?()
    }

    func sessionDesktopNotification(_ session: TerminalSession, title: String, body: String) {
        guard config.desktopNotifications, let pane = pane(for: session), !isLookedAt(pane) else { return }
        Notifier.shared.post(title: title.isEmpty ? self.title(ofPane: pane) : title, body: body, pane: pane.paneID)
    }

    func sessionCommandFinished(_ session: TerminalSession, command: String, exitCode: Int32?, duration: TimeInterval) {
        // It may have changed what a block shows (a commit, a branch), in any window.
        NotificationCenter.default.post(name: Blocks.commandFinished, object: nil)
        guard let pane = pane(for: session) else { return }
        PluginHost.shared.emit("commandFinished", ["command": command, "exitCode": exitCode.map { Int($0) } as Any? ?? NSNull(),
                                                   "duration": duration, "cwd": session.workingDirectory ?? ""])
        // A command that ran a while finished out of sight: its tab says so
        // until you look (a quick one isn't news).
        if duration >= 3, !isLookedAt(pane) { markAttention(pane) }
        guard duration >= config.notifyOnCommandFinishAfter else { return }
        switch config.notifyOnCommandFinish {
        case .never: return
        case .unfocused: if isLookedAt(pane) { return }
        case .always: break
        }
        let failed = (exitCode ?? 0) != 0
        let what = command.isEmpty ? "Command" : command
        let outcome = failed ? "failed (exit \(exitCode!))" : "finished"
        Notifier.shared.post(title: "\(what) \(outcome)",
                             body: "after \(Notifier.duration(duration)) · \(title(ofPane: pane))", pane: pane.paneID)
    }
    private func notifyIfNeeded(_ session: TerminalSession) {
        guard let pane = pane(for: session) else { return }
        let key = ObjectIdentifier(session)
        let top = session.programStatus.headline
        let looked = isLookedAt(pane)
        // Once per state change, not per report.
        let sound = top.flatMap { config.programStatusSound[$0.state] }
        if let top, let sound {
            if soundedRecords[key] != Self.signature(top) {
                soundedRecords[key] = Self.signature(top)
                if !looked { StatusSound.play(sound, for: pane.paneID) }
            }
        } else {
            soundedRecords[key] = nil
        }
        guard let top, config.programStatusNotify.contains(top.state) else { notifiedRecords[key] = nil; return }
        guard notifiedRecords[key] != Self.signature(top) else { return }
        notifiedRecords[key] = Self.signature(top)
        // In the window: the pane's edge lights up (unless you're typing in it).
        if pane !== focusedTerminal || !(window?.isKeyWindow ?? false) {
            pane.flashHalo(Self.color(for: top.state))
        }
        guard !looked, config.desktopNotifications else { return }
        let app = session.programStatus.effectiveApp(of: top)
        let what = [app, top.title].filter { !$0.isEmpty }.joined(separator: " · ")
        Notifier.shared.post(title: "\(Self.label(for: top))\(what.isEmpty ? "" : ": " + what)",
                             body: top.message.isEmpty ? title(ofPane: pane) : top.message, pane: pane.paneID,
                             sound: sound == nil)
    }

    /// The settings changed: what programs are in now isn't news, even in a
    /// state a setting just took in — only what they go on to do is.
    func rememberProgramStates() {
        for pane in allPanes {
            let key = ObjectIdentifier(pane.session)
            let top = pane.session.programStatus.headline
            notifiedRecords[key] = top.flatMap { config.programStatusNotify.contains($0.state) ? Self.signature($0) : nil }
            soundedRecords[key] = top.flatMap { config.programStatusSound[$0.state] != nil ? Self.signature($0) : nil }
        }
    }

    /// The user can see this pane right now: Libertty is active, its window key,
    /// its tab selected.
    private func isLookedAt(_ pane: TerminalView) -> Bool {
        NSApp.isActive && window?.isKeyWindow == true
            && (selectedTab.panes.contains { $0 === pane } || selectedTab.parked.contains { $0.showsCard && $0.pane === pane })
    }

    /// Window ▸ Picture in Picture: the focused pane in a floating window.
    func togglePictureInPicture() {
        if !selectedTab.isTerminal { select(terminalTab) }
        let pane = focusedTerminal
        MainActor.assumeIsolated {
            // Whichever window has the pane by then (it may move to another).
            PictureInPicture.toggle(pane, title: { [weak pane] in
                pane.map(Self.title(ofPane:)) ?? ""
            }, reveal: { [weak self, weak pane] in
                guard let pane else { return }
                Probe.activateApp()
                if let app = NSApp.delegate as? AppDelegate { _ = app.reveal(paneID: pane.paneID) } else { _ = self?.reveal(paneID: pane.paneID) }
            })
        }
    }

    /// This window's panes, for Web Access.
    var webPanes: [WebPane] {
        let name = window?.title ?? "Libertty"
        return workspaces.enumerated().flatMap { w, workspace in
            let tabs = w == activeWorkspace ? self.tabs : workspace.tabs
            let place = workspaces.count > 1 ? "\(name) · \(workspace.name)" : name
            return tabs.enumerated().flatMap { index, tab in
                tab.everyPane.map { pane in
                    WebPane(id: pane.paneID, title: title(ofPane: pane), place: tabs.count > 1 ? "\(place), tab \(index + 1)" : place,
                            host: host?.destination, session: pane.session)
                }
            }
        }
    }

    func title(ofPane pane: TerminalView) -> String { Self.title(ofPane: pane) }

    /// A notification was clicked: bring its pane forward. Returns whether it is here.
    func reveal(paneID: String) -> Bool {
        guard let pane = allPanes.first(where: { $0.paneID == paneID }),
              let tab = everyTab.first(where: { $0.panes.contains { $0 === pane } || $0.parked.contains { $0.pane === pane } })
        else { return false }
        return reveal(pane, in: tab)
    }

    /// Bring a tab forward, and in a split one of its panes, a terminal or
    /// a document (Go to Pane): behind a zoomed pane it couldn't be seen, so
    /// back to the split.
    @discardableResult
    func reveal(_ leaf: NSView?, in tab: TerminalTab) -> Bool {
        // A tab of another workspace brings its workspace forward.
        if !tabs.contains(where: { $0 === tab }), let i = workspaces.firstIndex(where: { $0.tabs.contains { $0 === tab } }) {
            switchWorkspace(to: i)
        }
        guard tabs.contains(where: { $0 === tab }) else { return false }
        // A parked pane comes back to be seen (a notification names it).
        if let pane = leaf as? TerminalView, tab.parked.contains(where: { $0.pane === pane }) {
            select(tab)
            unpark(pane)
            window?.makeKeyAndOrderFront(nil)
            return true
        }
        select(tab)
        if let leaf, let container = tab.container, container.views.contains(where: { $0 === leaf }) {
            if let zoomed = container.zoomed, zoomed !== leaf { container.toggleZoom(zoomed) }
            focusLeaf(leaf)
        }
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    /// The glyph for what a pane runs (its tab's icon, for the palette).
    func symbol(of pane: TerminalView) -> String {
        programs[ObjectIdentifier(pane.session)]?.symbol ?? "apple.terminal"
    }

    /// How many panes have a program in a state the Dock badge counts
    /// (`program-status-dock-badge`; by default, waiting for you).
    var attentionCount: Int {
        allPanes.filter { $0.session.programStatus.headline(among: config.programStatusDockBadge) != nil }.count
    }

    func sessionExited(_ session: TerminalSession, status: Int32) {
        guard let pane = pane(for: session) else { return }
        // In a workspace that isn't showing: its panes are cleared away when
        // it comes back — unless nothing of it is left running.
        if let i = workspaces.indices.first(where: {
            $0 != activeWorkspace && workspaces[$0].tabs.contains { $0.everyPane.contains { $0 === pane } }
        }) {
            // All its programs gone: it goes too — unless it holds unsaved text.
            if workspaces[i].tabs.flatMap(\.everyPane).allSatisfy({ $0.session.hasExited }),
               !documents(in: workspaces[i].tabs).contains(where: \.hasUnsavedChanges) {
                endWorkspace(workspaces[i].id, undoable: false)
            }
            return
        }
        // A parked program ended: nothing to bring back.
        if let tab = everyTab.first(where: { $0.parked.contains { $0.pane === pane } }) {
            tab.parked.removeAll { $0.pane === pane }
            pane.isParked = false
            PictureInPicture.paneClosed(pane)
            Notifier.shared.clear(pane: pane.paneID)
            updateSidebar()
            return
        }
        // A program that failed at once (or any, with wait-after-command or
        // --keep-open) leaves its pane, so what it said can be read; a key
        // in it closes it (Ghostty, Rex).
        let ran = session.startedAt.map { CACurrentMediaTime() - $0 }
        let code = PTY.exitCode(fromWaitStatus: status)
        let failedAtOnce = code != 0 && config.abnormalCommandExitRuntime > 0
            && (ran.map { $0 * 1000 < Double(config.abnormalCommandExitRuntime) } ?? false)
        if !Self.oneShot, failedAtOnce || config.waitAfterCommand || session.keepsPaneAfterExit, tab(containing: pane) != nil {
            let after = ran.map { String(format: " after %.2f s", $0) } ?? ""
            session.note("[Exited with status \(code)\(after). Press any key to close this pane.]")
            pane.closesOnKey = true
            updateSidebar()
            return
        }
        // The program ended by itself: nothing to bring back.
        removePane(pane, undoable: false)
    }

    func sessionWorkingDirectoryChanged(_ session: TerminalSession) {
        // This Mac's folders, for Go to Directory (a host's are that machine's).
        if session.host == nil, let directory = session.workingDirectory { RecentFolders.shared.record(directory) }
        updateTitle()
        if session === focusedTerminal.session { updateSidebar() } else { updateSidebar(force: false) }
    }

    // MARK: Title & program status

    /// A tab's name: its override, else the focused program's title (OSC
    /// 0/2), else its directory.
    func title(of tab: TerminalTab) -> String {
        let name = plainTitle(of: tab)
        return tab.rang ? "🔔 " + name : name
    }

    private func plainTitle(of tab: TerminalTab) -> String {
        let label = self.label(of: tab)
        return label.detail.isEmpty ? label.name : "\(label.name) — \(label.detail)"
    }

    /// How a tab names itself (GoRex): what runs in its focused pane, and
    /// where. A program's own title wins (an editor names its file); a
    /// title the shell set ("user@host:~/src") says less than the program
    /// and its folder do. ssh says where it went. Overrides win over all.
    func label(of tab: TerminalTab) -> (name: String, detail: String) {
        if !tab.titleOverride.isEmpty { return (tab.titleOverride, "") }
        if !tab.paneTitleOverride.isEmpty { return (tab.paneTitleOverride, "") }
        guard let pane = tab.focusedPane else { return (tab.document?.title ?? "Libertty", "") }
        return label(of: pane)
    }

    func label(of pane: TerminalView) -> (name: String, detail: String) {
        let session = pane.session
        let directory = Self.shortDirectory(session.workingDirectory)
        // Named (`+rename-session`, an agent naming its task): that, and what runs there.
        if !session.label.isEmpty {
            return (session.label, programs[ObjectIdentifier(session)]?.name ?? directory)
        }
        let title = ProgramStatusStore.sanitize(session.title).trimmingCharacters(in: .whitespaces)
        let ownTitle = !title.isEmpty && !Self.isShellTitle(title, directory: session.workingDirectory)
        if let tile = programs[ObjectIdentifier(session)] {
            if let host = tile.host { return ("SSH", host) }
            if ownTitle { return (title, "") }
            return (tile.name, directory)
        }
        // At a prompt: the shell's own title says no more than the folder —
        // unless where it is isn't known, when it's the best name there is.
        if ownTitle { return (title, "") }
        if !directory.isEmpty { return (directory, "") }
        return (title.isEmpty ? "Libertty" : Self.place(inShellTitle: title), "")
    }

    /// A tab's progress: a pane's OSC 9;4 report, else an OSC 7501 record's.
    func progress(of tab: TerminalTab) -> TerminalProgress? {
        if let p = tab.everyPane.compactMap(\.session.progress).first { return p }
        if let record = status(of: tab), record.state == .working, let percent = record.progress {
            return TerminalProgress(state: .normal, percent: percent)
        }
        return nil
    }

    /// The most urgent OSC 7501 record among a tab's panes, of the states
    /// tabs show (`program-status-indicator`).
    func status(of tab: TerminalTab) -> ProgramStatusStore.Record? {
        tab.everyPane.compactMap { $0.session.programStatus.headline(among: config.programStatusIndicator) }
            .max { $0.state < $1.state }
    }

    /// The window title is the selected tab's. The subtitle shows the most
    /// urgent OSC 7501 record across every tab, so an agent waiting in a
    /// background tab still shows. Program text is untrusted, so it is
    /// sanitized by the store and shown as plain text.
    func updateTitle() {
        guard let window else { return }
        let tab = selectedTab
        window.title = tab.paneTitleOverride.isEmpty ? title(of: tab) : tab.paneTitleOverride
        // A document tab gets the proxy icon (⌘-click for its folders).
        window.representedURL = tab.document?.url

        if selectedTab.broadcasting {
            window.subtitle = "Broadcasting input to \(selectedTab.panes.count) panes"
            updateSidebar()
            return
        }
        if let host {
            // Which machine this is, always.
            let down = allPanes.contains { !$0.session.linkUp }
            window.subtitle = host.destination + (down ? " · reconnecting…" : "")
            hostChip.refresh(host: host, linkUp: !down)
            updateSidebar()
            return
        }
        hostChip.refresh(host: nil, linkUp: true)
        let candidates = allPanes.compactMap { pane in
            pane.session.programStatus.headline(among: config.programStatusIndicator).map { (pane.session.programStatus, $0) }
        }
        if let (store, record) = candidates.max(by: { $0.1.state < $1.1.state }) {
            let app = store.effectiveApp(of: record)
            var parts: [String] = [Self.label(for: record)]
            if !app.isEmpty { parts.append(app) }
            if !record.title.isEmpty { parts.append(record.title) }
            if !record.message.isEmpty { parts.append(record.message) }
            if let progress = record.progress { parts.append("\(progress)%") }
            window.subtitle = parts.joined(separator: " · ")
        } else {
            window.subtitle = ""
        }
        updateSidebar()
    }

    /// View ▸ Change Terminal Title / Change Tab Title (Ghostty's
    /// prompt_surface_title / prompt_tab_title). Empty goes back to the
    /// program's title.
    func promptTitle(tab isTab: Bool) {
        guard let window else { return }
        // A tab is renamed in place where it's listed, when that shows.
        if isTab, let i = tabs.firstIndex(where: { $0 === selectedTab }) {
            if config.tabBar == .top, tabStripTitles != nil { return tabStrip.beginRename(at: i) }
            // (Not a tab the sidebar's filters fold away: the alert, then.)
            if config.tabBar == .sidebar, isSidebarShown, sidebar.shows(row: i) { return sidebar.beginRename(row: i) }
        }
        let tab = selectedTab
        let alert = NSAlert()
        alert.messageText = isTab ? "Change Tab Title" : "Change Terminal Title"
        alert.informativeText = "Leave empty to use the title the program sets."
        let field = NSTextField(string: isTab ? tab.titleOverride : tab.paneTitleOverride)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = window.title
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let text = ProgramStatusStore.sanitize(field.stringValue)
            if isTab { tab.titleOverride = text } else { tab.paneTitleOverride = text }
            self.updateTitle()
            self.window?.makeFirstResponder(tab.focusTarget)
        }
    }

    // MARK: Codex's turn

    /// Codex says when its turn ends (`notify`), not when it starts: Return
    /// in a pane where Codex runs starts one — its tab says working until
    /// the turn ends (done, waiting for approval) or Codex goes quiet (no
    /// output for 5 s: its status line ticks every second while it works,
    /// so a Return that started nothing ends at once).
    func promptSubmitted(in pane: TerminalView) {
        guard programs[ObjectIdentifier(pane.session)]?.name == "Codex" else { return }
        let status = pane.session.programStatus
        // Already working, or waiting for an answer this Return may give: as it is.
        if let turn = status.records["turn"], turn.app == "codex", turn.state == .working { return }
        status.apply(ProgramStatusStore.Report(clear: false, state: .working, kind: .none, progress: nil, id: "turn",
                                               app: "codex", title: "", message: ""))
        sessionProgramStatusChanged(pane.session)
        watchCodexTurn(pane, since: CACurrentMediaTime())
    }

    private func watchCodexTurn(_ pane: TerminalView, since: CFTimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak pane] in
            guard let self, let pane else { return }
            let status = pane.session.programStatus
            guard let turn = status.records["turn"], turn.app == "codex", turn.state == .working else { return }
            let last = max(since, pane.session.outputMark.time)
            if CACurrentMediaTime() - last > 5 {
                status.clear(id: "turn")
                self.sessionProgramStatusChanged(pane.session)
            } else {
                self.watchCodexTurn(pane, since: since)
            }
        }
    }
}
