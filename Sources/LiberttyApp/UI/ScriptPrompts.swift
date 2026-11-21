import AppKit

/// The app's side of `libertty +pick` and `+input` (ScriptPrompt): which
/// window asks — the one showing the pane the command runs in, else the one
/// in front — and how long the question stays: until it's answered or
/// cancelled, its time runs out, or what it was for goes away (the command,
/// ^C'd or killed; its pane; the window). One at a time per window.
/// Shared by the app and `--ui-probe` (PaneRequests).
final class ScriptPromptSession {
    /// The questions up now, a window each at most.
    private(set) static var open: [ScriptPromptSession] = []

    let prompt: ScriptPrompt
    /// The request, to answer it.
    private let request: [String: String]
    private weak var controller: TerminalWindowController?
    /// The pane the command runs in, when it runs in one.
    private weak var pane: TerminalView?
    private var palette: CommandPalette?
    private var processWatch: DispatchSourceProcess?
    private var check: Timer?
    private var windowObservers: [NSObjectProtocol] = []
    private let deadline: Date?
    private let pid: pid_t
    private var ended = false

    /// `kind: prompt`: asked over a window of `controllers`, or answered at
    /// once why not (`busy`, `error`).
    static func handle(_ info: [String: String], in controllers: [TerminalWindowController]) {
        guard let prompt = ScriptPrompt(fields: info) else {
            return RemoteControl.answer(info, ["result": "error", "message": "this Libertty doesn't know that kind of prompt"])
        }
        let id = info["session"] ?? ""
        // Two copies of Libertty may both hear it (an installed one and a
        // build, on one liberttyd): the one showing the command's pane asks.
        // Another says `no-pane` and stays out of it; only if no copy has
        // the pane does the command ask again with `fallback`, for the
        // window in front. (Outside a pane: the copy in front asks first.)
        let fallback = info["fallback"] == "1"
        var found: (controller: TerminalWindowController, pane: TerminalView)?
        if !id.isEmpty {
            for controller in controllers {
                if let pane = controller.pane(showing: id) { found = (controller, pane); break }
            }
        }
        // The Quick Terminal put away isn't one to ask in (it would come
        // down over whatever you're doing): the window in front, then.
        // (A window kept for Undo Close isn't among `controllers`.)
        if let shown = found, let window = shown.controller.window, !window.isVisible, !window.isMiniaturized, !NSApp.isHidden {
            found = nil
        }
        if found == nil, !fallback, !id.isEmpty || !NSApp.isActive {
            return RemoteControl.answer(info, ["result": "no-pane"])
        }
        guard let controller = found?.controller ?? front(of: controllers) else {
            return RemoteControl.answer(info, ["result": "no-pane"])
        }
        guard !open.contains(where: { $0.controller === controller }) else {
            return RemoteControl.answer(info, ["result": "busy"])
        }
        let session = ScriptPromptSession(prompt: prompt, request: info, controller: controller, pane: found?.pane)
        guard session.start() else {
            return RemoteControl.answer(info, ["result": "error", "message": "the window couldn't show it"])
        }
        open.append(session)
        // (Who's showing it: the command stops waiting should it quit.)
        RemoteControl.answer(info, ["result": "shown", "pid": String(getpid())])
    }

    /// The window in front (of `controllers`), else any shown one — or,
    /// with Libertty hidden (⌘H), any of its windows: they come back with it.
    private static func front(of controllers: [TerminalWindowController]) -> TerminalWindowController? {
        let shown = controllers.filter { !$0.isQuick && ($0.window?.isVisible == true || NSApp.isHidden && $0.window != nil) }
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? TerminalWindowController }
        return ordered.first { c in shown.contains { $0 === c } } ?? shown.first
    }

    private init(prompt: ScriptPrompt, request: [String: String], controller: TerminalWindowController, pane: TerminalView?) {
        self.prompt = prompt
        self.request = request
        self.controller = controller
        self.pane = pane
        pid = pid_t(request["pid"] ?? "") ?? 0
        deadline = prompt.timeout.map { Date().addingTimeInterval($0) }
    }

    /// Asked, and watched for what ends it besides an answer: the command
    /// gone, the time up, the window or pane gone. False: it couldn't be.
    private func start() -> Bool {
        guard let controller else { return false }
        let asker = pane.map { controller.askerLabel(of: $0) } ?? ""
        palette = CommandPalette.ask(prompt, from: asker, in: controller, quietly: pane.map(controller.isMuted) ?? false) { [weak self] answer in
            guard let self else { return }
            self.end(self.reply(to: answer), withdraw: false)
        }
        guard palette != nil else { return false }
        if let deadline { palette?.showTimeLeft(deadline.timeIntervalSinceNow) }
        if pid > 0 {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in self?.end(nil) }
            source.resume()
            processWatch = source
        }
        if let window = controller.window {
            windowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                          queue: .main) { [weak self] _ in
                self?.end(["result": "closed", "message": "its window closed with the question unanswered"])
            })
            // Back to its window (Libertty wasn't in front when it asked): the question has the keyboard.
            windowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                                          queue: .main) { [weak self] _ in
                self?.palette?.takeKeyboard()
            })
        }
        // (Also while a menu or a sheet is up.)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.recheck() }
        RunLoop.main.add(timer, forMode: .common)
        check = timer
        return true
    }

    private func recheck() {
        // The command gone without a word (the source missed it: it was gone already).
        if pid > 0, kill(pid, 0) != 0, errno == ESRCH { return end(nil) }
        if let deadline {
            if Date() >= deadline { return end(["result": "timeout"]) }
            palette?.showTimeLeft(deadline.timeIntervalSinceNow)
        }
        guard let controller, let window = controller.window else {
            return end(["result": "closed", "message": "its window closed with the question unanswered"])
        }
        // Hidden for Undo Close (not minimized, nor Libertty hidden; the
        // Quick Terminal comes and goes as it does: there again, it asks again).
        if !controller.isQuick, !window.isVisible, !window.isMiniaturized, !NSApp.isHidden {
            return end(["result": "closed", "message": "its window closed with the question unanswered"])
        }
        if let asking = pane {
            let windows = (NSApp.delegate as? AppDelegate)?.allControllers ?? [controller]
            if asking.session.hasExited || !windows.contains(where: { $0.allPanes.contains { $0 === asking } }) {
                return end(["result": "closed", "message": "its pane closed with the question unanswered"])
            }
        }
    }

    /// The answer as the command is told it. What's typed into a `--secure`
    /// field never goes out in the reply, which any process of yours can
    /// hear: it's written to the command's own file (`answerFile`, in a
    /// directory only you can enter), and the reply only says it's there.
    private func reply(to answer: ScriptPrompt.Answer) -> [String: String] {
        guard prompt.secure, case .text(let text) = answer else { return ScriptPrompt.reply(answer) }
        guard let path = request["answerFile"], ScriptPrompt.writeAnswer(text, to: path) else {
            return ["result": "error", "message": "the answer couldn't be handed over privately, so it wasn't sent"]
        }
        return ["result": "answered", "file": "1"]
    }

    /// Over: the command told `reply` (nil: there's nobody to tell), the
    /// page taken down unless it went by itself.
    private func end(_ reply: [String: String]?, withdraw: Bool = true) {
        guard !ended else { return }
        ended = true
        processWatch?.cancel()
        processWatch = nil
        check?.invalidate()
        check = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if withdraw { palette?.withdraw() }
        palette = nil
        Self.open.removeAll { $0 === self }
        if let reply { RemoteControl.answer(request, reply) }
    }
}

extension TerminalWindowController {
    /// Who's asking, as a prompt says it: the pane's tab and folder.
    func askerLabel(of pane: TerminalView) -> String {
        var parts: [String] = []
        if let tab = owningTab(of: pane), let i = tabs.firstIndex(where: { $0 === tab }) { parts.append(L10n.t("Tab") + " \(i + 1)") }
        if let path = pane.session.workingDirectory {
            parts.append(path == NSHomeDirectory() ? "~" : (path as NSString).lastPathComponent)
        }
        return parts.joined(separator: " · ")
    }
}
