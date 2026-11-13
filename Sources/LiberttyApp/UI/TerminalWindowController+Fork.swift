import AppKit
import LiberttyCore

/// Fork Conversation: a coding agent's conversation in a pane carried on in
/// a new pane beside it (or a tab, or a window) as a conversation of its
/// own — the agent's own fork (Claude Code's --fork-session, `codex fork`)
/// from the same transcript, in the same folder, the original left as it was.
extension TerminalWindowController {
    typealias ForkPlace = Action.ForkPlace

    /// The conversation the agent in `pane` runs, as its hooks or notify
    /// recorded it (`+agent-setup`).
    func conversation(in pane: TerminalView) -> Conversation? {
        guard let id = pane.session.persistentID else { return nil }
        return Conversations.running(in: id, among: Conversations.load())
    }

    /// Why the agent's conversation in `pane` can't be forked; nil when it can.
    func whyNotFork(_ pane: TerminalView) -> String? {
        if pane.session.host != nil || host != nil {
            return L10n.t("Its conversation is kept on the host, not on this Mac.")
        }
        guard let conversation = conversation(in: pane) else {
            return programs[ObjectIdentifier(pane.session)]?.agent == nil
                ? L10n.t("No coding agent runs in this pane.")
                : L10n.t("Libertty doesn't know this conversation: set the agent up with libertty +agent-setup, then send it a prompt.")
        }
        guard Conversations.forkCommand(conversation) != nil else {
            return L10n.t("%@ can't fork a conversation from its command line.").replacingOccurrences(of: "%@", with: conversation.agentName)
        }
        return nil
    }

    /// Fork the focused pane's conversation (or `pane`'s) into a new pane
    /// beside it, a tab or a window. Returns the new pane; nil (having said
    /// why) when it can't.
    @discardableResult
    func forkConversation(of given: TerminalView? = nil, into place: ForkPlace = .split) -> TerminalView? {
        let pane = given ?? focusedTerminal
        if let why = whyNotFork(pane) {
            explainFork(why)
            return nil
        }
        guard let conversation = conversation(in: pane), let command = Conversations.forkCommand(conversation) else { return nil }
        // Where it runs: the pane's folder (a worktree's, if it's in one), else the conversation's.
        var isDirectory: ObjCBool = false
        let candidates = [pane.session.workingDirectory, conversation.directory].compactMap { $0 }
        let directory = candidates.first { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue }
            ?? NSHomeDirectory()
        let made: TerminalView?
        switch place {
        case .split:
            made = try? makeSplit(beside: pane, toward: .right, workingDirectory: directory)
        case .tab, .window:
            made = newTab(workingDirectory: directory)?.focusedPane
            if place == .window, made != nil { moveTabToNewWindow() }
        }
        guard let new = made else {
            explainFork(L10n.t("There's no room for a new pane here."))
            return nil
        }
        new.session.typeAtFirstPrompt(command)
        return new
    }

    private func explainFork(_ why: String) {
        guard let window else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = L10n.t("Can't fork the conversation")
        alert.informativeText = why
        alert.beginSheetModal(for: window)
    }
}
