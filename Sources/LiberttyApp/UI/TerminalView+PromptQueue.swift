import AppKit

/// A pane with prompts queued says so at its bottom left ("2 queued", and
/// "paused" when the queue waits for you); a click opens the queue in its
/// composer. Its tab's row in the sidebar says so too (`queueSummary`).
extension TerminalView {
    private static var queueTagKey: UInt8 = 0

    /// Show the pane's queue as it is now.
    func updateQueueTag() {
        let queue = PromptQueues.shared.queue(of: session)
        var tag = objc_getAssociatedObject(self, &Self.queueTagKey) as? NSButton
        guard !queue.isEmpty else {
            tag?.removeFromSuperview()
            objc_setAssociatedObject(self, &Self.queueTagKey, nil, .OBJC_ASSOCIATION_RETAIN)
            return
        }
        if tag == nil {
            let button = NSButton(title: "", target: self, action: #selector(openQueue(_:)))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            effectiveAppearance.performAsCurrentDrawingAppearance {
                button.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
            }
            button.toolTip = L10n.t("Prompts queued for this pane: each goes when the pane is ready. Click to see them.")
            addSubview(button)
            button.layer?.zPosition = 2
            objc_setAssociatedObject(self, &Self.queueTagKey, button, .OBJC_ASSOCIATION_RETAIN)
            tag = button
        }
        guard let tag else { return }
        let text = Self.queueSummary(queue)
        tag.attributedTitle = NSAttributedString(string: "  " + text + "  ", attributes: [
            .font: Typeface.ui(11, .medium),
            .foregroundColor: queue.paused ? NSColor.systemOrange : NSColor.secondaryLabelColor,
        ])
        tag.setAccessibilityLabel(text)
        let size = tag.fittingSize
        tag.frame = NSRect(x: 12, y: bounds.height - size.height - 6, width: min(size.width, bounds.width - 24), height: size.height)
        tag.autoresizingMask = [.maxXMargin, .minYMargin]
    }

    /// "2 queued", "1 queued · paused".
    static func queueSummary(_ queue: PromptQueue) -> String {
        let n = L10n.t("%d queued").replacingOccurrences(of: "%d", with: String(queue.items.count))
        return queue.paused ? n + " · " + L10n.t("paused") : n
    }

    @objc private func openQueue(_ sender: Any?) {
        ComposerController.show(in: self, queue: true)
    }

    /// What the queue tag says (the UI probe): nil when there's none.
    var queueTagShown: String? { (objc_getAssociatedObject(self, &Self.queueTagKey) as? NSButton)?.accessibilityLabel() }
}

extension PromptQueues {
    /// The windows that may show a session: every terminal window, the
    /// quick terminal's included.
    static var controllers: [TerminalWindowController] {
        var all = NSApp.windows.compactMap { $0.windowController as? TerminalWindowController }
        if let quick = QuickTerminal.shared.windowController, !all.contains(where: { $0 === quick }) { all.append(quick) }
        return all
    }

    /// The pane showing a session, and its window.
    static func pane(of session: TerminalSession) -> (TerminalWindowController, TerminalView)? {
        for c in controllers { if let p = c.pane(for: session) { return (c, p) } }
        return nil
    }

    /// Ties the queues to the windows: who's an agent (the windows know what
    /// runs in front of each pane), and what a change shows — the pane's tag
    /// and its tab's row. Once, as the app or a probe starts.
    func connectToWindows() {
        takesInput = { session in Self.pane(of: session).map { !$0.1.isReadOnly } ?? false }
        agentInFront = { session in
            guard let (controller, _) = Self.pane(of: session) else { return false }
            if controller.programs[ObjectIdentifier(session)]?.agent != nil { return true }
            // An agent's report says so too (a host's pane, before its tile).
            return session.programStatus.records.values.contains {
                ProgramBadge.agentKey(session.programStatus.effectiveApp(of: $0)) != nil
            }
        }
        NotificationCenter.default.addObserver(forName: Self.changed, object: nil, queue: .main) { note in
            guard let session = note.object as? TerminalSession, let (controller, pane) = Self.pane(of: session) else { return }
            pane.updateQueueTag()
            controller.updateSidebar()
        }
    }
}
