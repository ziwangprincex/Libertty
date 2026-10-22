import AppKit

/// What `libertty +split` and `+move-pane` ask of the running Libertty, by
/// the session ID of the pane to act on: whichever window shows it does it.
/// Shared by the app and `--ui-probe` (which has no app delegate).
enum PaneRequests {
    /// Handled (it was one of these); false leaves `info` to the caller.
    static func handle(_ info: [String: String], in controllers: [TerminalWindowController]) -> Bool {
        switch info["kind"] {
        case "split":
            split(info, in: controllers)
            return true
        case "move-pane":
            move(info, in: controllers)
            return true
        default:
            return false
        }
    }

    /// `{beside, direction?, share?, cwd?, command?, focus?, keepOpen?}`: a new pane
    /// beside the one showing session `beside`. Answers `made` with the new
    /// pane's session ID ("" for one outside liberttyd), `no-pane`, `refused`
    /// (it's parked) or `error`, with why.
    private static func split(_ info: [String: String], in controllers: [TerminalWindowController]) {
        guard let beside = info["beside"], let (controller, pane) = find(beside, in: controllers) else {
            return RemoteControl.answer(info, ["result": "no-pane"])
        }
        if controller.isOutOfSplit(pane) {
            return RemoteControl.answer(info, ["result": "refused", "message": "it's parked (unpark it first)"])
        }
        let direction = SplitContainerView.Direction(cliName: info["direction"] ?? "right") ?? .right
        let share = info["share"].flatMap(Double.init).map { CGFloat(min(0.9, max(0.1, $0))) } ?? 0.5
        let focus = info["focus"] != "0"
        let made: TerminalView?
        do {
            made = try controller.makeSplit(beside: pane, toward: direction, share: share,
                                            command: info["command"].flatMap { $0.isEmpty ? nil : $0 },
                                            workingDirectory: info["cwd"].flatMap { $0.isEmpty ? nil : $0 }, focus: focus,
                                            keepOpen: info["keepOpen"] == "1")
        } catch {
            return RemoteControl.answer(info, ["result": "error", "message": error.localizedDescription])
        }
        guard let new = made else { return RemoteControl.answer(info, ["result": "no-pane"]) }
        if focus {
            // The Quick Terminal comes down its own way (off screen, it would take keys unseen).
            if controller.isQuick { QuickTerminal.shared.show() } else { controller.window?.makeKeyAndOrderFront(nil) }
            Probe.activateApp()
        }
        RemoteControl.answer(info, ["result": "made", "session": new.session.persistentID ?? ""])
    }

    /// `{id, to: new-tab | new-window | tab:N}`: the pane showing `id` moves.
    /// Answers `moved`, `no-pane`, or `refused` with why — then nothing moves
    /// and nothing comes forward.
    private static func move(_ info: [String: String], in controllers: [TerminalWindowController]) {
        let target: TerminalWindowController.MoveTarget, action: Action
        switch info["to"] ?? "" {
        case "new-tab": (target, action) = (.newTab, .moveSurfaceToNewTab)
        case "new-window": (target, action) = (.newWindow, .moveSurfaceToNewWindow)
        case let to where to.hasPrefix("tab:") && (Int(to.dropFirst(4)) ?? 0) > 0:
            let n = Int(to.dropFirst(4))!
            (target, action) = (.tab(n), .moveSurfaceToTab(n))
        default:
            return RemoteControl.answer(info, ["result": "refused", "message": "where to: new-tab, new-window or tab:N"])
        }
        guard let id = info["id"], let (controller, pane) = find(id, in: controllers) else {
            return RemoteControl.answer(info, ["result": "no-pane"])
        }
        if let why = controller.whyNotMove(pane, to: target) {
            return RemoteControl.answer(info, ["result": "refused", "message": why])
        }
        // Brought forward and focused first: the moves act on the focused pane.
        // Asked again then: bringing it forward may have changed its split.
        guard controller.reveal(paneID: id), controller.focusedTerminal === pane, controller.canMoveFocusedPane(to: target) else {
            return RemoteControl.answer(info, ["result": "refused", "message": "its split changed meanwhile"])
        }
        ActionDispatcher.perform(action, in: pane, controller: controller)
        Probe.activateApp()
        RemoteControl.answer(info, ["result": "moved"])
    }

    /// The window showing session `id`, and its pane there.
    private static func find(_ id: String, in controllers: [TerminalWindowController]) -> (TerminalWindowController, TerminalView)? {
        for controller in controllers { if let pane = controller.pane(showing: id) { return (controller, pane) } }
        return nil
    }
}

extension SplitContainerView.Direction {
    /// `right`, `left`, `down` or `up` (`libertty +split --down`).
    init?(cliName: String) {
        switch cliName {
        case "right": self = .right
        case "left": self = .left
        case "down": self = .down
        case "up": self = .up
        default: return nil
        }
    }
}
