import LiberttyCore
import AppKit

/// Carries out keybind actions, wherever they come from: a key press in a
/// terminal, a menu item, a global hotkey, or `libertty +action` from a script.
enum ActionDispatcher {
    private static var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    /// `view` is the terminal that has focus, if any; window-level actions
    /// fall back to the frontmost Libertty window.
    @discardableResult
    static func perform(_ action: Action, in view: TerminalView? = nil, controller given: TerminalWindowController? = nil) -> Bool {
        let controller = given ?? (view?.window?.windowController as? TerminalWindowController) ?? app?.frontController
        let view = view ?? controller?.focusedTerminal
        func direction(_ d: Action.Direction) -> SplitContainerView.Direction {
            switch d { case .left: .left; case .right: .right; case .up: .up; case .down: .down }
        }
        switch action {
        case .newWindow: app?.newWindow(nil)
        case .newTab: app?.newTab(in: controller?.window)
        case .newSplit(let d): controller?.split(direction(d))
        case .closeSurface: controller?.closePane(nil)
        case .closeTab: controller?.closeSelectedTab()
        case .closeWindow: controller?.closeWindowAndTabs()
        case .closeAllWindows: app?.closeAllWindows()
        case .previousTab: controller?.selectTab(offset: -1)
        case .nextTab: controller?.selectTab(offset: 1)
        case .gotoTab(let n): controller?.selectTab(n)
        case .lastTab: controller?.selectTab(nil)
        case .gotoSplit(.previous): controller?.focusCycling(forward: false)
        case .gotoSplit(.next): controller?.focusCycling(forward: true)
        case .gotoSplit(.direction(let d)): controller?.focus(direction(d))
        case .resizeSplit(let d, let n): controller?.resizeSplit(direction(d), by: n)
        case .equalizeSplits: controller?.equalizeSplits(nil)
        case .toggleSplitZoom: controller?.toggleZoom()
        case .increaseFontSize(let n):
            if let doc = controller?.selectedDocument { doc.zoom(by: n) } else { view?.adjustFontSize(by: n) }
        case .decreaseFontSize(let n):
            if let doc = controller?.selectedDocument { doc.zoom(by: -n) } else { view?.adjustFontSize(by: -n) }
        case .resetFontSize:
            if let doc = controller?.selectedDocument { doc.resetZoom() } else { view?.resetFontSize() }
        case .toggleMarkdownSource: controller?.selectedDocument?.showsSource.toggle()
        case .toggleEditor:
            guard let doc = controller?.selectedDocument else { return false }
            // (Markdown's "source" is the editor too: leaving it saves first.)
            if doc.isEditing { doc.leaveEditor() } else { doc.setEditing(true) }
        case .copyToClipboard: view?.copy(nil)
        case .pasteFromClipboard: view?.paste(nil)
        case .selectAll: view?.selectAll(nil)
        case .clearScreen: view?.clearScreen()
        case .scrollToTop: view?.scroll { $0.scrollToTop() }
        case .scrollToBottom: view?.scroll { $0.scrollToBottom() }
        case .scrollPageUp: view?.scroll { $0.scroll(pages: -1) }
        case .scrollPageDown: view?.scroll { $0.scroll(pages: 1) }
        case .scrollPageLines(let n): view?.scroll { $0.scroll(rows: n) }
        case .jumpToPrompt(let n): view?.scroll { $0.jumpToPrompt(n) }
        case .text(let s): view?.sendInput(s)
        case .csi(let s): view?.sendInput("\u{1b}[" + s)
        case .esc(let s): view?.sendInput("\u{1b}" + s)
        case .promptSurfaceTitle: controller?.promptTitle(tab: false)
        case .promptTabTitle: controller?.promptTitle(tab: true)
        case .toggleReadonly: view?.isReadOnly.toggle()
        case .startSearch: controller?.startSearch()
        case .endSearch: return controller?.endSearch() ?? false
        case .searchSelection: controller?.searchSelection()
        case .navigateSearch(let next): controller?.findNext(older: next)
        case .toggleSidebar: controller?.toggleSidebar()
        case .toggleInspector: controller?.toggleInspector()
        case .toggleFullscreen: (view?.window ?? controller?.window)?.toggleFullScreen(nil)
        case .toggleVisibility: app?.toggleVisibility()
        case .toggleWindowFloatOnTop: controller?.toggleFloatOnTop()
        case .resetWindowSize: controller?.resetWindowSize()
        case .toggleSecureInput: SecureInput.shared.requested.toggle()
        case .toggleCommandPalette: CommandPalette.toggle(in: controller)
        case .gotoPane: CommandPalette.toggle(in: controller, panesOnly: true)
        case .restartSurface: controller?.restartFocusedPane()
        case .parkSurface: controller?.parkFocusedPane()
        case .unparkSurface: controller?.unparkLatest()
        case .floatSurface: controller?.toggleFloatingPane()
        case .moveSurfaceToNewTab: controller?.moveFocusedPaneToNewTab()
        case .moveSurfaceToTab(let n): controller?.moveFocusedPane(toTab: n)
        case .moveSurfaceToNewWindow: controller?.moveFocusedPaneToNewWindow()
        case .moveTabToNewWindow: controller?.moveTabToNewWindow()
        case .openGit: controller?.openGit()
        case .openBrowser: controller?.openBrowser()
        case .openTasks: controller?.openTasks()
        case .newCanvas: controller?.openDocument(CanvasBlock.newFile())
        case .openProfiler: controller?.openDocument(Blocks.url("profiler"))
        case .openBoard: controller?.openBoard()
        case .openPlugins: controller?.openDocument(Blocks.url("plugins"))
        case .openScreen: controller?.openDocument(Blocks.url("screen"))
        case .focusAddress:
            guard let page = controller?.frontBrowser, controller?.selectedDocument === page else { return false }
            page.focusAddress()
        case .newWorkspace: controller?.promptWorkspaceName(creating: true)
        case .renameWorkspace: controller?.promptWorkspaceName(creating: false)
        case .closeWorkspace: controller.map { $0.closeWorkspace(at: $0.activeWorkspace) }
        case .nextWorkspace: controller?.switchWorkspace(offset: 1)
        case .previousWorkspace: controller?.switchWorkspace(offset: -1)
        case .gotoWorkspace(let n): controller?.switchWorkspace(to: n - 1)
        case .toggleQuickTerminal: QuickTerminal.shared.toggle()
        case .connectToHost: MainActor.assumeIsolated { ConnectPanel.shared.show() }
        case .togglePictureInPicture: controller?.togglePictureInPicture()
        case .toggleTabOverview: controller?.toggleTabOverview()
        case .toggleBroadcastInput: controller?.toggleBroadcastInput()
        case .undo:
            let undone = MainActor.assumeIsolated { () -> Bool in
                let manager = CloseUndo.shared.manager
                guard manager.canUndo else { return false }
                manager.undo()
                return true
            }
            if !undone { return false }
        case .redo:
            let redone = MainActor.assumeIsolated { () -> Bool in
                let manager = CloseUndo.shared.manager
                guard manager.canRedo else { return false }
                manager.redo()
                return true
            }
            if !redone { return false }
        case .copyCommandOutput: controller?.copyLastCommandOutput()
        case .writeScrollbackFile(let then): controller?.writeTextFile(selection: false, then: then)
        case .writeSelectionFile(let then): controller?.writeTextFile(selection: true, then: then)
        case .openConfig: AppDelegate.openConfigFile()
        case .reloadConfig: ConfigStore.shared.reload(force: true)
        case .quit: NSApp.terminate(nil)
        case .ignore: break
        case .unbind: return false
        }
        return true
    }

    /// What `libertty +action` may do. Typing into a terminal (text/csi/esc,
    /// paste) and quitting are left out: any local process can post these.
    static func allowedRemotely(_ action: Action) -> Bool {
        switch action {
        case .text, .csi, .esc, .pasteFromClipboard, .quit, .unbind, .toggleSecureInput, .toggleReadonly: false
        case .writeScrollbackFile("paste"), .writeSelectionFile("paste"): false
        default: true
        }
    }
}

/// Wraps an action for `NSMenuItem.representedObject`.
final class ActionBox: NSObject {
    let action: Action
    init(_ action: Action) { self.action = action }
}

/// `libertty +action` and `libertty +new-window` reach the running app as
/// distributed notifications: one-way, no socket to manage. Each carries
/// its liberttyd socket, and only a Libertty using the same one acts on it (a
/// test instance on its own socket never touches the everyday one).
enum RemoteControl {
    static let notification = Notification.Name("dev.libertty.terminal.remote")

    static func post(_ info: [String: String]) {
        var info = info
        info["socket"] = Wire.socketPath
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: nil, userInfo: info, deliverImmediately: true)
    }

    /// Whether a received request is for this instance.
    static func isForUs(_ info: [String: String]) -> Bool {
        (info["socket"] ?? Wire.socketPath) == Wire.socketPath
    }

    /// The running Libertty's answers, to requests that ask for one (`reply`: a token).
    static let replied = Notification.Name("dev.libertty.terminal.remote-reply")

    /// Answer a request that asked (`info["reply"]`); nothing for one that didn't.
    static func answer(_ info: [String: String], _ answer: [String: String]) {
        guard let token = info["reply"], !token.isEmpty else { return }
        var reply = answer
        reply["token"] = token
        DistributedNotificationCenter.default().postNotificationName(
            replied, object: nil, userInfo: reply, deliverImmediately: true)
    }

    /// Post `info` and wait for Libertty's answer: nil when none came in
    /// `timeout` seconds (it's gone, or older than the request). Two copies
    /// of Libertty may both hear it (an installed one and a build): one
    /// without the pane says `no-pane` at once, so that waits a moment for
    /// the other's word.
    static func request(_ info: [String: String], timeout: Double) -> [String: String]? {
        let token = UUID().uuidString
        var answers: [[String: String]] = []
        let observer = DistributedNotificationCenter.default().addObserver(forName: replied, object: nil, queue: .main) { note in
            guard let reply = note.userInfo as? [String: String], reply["token"] == token else { return }
            answers.append(reply)
        }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }
        var request = info
        request["reply"] = token
        post(request)
        var deadline = Date().addingTimeInterval(timeout)
        var provisional = false
        while Date() < deadline {
            if let decisive = answers.first(where: { $0["result"] != "no-pane" }) { return decisive }
            if !answers.isEmpty, !provisional {
                provisional = true
                deadline = min(deadline, Date().addingTimeInterval(0.5))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return answers.first(where: { $0["result"] != "no-pane" }) ?? answers.first
    }
}
