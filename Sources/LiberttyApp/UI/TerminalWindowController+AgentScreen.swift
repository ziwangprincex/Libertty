import AppKit
import LiberttyCore

/// What a pane's agent showed when its screen was last looked at.
final class AgentScreenWatch {
    var agent: String?
    var seen: AgentScreen.State?
    /// When the screen stopped showing work without showing it's done.
    var idleFrom: CFTimeInterval?
    var scheduled = false
    /// What the screen had printed, and its title, at the last look.
    var output: UInt64 = 0
    var title = ""
    /// The once-a-second look for a pane that doesn't draw (a tab in the
    /// background asks for no frames, so its output pokes nothing).
    var heartbeat = false
    /// A turn that ended, waiting to be told as done (`doneDelay`).
    var ending: DispatchWorkItem?
}

/// Coding agents' states from their screens (`agent-screen-status`, Kero's):
/// for an agent in front of a pane with rules for it (AgentScreen), what its
/// screen shows — a spinner, a permission dialog, its prompt at rest — is
/// the pane's program status, under a record of its own. Only a change of
/// what shows changes it, so a redraw (a resize) changes nothing. What the
/// agent or its hooks report stands over it.
extension TerminalWindowController {
    /// The record the screen's state goes in.
    static let agentScreenID = "screen"
    /// A screen that stops showing work without showing it's at rest waits
    /// this long before it counts as idle (Kero's idleHold): between a
    /// tool's output and the next spinner frame, it shows neither.
    static let agentIdleHold: CFTimeInterval = 0.7
    /// A turn's end is told this much later, so an agent that says so
    /// itself (Codex's notify) is the one that does, with its message.
    static let agentDoneDelay: CFTimeInterval = 1.5

    /// Something on a pane's screen may have changed: look at it soon,
    /// once however much more comes meanwhile.
    func pokeAgentScreen(_ pane: TerminalView) {
        let key = ObjectIdentifier(pane.session)
        guard programs[key]?.agent != nil || agentWatches[key] != nil else { return }
        let watch = agentWatches[key] ?? AgentScreenWatch()
        agentWatches[key] = watch
        guard !watch.scheduled else { return }
        watch.scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak pane] in
            watch.scheduled = false
            guard let self, let pane else { return }
            self.lookAtAgentScreen(pane, watch)
        }
    }

    private func startHeartbeat(_ pane: TerminalView, _ watch: AgentScreenWatch) {
        guard !watch.heartbeat else { return }
        watch.heartbeat = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak pane] in
            watch.heartbeat = false
            guard let self, let pane, self.agentWatches[ObjectIdentifier(pane.session)] === watch else { return }
            if pane.session.outputMark.count != watch.output || pane.session.title != watch.title {
                self.pokeAgentScreen(pane)
            } else {
                self.startHeartbeat(pane, watch)
            }
        }
    }

    private func lookAtAgentScreen(_ pane: TerminalView, _ watch: AgentScreenWatch) {
        let session = pane.session, key = ObjectIdentifier(session), store = session.programStatus
        let id = Self.agentScreenID
        let agent = config.agentScreenStatus && !session.hasExited ? programs[key]?.agent : nil
        if agent != watch.agent {
            watch.agent = agent
            watch.seen = nil
            watch.idleFrom = nil
            watch.ending?.cancel()
            watch.ending = nil
        }
        let ours = store.records[id]
        func clearOurs() {
            guard ours != nil else { return }
            store.clear(id: id)
            sessionProgramStatusChanged(session)
            tellDaemon(session, "clear", app: ours?.app ?? "")
        }
        guard let agent, let manifest = AgentScreen.manifest(for: agent) else {
            // The agent left (or the setting is off): what its screen said
            // goes, but a turn's end you haven't seen.
            if ours?.state != .done { clearOurs() }
            agentWatches[key] = nil
            return
        }
        // What the program or its hooks report stands (Claude Code with
        // +agent-setup, an OSC 7501 report); Codex's notify only ends turns.
        if store.records.values.contains(where: { $0.id != id && $0.app != "codex" }) {
            watch.seen = nil
            clearOurs()
            return
        }
        watch.output = session.outputMark.count
        watch.title = session.title
        startHeartbeat(pane, watch)
        let result = AgentScreen.detect(manifest, .init(screen: session.screenRows(), title: session.title,
                                                        progress: session.progressCode))
        guard !result.skip, result.state != .unknown else { return }
        let state = result.state
        if state == watch.seen {
            watch.idleFrom = nil
            return
        }
        if state == .idle, !result.visible, ours?.state == .working {
            let now = CACurrentMediaTime(), from = watch.idleFrom ?? now
            watch.idleFrom = from
            if now - from < Self.agentIdleHold {
                // Look again once the hold is over, whether or not more comes.
                DispatchQueue.main.asyncAfter(deadline: .now() + from + Self.agentIdleHold - now + 0.02) { [weak self, weak pane] in
                    guard let self, let pane, watch.idleFrom == from else { return }
                    self.lookAtAgentScreen(pane, watch)
                }
                return
            }
        }
        watch.idleFrom = nil
        watch.seen = state
        watch.ending?.cancel()
        watch.ending = nil
        func report(_ state: ProgramStatusStore.State) {
            store.apply(.init(clear: false, state: state, kind: .none, progress: nil, id: id, app: agent, title: "", message: ""))
            sessionProgramStatusChanged(session)
            tellDaemon(session, state.name, app: agent)
        }
        switch state {
        case .working: report(.working)
        case .blocked: report(.blocked)
        default:
            let wasWorking = ours?.state == .working
            if ours?.state != .done { clearOurs() }
            guard wasWorking else { return }
            // A turn ended: done, unless you were looking or the agent said so itself.
            let ending = DispatchWorkItem { [weak self, weak pane] in
                guard let self, let pane, watch.seen == .idle, watch.agent == agent, !self.isLookedAt(pane) else { return }
                if store.records.values.contains(where: { $0.id != id && ($0.state == .done || $0.state == .error) }) { return }
                report(.done)
            }
            watch.ending = ending
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.agentDoneDelay, execute: ending)
        }
    }

    /// One at a time, so liberttyd hears them in the order they were read.
    private static let screenReports = DispatchQueue(label: "libertty.screen-reports", qos: .utility)

    /// What the screen says goes to liberttyd too, as a `status` event like
    /// an OSC 7501 report's: `libertty +events --for waiting` (scripts, other
    /// agents) sees the agents that report nothing themselves. This Mac's
    /// panes only; an older liberttyd, which doesn't take it, isn't asked.
    private func tellDaemon(_ session: TerminalSession, _ state: String, app: String) {
        guard session.host == nil, let id = session.persistentID else { return }
        Self.screenReports.async {
            _ = DaemonClient.request(.report, json: ["id": id, "state": state, "record": Self.agentScreenID, "app": app],
                                     needing: "report")
        }
    }
}
