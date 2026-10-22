import AppKit
import LiberttyCore
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controllers: [TerminalWindowController] = []
    private var configToken: AnyObject?
    private var menuKeybinds: Keybinds?
    private var globalKeybinds: [Keybinds.Binding]?
    private var shownWarnings: [String] = []
    private var appearanceObservation: NSKeyValueObservation?
    /// Finder/`open` asked for a folder or script before launch finished:
    /// that window replaces the usual first one.
    private var openedDocument = false
    private var launched = false

    /// `Libertty [--cols N --rows N] -e COMMAND...` runs COMMAND in the first
    /// window instead of the login shell (benchmarks, `open -a Libertty --args -e ...`).
    private lazy var launch: (command: String?, cols: Int?, rows: Int?) = {
        let args = CommandLine.arguments
        func int(_ name: String) -> Int? {
            args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
        }
        let command = args.firstIndex(of: "-e").map { args[($0 + 1)...].joined(separator: " ") }
        return (command?.isEmpty == false ? command : nil, int("--cols"), int("--rows"))
    }()

    /// One command (`-e`) or a measurement: nothing to keep or bring back.
    private var oneShot: Bool { launch.command != nil || ResizeTrace.requested || LatencyTrace.requested }
    private var saveTimer: Timer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window: folders opened at launch get persistent sessions too.
        let config = ConfigStore.shared.config
        Persistence.setUp(wanted: (config.sessionPersistence && !oneShot) || CommandLine.arguments.contains("--persist"))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        Notifier.shared.onActivate = { [weak self] pane in _ = self?.reveal(paneID: pane) }
        _ = SecureInput.shared
        NSApp.servicesProvider = ServiceProvider()
        // Plugins that are on start with the app (their commands, their events).
        PluginHost.shared.start()
        configToken = ConfigStore.shared.observe { [weak self] _ in self?.configDidChange() }
        // `theme = light:A,dark:B` follows the system appearance.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { ConfigStore.shared.notify() }
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(remoteRequest(_:)), name: RemoteControl.notification, object: nil,
            suspensionBehavior: .deliverImmediately)

        if !oneShot { restoreWindows() }
        restoring = false
        // `libertty +open` when Libertty wasn't running: its requests ride on the
        // launch arguments (a notification would arrive before anyone listens).
        let opens = Self.launchOpenRequests()
        if !openedDocument && controllers.isEmpty && !opens.contains(where: { $0["split"] != "1" }) {
            open(tabbedInto: nil, command: launch.command, cols: launch.cols, rows: launch.rows)
        }
        opens.forEach(handleOpen)
        if !oneShot {
            MainActor.assumeIsolated { WebAccess.shared.apply(ConfigStore.shared.config) }
            saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.saveWindows() }
            MainActor.assumeIsolated { UpdateController.shared.start() }
            // The menu item says "Restart to Update" once one is downloaded.
            NotificationCenter.default.addObserver(forName: UpdateController.readyChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let keybinds = self.menuKeybinds else { return }
                    NSApp.mainMenu = self.makeMainMenu(keybinds)
                }
            }
        }
        // Launching is an explicit request to use Libertty; started from a shell,
        // cooperative activation would leave the window behind (or in Stage
        // Manager's strip).
        activate()
    }

    /// The layout to bring back: the file, unless this Mac's liberttyd holds
    /// a newer one — the file was lost or failed to write. The newer copy
    /// is the one saved later. Host windows come from the file either way
    /// (their own liberttyd is asked when they connect).
    private static func bestLayout(live: Set<String>) -> SavedState? {
        let file = Restoration.load()
        guard Persistence.enabled, !Restoration.isPrivate,
              case .layout(let held, mine: true) = Restoration.held(at: .local, local: true, timeout: 1),
              (held.savedAt ?? 0) > (file?.savedAt ?? 0) else { return file }
        // liberttyd's windows for this Mac, the file's for hosts.
        var merged = held
        merged.windows = held.windows.filter { $0.host == nil } + (file?.windows.filter { $0.host != nil } ?? [])
        return merged
    }
    /// Edit ▸ Undo with no window open: the last closed window comes back.
    @objc func undo(_ sender: Any?) { MainActor.assumeIsolated { CloseUndo.shared.manager.undo() } }
    @objc func redo(_ sender: Any?) { MainActor.assumeIsolated { CloseUndo.shared.manager.redo() } }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { CloseUndo.shared.expireAll() }
        // A one-off run (`-e`, a measurement) brings nothing back: end its sessions.
        if oneShot {
            for c in controllers { c.endAllSessions() }
            return
        }
        // Quitting keeps liberttyd's sessions running; the layout says where they go.
        saveWindows()
    }

    private func saveWindows() {
        guard !oneShot else { return }
        if ConfigStore.shared.config.windowSaveState == .never {
            if !controllers.isEmpty || FileManager.default.fileExists(atPath: Restoration.url.path) {
                Restoration.save([])
            }
            return
        }
        Restoration.save(controllers)
    }

    /// Last time's windows, and any liberttyd session no window shows.
    private func restoreWindows() {
        let config = ConfigStore.shared.config
        let sessions = Persistence.enabled ? (DaemonClient.sessions() ?? []) : []
        let live = Set(sessions.map(\.id))
        if config.windowSaveState != .never, let state = Self.bestLayout(live: live) {
            for saved in state.windows {
                guard let controller = TerminalWindowController.restore(saved, live: live, config: config) else { continue }
                show(controller)
            }
        }
        // Programs still running that no saved window holds (the layout was
        // saved before they started, or isn't restored): a window of tabs.
        let shown = Set(controllers.flatMap(\.persistentSessionIDs))
        let orphans = sessions.filter { !shown.contains($0.id) && $0.clients == 0 }
        guard !orphans.isEmpty else { return }
        let saved = SavedWindow(frame: "", sidebar: config.windowSidebar, inspector: config.windowInspector, fontSize: nil,
                                selected: 0, tabs: orphans.map { SavedTab(panes: SavedPane(session: $0.id)) })
        if let controller = TerminalWindowController.restore(saved, live: live, config: config) { show(controller) }
    }

    private func show(_ controller: TerminalWindowController) {
        register(controller)
        controller.showWindow(nil)
        try? controller.start()
    }

    /// Every terminal window (Web Access lists their panes).
    var windowControllers: [TerminalWindowController] { controllers }

    private func register(_ controller: TerminalWindowController) {
        controller.onClose = { [weak self] c in
            self?.controllers.removeAll { $0 === c }
            self?.updateDockBadge()
        }
        // Hidden for undo: not a window to save or count; back on undo.
        controller.onHide = { [weak self] c in self?.controllers.removeAll { $0 === c } }
        controller.onUnhide = { [weak self] c in
            guard let self, !self.controllers.contains(where: { $0 === c }) else { return }
            self.controllers.append(c)
        }
        controller.onAttentionChange = { [weak self] in self?.updateDockBadge() }
        controller.onLayoutChange = { [weak self] in self?.saveSoon() }
        controllers.append(controller)
    }

    /// A layout change is saved shortly after it (coalesced: a burst of
    /// title updates is one write, and an unchanged layout none at all).
    /// Not before the saved windows are all back: a half-restored layout
    /// mustn't replace the one being restored.
    private var pendingSave: DispatchWorkItem?
    private var restoring = true
    private func saveSoon() {
        guard pendingSave == nil, !restoring else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSave = nil
            self?.saveWindows()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Bring the pane with this id forward, in whichever window has it.
    func reveal(paneID: String) -> Bool {
        guard controllers.contains(where: { $0.reveal(paneID: paneID) }) else { return false }
        activate()
        return true
    }

    /// The Dock icon counts panes whose programs are in a state it counts
    /// (`program-status-dock-badge`; by default, waiting for you).
    private func updateDockBadge() {
        let n = controllers.reduce(0) { $0 + $1.attentionCount }
        NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }

    /// Libertty ▸ Quit and End Sessions: what quitting does without persistence.
    @objc func quitEndingSessions(_ sender: Any?) {
        guard confirmUnsavedEverywhere(quitting: true), confirmEndingPrograms(title: "Quit and end every program?") else { return }
        for c in controllers {
            c.skipCloseConfirmation = true
            c.window?.close()
        }
        endingSessions = true
        NSApp.terminate(nil)
    }

    private var endingSessions = false

    /// Quitting keeps liberttyd's programs running, so it needs no question;
    /// without persistence it ends them, so (as in Ghostty) it asks first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Unsaved edits first, whatever happens to the programs (Quit and End
        // Sessions asked already: its windows are gone by now).
        let unsaved = endingSessions ? [] : controllers.flatMap(\.unsavedDocuments)
        if !oneShot, !unsaved.isEmpty {
            switch askAboutUnsaved(unsaved, quitting: true) {
            case .alertFirstButtonReturn:
                TerminalWindowController.saveAll(unsaved) { [weak self] ok in
                    // Saved: the programs' question still comes, as it would have.
                    let programsOK = ok && (self?.endingSessions == true || Persistence.enabled
                        || self?.confirmEndingPrograms(title: "Quit Libertty?") == true)
                    sender.reply(toApplicationShouldTerminate: programsOK)
                }
                return .terminateLater
            case .alertThirdButtonReturn: break
            default: return .terminateCancel
            }
        }
        if oneShot || endingSessions || Persistence.enabled { return .terminateNow }
        return confirmEndingPrograms(title: "Quit Libertty?") ? .terminateNow : .terminateCancel
    }

    /// Save, Cancel, Don't Save about unsaved documents (app-wide, so modal).
    private func askAboutUnsaved(_ unsaved: [DocumentView], quitting: Bool) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        let what = unsaved.count == 1 ? "“\(unsaved[0].url.lastPathComponent)”" : "\(unsaved.count) files"
        alert.messageText = "Save changes to \(what)" + (quitting ? " before quitting?" : "?")
        alert.informativeText = "Your changes are lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        return alert.runModal()
    }

    /// Before closing every window without the windows' own questions:
    /// unsaved documents anywhere, saved (and waited for) or let go.
    private func confirmUnsavedEverywhere(quitting: Bool) -> Bool {
        let unsaved = controllers.flatMap(\.unsavedDocuments)
        guard !unsaved.isEmpty else { return true }
        switch askAboutUnsaved(unsaved, quitting: quitting) {
        case .alertFirstButtonReturn:
            var result: Bool?
            TerminalWindowController.saveAll(unsaved) { result = $0 }
            // Saves finish on the main run loop (the editor hands its text over).
            while result == nil { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            return result == true
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func confirmEndingPrograms(title: String) -> Bool {
        guard ConfigStore.shared.config.confirmClose, controllers.contains(where: \.hasRunningPrograms) else { return true }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Programs are still running and will be ended."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Stay running without windows (the global hotkeys keep working), unless
    /// configured otherwise or launched for one command (`-e`, benchmarks).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        ConfigStore.shared.config.quitAfterLastWindowClosed || launch.command != nil || ResizeTrace.requested
            || LatencyTrace.requested
    }

    /// Clicking the Dock icon with no windows open opens one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { open(tabbedInto: nil) }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "").target = self
        return menu
    }

    private func configDidChange() {
        let store = ConfigStore.shared
        if launched, !oneShot { MainActor.assumeIsolated { WebAccess.shared.apply(store.config) } }
        let keybinds = store.keybinds
        if keybinds != menuKeybinds {
            menuKeybinds = keybinds
            NSApp.mainMenu = makeMainMenu(keybinds)
        }
        if keybinds.global != globalKeybinds {
            globalKeybinds = keybinds.global
            GlobalHotkeys.shared.bind(keybinds.global.map { binding in
                (binding.trigger.configString, { [weak self] in self?.performGlobal(binding.action) })
            })
        }
        if store.warnings != shownWarnings {
            shownWarnings = store.warnings
            ConfigurationErrorsController.shared.update(store.warnings)
        }
    }

    // MARK: Windows

    @objc func newWindow(_ sender: Any?) {
        open(tabbedInto: nil)
    }

    /// The tab bar's "+": a new tab in the key window's tab group.
    @objc func newWindowForTab(_ sender: Any?) {
        newTab(in: NSApp.keyWindow)
    }

    func newTab(in window: NSWindow?) {
        open(tabbedInto: window ?? frontController?.window)
    }

    private func controller(for window: NSWindow?) -> TerminalWindowController? {
        window?.windowController as? TerminalWindowController
    }

    /// The terminal window the user was last in, even while another app is active.
    var frontController: TerminalWindowController? {
        NSApp.orderedWindows.lazy.compactMap { $0.windowController as? TerminalWindowController }.first
    }

    /// Close All Windows: one confirmation for everything still running.
    func closeAllWindows() {
        guard confirmUnsavedEverywhere(quitting: false) else { return }
        let all = controllers
        let close = { for c in all { c.skipCloseConfirmation = true; c.window?.close() } }
        guard ConfigStore.shared.config.confirmClose, all.contains(where: \.hasRunningPrograms) else { return close() }
        let alert = NSAlert()
        alert.messageText = "Close All Windows?"
        alert.informativeText = "Programs are still running in some windows and will be ended."
        alert.addButton(withTitle: "Close All")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { close() }
    }

    @discardableResult
    private func open(tabbedInto host: NSWindow?, command: String? = nil, cols: Int? = nil, rows: Int? = nil,
                      workingDirectory: String? = nil) -> TerminalWindowController? {
        // A tab goes into that window's sidebar.
        if let host = controller(for: host) {
            let tab = host.newTab(command: command, workingDirectory: workingDirectory)
            host.window?.makeKeyAndOrderFront(nil)
            return tab == nil ? nil : host
        }
        do {
            let source = frontController
            // New windows keep the current zoom (⌘+/⌘-) and directory.
            let fontSize = (source?.window?.firstResponder as? TerminalView)?.fontSize
            let controller = try TerminalWindowController(
                config: ConfigStore.shared.config, fontSize: fontSize, cols: cols, rows: rows)
            register(controller)
            controller.showWindow(nil)
            try controller.start(command: command, workingDirectory: workingDirectory ?? source?.focusedWorkingDirectory)
            if ResizeTrace.requested, controllers.count == 1, let window = controller.window {
                ResizeTrace.start(window: window, controller: controller)
            }
            if LatencyTrace.requested, controllers.count == 1 { LatencyTrace.start(controller: controller) }
            return controller
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    /// Names for documents about to open (`libertty +diff` shows "git diff").
    private var pendingDisplayNames: [URL: String] = [:]
    func takeDisplayName(for url: URL) -> String? { pendingDisplayNames.removeValue(forKey: url.standardizedFileURL) }

    /// Connect to Host. `held` (read off the main thread; nil when windows
    /// aren't restored): what the host's liberttyd keeps, and its sessions.
    /// Its windows come back where they have a session no window shows,
    /// and any other such session as a tab — unless this Mac shows that
    /// host already, when connecting again means a new window.
    func openWindows(on host: RemoteHost, held: (Restoration.Held, [SessionInfo]?)?) {
        if let (layout, sessions) = held {
            // Couldn't be read (either part): nothing comes back, and what
            // it keeps stays as it is for now.
            var read = sessions != nil
            if case .unknown = layout { read = false }
            if read { Restoration.unreadHosts.remove(host.destination) } else { Restoration.unreadHosts.insert(host.destination) }
            if let sessions, !controllers.contains(where: { $0.host?.destination == host.destination }),
               restore(layout, sessions: sessions, on: host) {
                return activate()
            }
        }
        _ = openWindow(on: host)
    }

    /// Bring a host's windows back; whether any came.
    private func restore(_ layout: Restoration.Held, sessions: [SessionInfo], on host: RemoteHost) -> Bool {
        let config = ConfigStore.shared.config
        // Sessions there that no window on any Mac shows.
        let detached = Set(sessions.filter { $0.clients == 0 }.map(\.id))
        var opened = false
        if case .layout(let state, let mine) = layout {
            for saved in state.windows {
                guard var window = saved.forConnect(detached: detached, documents: mine) else { continue }
                window.host = host.destination
                guard let controller = TerminalWindowController.restore(window, live: detached, config: config) else { continue }
                show(controller)
                opened = true
            }
        }
        // Programs still running there that no window holds: a window of tabs.
        let shown = Set(controllers.flatMap(\.persistentSessionIDs))
        let orphans = sessions.filter { $0.clients == 0 && !shown.contains($0.id) }
        if !orphans.isEmpty {
            let saved = SavedWindow(frame: "", sidebar: config.windowSidebar, inspector: config.windowInspector, fontSize: nil,
                                    selected: 0, tabs: orphans.map { SavedTab(panes: SavedPane(session: $0.id)) },
                                    host: host.destination)
            if let controller = TerminalWindowController.restore(saved, live: detached, config: config) {
                show(controller)
                opened = true
            }
        }
        return opened
    }

    /// A window whose sessions run on `host` (set up already, see ConnectPanel).
    @discardableResult
    func openWindow(on host: RemoteHost, command: String? = nil) -> TerminalWindowController? {
        do {
            let controller = try TerminalWindowController(config: ConfigStore.shared.config)
            controller.bind(to: host)
            register(controller)
            controller.showWindow(nil)
            try controller.start(command: command)
            activate()
            return controller
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    /// A file shown in the front window (a new window if there is none).
    func openDocument(_ url: URL, line: Int? = nil, edit: Bool? = nil, waitToken: String? = nil) {
        let controller = frontController ?? open(tabbedInto: nil)
        controller?.openDocument(url, line: line, edit: edit, waitToken: waitToken)
        controller?.window?.makeKeyAndOrderFront(nil)
        activate()
    }

    /// Finder Services ▸ New Libertty Window/Tab Here.
    func openHere(_ directories: [String], tab: Bool) {
        for dir in directories { open(tabbedInto: tab ? frontController?.window : nil, workingDirectory: dir) }
        activate()
    }

    // MARK: Opening folders and scripts (default terminal, Finder, `open -a Libertty`)

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // `-e` arguments that are paths also arrive here; they're the command.
        if CommandLine.arguments.dropFirst().contains(filename) { return true }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filename, isDirectory: &isDirectory) else { return false }
        if !launched { openedDocument = true }

        if isDirectory.boolValue {
            open(tabbedInto: nil, workingDirectory: filename)
            activate()
            return true
        }
        // Text (README.md, notes, source): show it. Scripts run, as in Terminal.
        let url = URL(fileURLWithPath: filename)
        let scripts: Set<String> = ["command", "tool", "sh", "zsh", "csh", "pl", "bash"]
        if !scripts.contains(url.pathExtension.lowercased()), DocumentView.canShow(url) {
            openDocument(url)
            return true
        }
        // A script: run it in the user's shell, so their profile (PATH,
        // Homebrew...) applies, by typing its quoted path at the prompt.
        // Control characters would act as keys while typed, and are
        // invisible in the dialog, so such paths are refused.
        guard !filename.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            let alert = NSAlert()
            alert.messageText = "Cannot Execute File"
            alert.informativeText = "This file's path contains hidden control characters, which could make Libertty run a different command than the one shown."
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Allow Libertty to execute \"\(filename)\"?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let quoted = "'" + filename.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let controller = open(tabbedInto: nil, workingDirectory: (filename as NSString).deletingLastPathComponent)
        controller?.focusedTerminal.sendInput(quoted + "\n")
        activate()
        return true
    }

    @objc func makeDefaultTerminal(_ sender: Any?) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .unixExecutable) { error in
            guard let error else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Failed to Set Default Terminal"
                alert.informativeText = "Libertty could not be set as the default terminal application.\n\nError: \(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    private var isDefaultTerminal: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: .unixExecutable)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    // MARK: Config file

    /// Settings… (open_config): the config file in the user's text editor,
    /// created from the template the first time.
    static func openConfigFile() {
        let store = ConfigStore.shared
        store.ensureFile()
        let editor = NSWorkspace.shared.urlForApplication(toOpen: store.url)
            ?? NSWorkspace.shared.urlForApplication(toOpen: .plainText)
        if let editor {
            NSWorkspace.shared.open([store.url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([store.url])
        }
    }

    /// Help ▸ Libertty Help: every option, action and default keybind, as a text file.
    @objc func showHelp(_ sender: Any?) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.libertty.terminal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Libertty Reference.txt")
        try? CLI.reference().write(to: url, atomically: true, encoding: .utf8)
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Global hotkeys

    /// A `global:` keybind fired while any app may be in front.
    private func performGlobal(_ action: Action) {
        switch action {
        case .toggleVisibility:
            toggleVisibility()
        case .newWindow:
            open(tabbedInto: nil)
            activate()
        default:
            // Everything else acts on Libertty's front window, brought forward first.
            if frontController == nil { open(tabbedInto: nil) }
            showFrontWindow()
            ActionDispatcher.perform(action)
        }
    }

    /// Show/Hide All Terminals (toggle_visibility): hide Libertty when it is in
    /// front, otherwise bring its last window forward (onto the current
    /// Space) or open one.
    func toggleVisibility() {
        if NSApp.isActive, NSApp.keyWindow?.windowController is TerminalWindowController {
            NSApp.hide(nil)
            return
        }
        showFrontWindow()
    }

    private func showFrontWindow() {
        NSApp.unhide(nil)
        guard let window = frontController?.window ?? controllers.last?.window else {
            open(tabbedInto: nil)
            return activate()
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isOnActiveSpace {
            // Come to the user rather than switching their Space away.
            let behavior = window.collectionBehavior
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
            window.collectionBehavior = behavior
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        activate()
    }

    private func activate() {
        // A hotkey or launch is the user's own request to switch apps, which
        // is exactly the case cooperative activation may otherwise decline.
        Probe.activateApp()
    }

    // MARK: Remote control (`libertty +action`, `libertty +new-window`)

    /// `libertty +open [--split] FILE[:LINE]`: as a tab, or beside the front
    /// window's terminal (a new window when there is none).
    private func handleOpen(_ info: [String: String]) {
        guard let path = info["path"] else { return }
        let url = path.hasPrefix("http://") || path.hasPrefix("https://") ? URL(string: path) : URL(fileURLWithPath: path)
        // `--edit`/`--wait`: any text file, in the editor (a commit message has no extension).
        let edit = info["edit"] == "1"
        let wait = info["wait"].flatMap { $0.isEmpty ? nil : $0 }
        guard let url, edit ? EditorAssets.canEdit(url) : DocumentView.canShow(url) else {
            if let wait { EditorWait.post(wait) }  // nothing to wait for
            return
        }
        if let name = info["name"], !name.isEmpty { pendingDisplayNames[url.standardizedFileURL] = name }
        let line = info["line"].flatMap { Int($0) }
        guard let controller = frontController ?? open(tabbedInto: nil) else {
            if let wait { EditorWait.post(wait) }  // no window to show it in: nothing to wait for
            return
        }
        if info["split"] == "1" {
            controller.openDocumentInSplit(url, line: line, edit: edit ? true : nil, waitToken: wait)
            controller.window?.makeKeyAndOrderFront(nil)
            activate()
        } else {
            openDocument(url, line: line, edit: edit ? true : nil, waitToken: wait)
        }
    }

    /// `--open-document PATH LINE SPLIT` (from `libertty +open`, see CLI.openFiles).
    private static func launchOpenRequests() -> [[String: String]] {
        let args = CommandLine.arguments
        return args.indices.compactMap { i in
            guard args[i] == "--open-document", i + 3 < args.count else { return nil }
            // Older launchers pass three values; `--edit`/`--wait` add two more.
            var request = ["kind": "open", "path": args[i + 1], "line": args[i + 2], "split": args[i + 3]]
            if i + 5 < args.count, args[i + 4].hasPrefix("edit=") {
                request["edit"] = String(args[i + 4].dropFirst(5))
                request["wait"] = args[i + 5].hasPrefix("wait=") ? String(args[i + 5].dropFirst(5)) : ""
            }
            return request
        }
    }

    @objc private func remoteRequest(_ note: Notification) {
        guard let info = note.userInfo as? [String: String], RemoteControl.isForUs(info) else { return }
        if info["kind"] == "open" { return handleOpen(info) }
        if info["kind"] == "browser" {
            // A window to act in: the front one, or a new one for `open`.
            let controller = frontController ?? (info["op"] == "open" ? open(tabbedInto: nil) : nil)
            BrowserAutomation.handle(info, in: controller)
            if info["op"] == "open" { activate() }
            return
        }
        if info["kind"] == "connect", let destination = info["host"] {
            return MainActor.assumeIsolated { ConnectPanel.shared.show(destination: destination) }
        }
        if info["kind"] == "new-window" {
            let command = info["command"].flatMap { $0.isEmpty ? nil : $0 }
            open(tabbedInto: info["tab"] == "1" ? frontController?.window : nil, command: command,
                 workingDirectory: info["cwd"])
            return activate()
        }
        if info["kind"] == "focus", let id = info["id"] {
            if controllers.contains(where: { $0.reveal(paneID: id) }) { activate() }
            return
        }
        if info["kind"] == "attach", let id = info["id"] {
            // `libertty +attach ID`: a liberttyd session in a tab (or window) here.
            if info["tab"] == "1", let host = frontController {
                host.attachTab(id)
                host.window?.makeKeyAndOrderFront(nil)
            } else {
                let config = ConfigStore.shared.config
                let saved = SavedWindow(frame: "", sidebar: config.windowSidebar, inspector: config.windowInspector,
                                        fontSize: nil, selected: 0, tabs: [SavedTab(panes: SavedPane(session: id))])
                if let controller = TerminalWindowController.restore(saved, live: [id], config: config) { show(controller) }
            }
            return activate()
        }
        guard let text = info["action"], let action = Action(text), ActionDispatcher.allowedRemotely(action) else { return }
        ActionDispatcher.perform(action)
    }

    // MARK: Menu

    @objc func menuAction(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? ActionBox)?.action else { return }
        ActionDispatcher.perform(action, in: NSApp.keyWindow?.firstResponder as? TerminalView)
    }

    @objc func useFloatAsDefault(_ sender: Any?) {
        let floating = (NSApp.keyWindow?.windowController as? TerminalWindowController)?.isFloatingOnTop ?? false
        UserDefaults.standard.set(floating, forKey: TerminalWindowController.floatDefaultsKey)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undo(_:)) || item.action == #selector(redo(_:)) {
            let manager = MainActor.assumeIsolated { CloseUndo.shared.manager }
            let undo = item.action == #selector(undo(_:))
            item.title = undo ? manager.undoMenuItemTitle : manager.redoMenuItemTitle
            return undo ? manager.canUndo : manager.canRedo
        }
        if let action = (item.representedObject as? ActionBox)?.action, action == .toggleBroadcastInput {
            item.state = frontController?.isBroadcasting == true ? .on : .off
        }
        let controller = NSApp.keyWindow?.windowController as? TerminalWindowController
        if item.action == #selector(makeDefaultTerminal(_:)) {
            return Bundle.main.bundleURL.pathExtension == "app" && !isDefaultTerminal
        }
        if item.action == #selector(useFloatAsDefault(_:)) { return controller != nil }
        guard let action = (item.representedObject as? ActionBox)?.action else { return true }
        switch action {
        case .toggleSecureInput:
            item.state = SecureInput.shared.requested ? .on : .off
            return true
        case .toggleReadonly:
            let view = NSApp.keyWindow?.firstResponder as? TerminalView
            item.state = view?.isReadOnly == true ? .on : .off
            return view != nil
        case .toggleWindowFloatOnTop:
            item.state = controller?.isFloatingOnTop == true ? .on : .off
            return controller != nil
        case .toggleSidebar:
            item.title = controller?.isSidebarShown == false ? "Show Sidebar" : "Hide Sidebar"
            return controller != nil
        case .toggleInspector:
            item.title = controller?.isInspectorShown == true ? "Hide Inspector" : "Show Inspector"
            return controller != nil
        case .endSearch, .navigateSearch:
            return controller?.isSearching == true
        case .toggleMarkdownSource:
            let doc = controller?.selectedDocument
            item.state = doc?.showsSource == true ? .on : .off
            return doc?.isMarkdown == true
        case .toggleEditor:
            let doc = controller?.selectedDocument
            item.state = doc?.isEditing == true ? .on : .off
            return doc?.kind == .text
        case .toggleSplitZoom:
            // A check while zoomed: otherwise nothing says the other panes are there.
            item.state = controller?.isZoomed == true ? .on : .off
            return (controller?.selectedPaneCount ?? 0) > 1
        case .restartSurface:
            return controller?.canRestartFocusedPane == true
        case .parkSurface:
            return controller?.canParkFocusedPane == true
        case .unparkSurface:
            return controller?.parkedPanes.isEmpty == false
        case .closeWorkspace, .nextWorkspace, .previousWorkspace:
            return (controller?.workspaceNames.count ?? 0) > 1
        case .floatSurface:
            let floating = controller?.hasFloatingPane == true
            item.title = floating ? "Bring Back Floating Pane" : "Float Pane"
            return floating || controller?.canParkFocusedPane == true
        case .newWindow, .newTab, .closeAllWindows, .toggleVisibility, .openConfig, .reloadConfig, .quit:
            return true
        default:
            return controller != nil
        }
    }

    /// Ghostty's menus (macos/Sources/App/MainMenu.xib), item for item, with
    /// its menu icons, for what Libertty has. Key equivalents come from the
    /// keybind table, so a rebound key shows (and works) in the menu, and an
    /// unbound one leaves it.
    private func makeMainMenu(_ keybinds: Keybinds) -> NSMenu {
        let main = NSMenu()

        @discardableResult
        func item(_ title: String, _ action: Action? = nil, selector: Selector? = nil, key: String = "",
                  mods: NSEvent.ModifierFlags = [.command], symbol: String? = nil, in menu: NSMenu) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: selector ?? #selector(menuAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            if let action {
                if selector == nil {
                    item.target = self
                    item.representedObject = ActionBox(action)
                }
                if let trigger = keybinds.trigger(for: action) {
                    (item.keyEquivalent, item.keyEquivalentModifierMask) = trigger.menuEquivalent
                } else {
                    item.keyEquivalent = ""
                }
            }
            // Menu icons are the norm from macOS 26 on, as in Ghostty.
            if let symbol, #available(macOS 26, *) {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            }
            return item
        }

        let app = submenu("Libertty", in: main)
        item("About Libertty", selector: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), symbol: "info.circle", in: app)
        let update = item(MainActor.assumeIsolated { UpdateController.shared.isReady } ? "Restart to Update…" : "Check for Updates…",
                          selector: #selector(UpdateController.checkForUpdates(_:)), symbol: "arrow.down.circle", in: app)
        update.target = MainActor.assumeIsolated { UpdateController.shared }
        app.addItem(.separator())
        item("Settings…", .openConfig, symbol: "gear", in: app)
        item("Reload Configuration", .reloadConfig, symbol: "arrow.trianglehead.2.clockwise.rotate.90", in: app)
        item("Secure Keyboard Entry", .toggleSecureInput, symbol: "lock.display", in: app)
        let web = item("Web Access…", selector: #selector(WebAccessPanel.show(_:)), symbol: "globe", in: app)
        web.target = MainActor.assumeIsolated { WebAccessPanel.shared }
        item("Make Libertty the Default Terminal", selector: #selector(makeDefaultTerminal(_:)), symbol: "star.fill", in: app)
            .target = self
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        item("Hide Libertty", selector: #selector(NSApplication.hide(_:)), key: "h", in: app)
        item("Hide Others", selector: #selector(NSApplication.hideOtherApplications(_:)), key: "h",
             mods: [.command, .option], in: app)
        item("Show All", selector: #selector(NSApplication.unhideAllApplications(_:)), in: app)
        app.addItem(.separator())
        item("Quit Libertty", .quit, selector: #selector(NSApplication.terminate(_:)), in: app)
        if Persistence.enabled {
            // Quitting keeps the programs running; this one ends them first.
            let end = item("Quit and End Sessions", selector: #selector(quitEndingSessions(_:)), key: "q",
                           mods: [.command, .option], in: app)
            end.target = self
            end.isAlternate = true
        }

        let file = submenu("File", in: main)
        item("New Window", .newWindow, symbol: "macwindow.badge.plus", in: file)
        item("New Tab", .newTab, symbol: "macwindow", in: file)
        item("Connect to Host…", .connectToHost, symbol: "network", in: file)
        file.addItem(.separator())
        item("Split Right", .newSplit(.right), symbol: "rectangle.righthalf.inset.filled", in: file)
        item("Split Left", .newSplit(.left), symbol: "rectangle.leadinghalf.inset.filled", in: file)
        item("Split Down", .newSplit(.down), symbol: "rectangle.bottomhalf.inset.filled", in: file)
        item("Split Up", .newSplit(.up), symbol: "rectangle.tophalf.inset.filled", in: file)
        file.addItem(.separator())
        item("Close", .closeSurface, symbol: "xmark", in: file)
        item("Close Tab", .closeTab, in: file)
        item("Close Window", .closeWindow, in: file)
        item("Close All Windows", .closeAllWindows, in: file)
        file.addItem(.separator())
        // To whatever has the keyboard: a document in the editor saves (DocumentView.saveDocument).
        item("Save", selector: #selector(DocumentView.saveDocument(_:)), key: "s", symbol: "square.and.arrow.down", in: file)
        file.addItem(.separator())
        item("Export Text As…", .writeScrollbackFile("save"), symbol: "square.and.arrow.up", in: file)
        item("Open Scrollback in Tab", .writeScrollbackFile("open"), symbol: "doc.text", in: file)

        let edit = submenu("Edit", in: main)
        // Standard selectors, so text fields (the title prompts) edit as usual.
        item("Undo", selector: #selector(undo(_:)), key: "z", in: edit)
        item("Redo", selector: #selector(redo(_:)), key: "z", mods: [.command, .shift], in: edit)
        edit.addItem(.separator())
        item("Copy", .copyToClipboard, selector: #selector(NSText.copy(_:)), in: edit)
        item("Paste", .pasteFromClipboard, selector: #selector(NSText.paste(_:)), in: edit)
        item("Select All", .selectAll, selector: #selector(NSResponder.selectAll(_:)), in: edit)
        item("Copy Output of Last Command", .copyCommandOutput, symbol: "text.append", in: edit)
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        let findParent = edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        findParent.submenu = find
        if #available(macOS 26, *) {
            findParent.image = NSImage(systemSymbolName: "text.page.badge.magnifyingglass", accessibilityDescription: "Find")
        }
        item("Find...", .startSearch, symbol: "magnifyingglass", in: find)
        item("Find Next", .navigateSearch(next: true), in: find)
        item("Find Previous", .navigateSearch(next: false), in: find)
        find.addItem(.separator())
        item("Hide Find Bar", .endSearch, in: find)
        find.addItem(.separator())
        item("Use Selection for Find", .searchSelection, in: find)

        edit.addItem(.separator())
        // Lets the system put Emoji & Symbols, AutoFill… here too.
        item("Emoji & Symbols", selector: #selector(NSApplication.orderFrontCharacterPalette(_:)), key: " ",
             mods: [.command, .control], symbol: "face.smiling", in: edit)

        let view = submenu("View", in: main)
        item("Command Palette", .toggleCommandPalette, symbol: "filemenu.and.selection", in: view)
        item("Go to Pane...", .gotoPane, symbol: "rectangle.3.group", in: view)
        view.addItem(.separator())
        item("Show Sidebar", .toggleSidebar, symbol: "sidebar.left", in: view)
        item("Show Inspector", .toggleInspector, symbol: "sidebar.right", in: view)
        view.addItem(.separator())
        item("Reset Font Size", .resetFontSize, symbol: "textformat.size", in: view)
        item("Increase Font Size", .increaseFontSize(1), symbol: "textformat.size.larger", in: view)
        item("Decrease Font Size", .decreaseFontSize(1), symbol: "textformat.size.smaller", in: view)
        view.addItem(.separator())
        item("Change Tab Title...", .promptTabTitle, symbol: "pencil.line", in: view)
        item("Change Terminal Title...", .promptSurfaceTitle, in: view)
        item("Terminal Read-only", .toggleReadonly, symbol: "eye.fill", in: view)
        item("Show Markdown Source", .toggleMarkdownSource, symbol: "chevron.left.forwardslash.chevron.right", in: view)
        item("Edit Document", .toggleEditor, symbol: "pencil", in: view)
        view.addItem(.separator())
        item("Git", .openGit, symbol: "arrow.triangle.branch", in: view)
        item("Browser", .openBrowser, symbol: "globe", in: view)
        item("Tasks", .openTasks, symbol: "gauge.with.dots.needle.33percent", in: view)
        item("New Canvas", .newCanvas, symbol: CanvasBlock.symbol, in: view)
        item("Profiler", .openProfiler, symbol: ProfilerBlock.symbol, in: view)
        item("Board", .openBoard, symbol: BoardBlock.symbol, in: view)
        item("Plugins", .openPlugins, symbol: PluginsBlock.symbol, in: view)
        item("Screen", .openScreen, symbol: ScreenShareBlock.symbol, in: view)

        let window = submenu("Window", in: main)
        item("Minimize", selector: #selector(NSWindow.performMiniaturize(_:)), key: "m", in: window)
        item("Zoom", selector: #selector(NSWindow.performZoom(_:)), in: window)
        window.addItem(.separator())
        // Not taken from the keybinds (as in Ghostty): a custom key here
        // would disable macOS's own full-screen shortcut.
        item("Toggle Full Screen", selector: #selector(NSWindow.toggleFullScreen(_:)), key: "f",
             mods: [.command, .control], symbol: "square.arrowtriangle.4.outward", in: window)
        item("Show/Hide All Terminals", .toggleVisibility, symbol: "eye", in: window)
        item("Quick Terminal", .toggleQuickTerminal, symbol: "rectangle.topthird.inset.filled", in: window)
        item("Picture in Picture", .togglePictureInPicture, symbol: "pip", in: window)
        window.addItem(.separator())
        item("Broadcast Input to All Panes", .toggleBroadcastInput, symbol: "dot.radiowaves.left.and.right", in: window)
        item("Show All Tabs", .toggleTabOverview, symbol: "square.grid.2x2", in: window)
        item("Show Previous Tab", .previousTab, in: window)
        item("Show Next Tab", .nextTab, in: window)
        window.addItem(.separator())
        item("Zoom Split", .toggleSplitZoom, symbol: "arrow.up.left.and.arrow.down.right", in: window)
        item("Restart Shell in Pane", .restartSurface, symbol: "arrow.counterclockwise", in: window)
        item("Park Pane", .parkSurface, symbol: "tray.and.arrow.down", in: window)
        item("Unpark Pane", .unparkSurface, symbol: "tray.and.arrow.up", in: window)
        item("Float Pane", .floatSurface, symbol: "pip.enter", in: window)
        window.addItem(.separator())
        item("New Workspace…", .newWorkspace, symbol: "square.stack.3d.up", in: window)
        item("Rename Workspace…", .renameWorkspace, in: window)
        item("Close Workspace", .closeWorkspace, in: window)
        item("Show Next Workspace", .nextWorkspace, in: window)
        item("Show Previous Workspace", .previousWorkspace, in: window)
        window.addItem(.separator())
        item("Select Previous Split", .gotoSplit(.previous), symbol: "chevron.backward.2", in: window)
        item("Select Next Split", .gotoSplit(.next), symbol: "chevron.forward.2", in: window)
        let select = NSMenu(title: "Select Split")
        window.addItem(withTitle: "Select Split", action: nil, keyEquivalent: "").submenu = select
        item("Select Split Above", .gotoSplit(.direction(.up)), symbol: "arrow.up", in: select)
        item("Select Split Below", .gotoSplit(.direction(.down)), symbol: "arrow.down", in: select)
        item("Select Split Left", .gotoSplit(.direction(.left)), symbol: "arrow.left", in: select)
        item("Select Split Right", .gotoSplit(.direction(.right)), symbol: "arrow.right", in: select)
        let resize = NSMenu(title: "Resize Split")
        window.addItem(withTitle: "Resize Split", action: nil, keyEquivalent: "").submenu = resize
        item("Equalize Splits", .equalizeSplits,
             symbol: "inset.filled.topleft.topright.bottomleft.bottomright.rectangle", in: resize)
        resize.addItem(.separator())
        item("Move Divider Up", .resizeSplit(.up, 10), symbol: "arrow.up.to.line", in: resize)
        item("Move Divider Down", .resizeSplit(.down, 10), symbol: "arrow.down.to.line", in: resize)
        item("Move Divider Left", .resizeSplit(.left, 10), symbol: "arrow.left.to.line", in: resize)
        item("Move Divider Right", .resizeSplit(.right, 10), symbol: "arrow.right.to.line", in: resize)
        window.addItem(.separator())
        item("Return To Default Size", .resetWindowSize, in: window)
        window.addItem(.separator())
        item("Float on Top", .toggleWindowFloatOnTop, symbol: "square.filled.on.square", in: window)
        item("Use as Default", selector: #selector(useFloatAsDefault(_:)), in: window).target = self
        window.addItem(.separator())
        item("Bring All to Front", selector: #selector(NSApplication.arrangeInFront(_:)), in: window)
        NSApp.windowsMenu = window

        let help = submenu("Help", in: main)
        item("Libertty Help", selector: #selector(showHelp(_:)), key: "?", in: help).target = self
        NSApp.helpMenu = help

        return main
    }

    private func submenu(_ title: String, in main: NSMenu) -> NSMenu {
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }
}

/// Finder Services ▸ New Libertty Tab/Window Here (declared in Info.plist).
final class ServiceProvider: NSObject {
    @objc func openTab(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        open(pasteboard, tab: true, error: error)
    }

    @objc func openWindow(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        open(pasteboard, tab: false, error: error)
    }

    private func open(_ pasteboard: NSPasteboard, tab: Bool, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            error.pointee = "Could not load any folder from the selection."
            return
        }
        // Files open in their folder.
        let dirs = Set(urls.map { url -> String in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
            return (isDir ? url : url.deletingLastPathComponent()).path
        })
        (NSApp.delegate as? AppDelegate)?.openHere(dirs.sorted(), tab: tab)
    }
}
