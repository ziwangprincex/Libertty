import AppKit

/// Focus history (`FocusHistory`): what it keeps of this window, and its
/// jumps — Back, Forward, Recent — to a pane or a tab of any window.
extension TerminalWindowController {
    /// What focus history keeps of the tab in front: a document tab's
    /// document, or the split's focused pane or document pane (a floating
    /// pane is none of the split's).
    var historyLeaf: NSView? { selectedTab.document ?? focusedLeaf }

    /// Focus moved in this window: where it is once the event that moved
    /// it is over becomes the newest in focus history — while this window
    /// has the keyboard (a probe's never does), not in the Quick Terminal.
    /// (Once it's over: bringing a tab forward focuses its own pane, then
    /// perhaps another; a click into another window makes it key, its
    /// focused pane with it, then focuses the pane clicked. Only where
    /// focus lands counts.)
    func noteFocusHistory() {
        guard !isQuick else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isKeyWindow == true || Probe.running, self.focusedFloatingPane == nil,
                  let leaf = self.historyLeaf else { return }
            FocusHistory.shared.note(leaf)
        }
    }

    /// The windows focus history goes to: the app's (not one hidden for
    /// Undo Close, not the Quick Terminal) — in a probe, its own.
    private static func historyWindows(around current: TerminalWindowController?) -> [TerminalWindowController] {
        var all = (NSApp.delegate as? AppDelegate)?.windowControllers ?? []
        if let current, !all.contains(where: { $0 === current }) { all.append(current) }
        return all.filter { !$0.isQuick && ($0.window?.isVisible == true || $0.window?.isMiniaturized == true) }
    }

    /// Where `leaf` is among `windows`: its window, its tab, and whether it
    /// can be shown there (in its tab's split, or the document a tab is; not parked).
    private static func place(of leaf: AnyObject, in windows: [TerminalWindowController])
        -> (controller: TerminalWindowController, tab: TerminalTab, shown: Bool)? {
        for controller in windows {
            for tab in controller.everyTab {
                if tab.document === leaf || tab.container?.views.contains(where: { $0 === leaf }) == true {
                    return (controller, tab, true)
                }
                if tab.parked.contains(where: { $0.pane === leaf }) { return (controller, tab, false) }
            }
        }
        return nil
    }

    /// Back, Forward or Recent from `controller`'s window (the Quick
    /// Terminal's too: back to the last pane of a window): the pane, or the
    /// tab, focus was in before (or, forward, after). Its window comes
    /// forward, its tab is selected, its pane revealed as Go to Pane does.
    /// Nowhere to go: a beep, and nothing changes.
    static func jumpInFocusHistory(_ level: FocusHistory.Level, _ move: FocusHistory.Move, from controller: TerminalWindowController?) {
        let windows = historyWindows(around: controller)
        // (A floating pane with the keyboard isn't kept: back from it is to the split.)
        let current: NSView? = controller.flatMap { $0.isQuick || $0.focusedFloatingPane != nil ? nil : $0.historyLeaf }
        let here: AnyObject?
        switch level {
        case .pane: here = current
        case .tab: here = controller.flatMap { $0.isQuick ? nil : $0.selectedTab }
        }
        let went = FocusHistory.shared.jump(level, move, current: current, here: here, stop: { leaf in
            guard let found = place(of: leaf, in: windows) else { return nil }
            switch level {
            case .pane: return found.shown ? leaf : nil
            case .tab: return found.tab
            }
        }, go: { stop in
            // A pane or document, or a tab (as it was: its own focused pane).
            let target: (controller: TerminalWindowController, tab: TerminalTab, leaf: NSView?)?
            if let tab = stop as? TerminalTab {
                target = windows.first { $0.everyTab.contains { $0 === tab } }.map { ($0, tab, nil) }
            } else {
                target = place(of: stop, in: windows).map { ($0.controller, $0.tab, $0.tab.document === stop ? nil : stop as? NSView) }
            }
            guard let target else { return nil }
            if target.controller.window?.isMiniaturized == true { target.controller.window?.deminiaturize(nil) }
            guard target.controller.reveal(target.leaf, in: target.tab) else { return nil }
            Probe.activateApp()
            return target.controller.historyLeaf
        })
        if !went { NSSound.beep() }
    }
}
