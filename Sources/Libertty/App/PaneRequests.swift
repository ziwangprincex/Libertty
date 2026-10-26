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
        case "swap-pane", "resize-pane":
            arrange(info, in: controllers)
            return true
        case "list-panes":
            list(info, in: controllers)
            return true
        default:
            return false
        }
    }

    /// Every terminal pane of every window, one line each: where it is, its
    /// session, and how it's drawn — text size and font, cell, scale, grid.
    private static func list(_ info: [String: String], in controllers: [TerminalWindowController]) {
        var lines: [String] = []
        for (w, controller) in controllers.enumerated() {
            let groups = controller.workspaceTabs
            for (s, group) in groups.enumerated() {
                let workspace = groups.count > 1 ? "workspace \(s + 1) " : ""
                for (t, tab) in group.enumerated() {
                    for (p, pane) in tab.everyPane.enumerated() {
                        let id = pane.session.persistentID ?? "-"
                        let focused = tab === controller.selectedTab && pane === controller.focusedTerminal ? " *" : ""
                        lines.append("window \(w + 1) \(workspace)tab \(t + 1) pane \(p + 1)  \(id)  \(pane.metricsSummary)\(focused)")
                    }
                }
            }
        }
        RemoteControl.answer(info, ["result": "ok", "text": lines.joined(separator: "\n")])
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
        if let to = info["to"], to.hasPrefix("beside:") { return arrange(info, in: controllers) }
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

    /// Within a split: `swap-pane {id, with}`, `resize-pane {id, direction,
    /// points}` (direction `equalize` evens it out), `move-pane {id, to:
    /// beside:OTHER, side}`. Answers swapped, resized or moved; `no-pane`
    /// (with which: `missing`); `refused` with why.
    private static func arrange(_ info: [String: String], in controllers: [TerminalWindowController]) {
        guard let id = info["id"], let (controller, pane) = find(id, in: controllers) else {
            return RemoteControl.answer(info, ["result": "no-pane", "missing": info["id"] ?? ""])
        }
        let other: TerminalView?
        if info["kind"] == "swap-pane" || info["to"]?.hasPrefix("beside:") == true {
            let otherID = info["with"] ?? String((info["to"] ?? "").dropFirst("beside:".count))
            guard let found = controller.pane(showing: otherID) else {
                return RemoteControl.answer(info, ["result": "no-pane", "missing": otherID])
            }
            other = found
        } else {
            other = nil
        }
        let result: String
        switch info["kind"] {
        case "swap-pane":
            result = controller.arrange(pane, .swap(other!)) ?? "swapped"
        case "resize-pane":
            let direction = info["direction"] ?? ""
            if direction == "equalize" {
                result = controller.arrange(pane, .equalize) ?? "resized"
            } else if let d = SplitContainerView.Direction(cliName: direction) {
                result = controller.arrange(pane, .resize(d, CGFloat(Int(info["points"] ?? "") ?? 0))) ?? "resized"
            } else {
                result = "where to: right, left, down or up"
            }
        default:
            let side = SplitContainerView.Direction(cliName: info["side"] ?? "right") ?? .right
            result = controller.arrange(pane, .beside(other!, side)) ?? "moved"
        }
        if ["swapped", "resized", "moved"].contains(result) {
            RemoteControl.answer(info, ["result": result])
        } else {
            RemoteControl.answer(info, ["result": "refused", "message": result])
        }
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
