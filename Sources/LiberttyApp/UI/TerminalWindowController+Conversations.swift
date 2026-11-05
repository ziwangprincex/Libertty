import AppKit
import LiberttyCore

/// Agents' conversations picked up again (Kero's Resume Conversation…).
extension TerminalWindowController {
    /// A pane resuming a conversation: the conversation runs in its session
    /// now (so the agent leaving this pane ends it), and the pane goes by the
    /// name its session had: its session's (liberttyd keeps it), else,
    /// outside liberttyd, its tab's.
    func nameAfterConversation(_ pane: TerminalView) {
        guard let conversation = pane.resumedConversation else { return }
        if let id = pane.session.persistentID, id != conversation.session {
            DispatchQueue.global(qos: .utility).async {
                Conversations.record(agent: conversation.agent, id: conversation.id, session: id, directory: conversation.directory)
            }
        }
        guard !conversation.name.isEmpty else { return }
        guard let id = pane.session.persistentID else {
            if let tab = owningTab(of: pane), tab.titleOverride.isEmpty {
                tab.titleOverride = conversation.name
                updateTitle()
            }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            _ = DaemonClient.request(.rename, json: ["id": id, "label": conversation.name], needing: "label")
        }
    }

    /// The pane where a conversation runs now, in this window.
    func pane(running conversation: Conversation) -> TerminalView? {
        guard !conversation.ended else { return nil }
        return allPanes.first { $0.session.persistentID == conversation.session && !$0.session.hasExited }
    }

    /// Resume Conversation: the pane running it, else a new tab in its folder
    /// whose shell resumes it, as the agent's own resume option would.
    /// Returns the pane, nil when it can't be resumed.
    @discardableResult
    func resume(_ conversation: Conversation) -> TerminalView? {
        if let pane = pane(running: conversation), let tab = owningTab(of: pane) {
            reveal(pane, in: tab)
            return pane
        }
        guard host == nil, let command = Conversations.resumeCommand(conversation) else { NSSound.beep(); return nil }
        var isDirectory: ObjCBool = false
        let directory = FileManager.default.fileExists(atPath: conversation.directory, isDirectory: &isDirectory)
            && isDirectory.boolValue ? conversation.directory : NSHomeDirectory()
        guard let tab = newTab(workingDirectory: directory), let pane = tab.focusedPane else { return nil }
        pane.resumedConversation = conversation
        pane.session.typeAtFirstPrompt(command)
        nameAfterConversation(pane)
        window?.makeKeyAndOrderFront(nil)
        return pane
    }
}
