#if os(Linux)
import Dispatch
import FoundationEssentials  // not Foundation: on Linux that brings 45 MB of ICU
#else
import Foundation
#endif

/// liberttyd's own look at a coding agent's screen (AgentScreen, Kero's
/// kerod does the same): what the agent in front of a session is doing,
/// told as `status` events (`+events --for waiting`), whether or not a
/// window shows it — the app closed, a session detached, a remote host's.
/// And the program in front, for the windows: on a remote host they can't
/// read the process table, so this is how a tab there shows its agent.
///
/// The app's watch (TerminalWindowController+AgentScreen) decides what its
/// own tabs show from its copy of the screen; this one only reports. The
/// rules are the same, so they agree. What the agent says itself (its
/// hooks, an OSC 7501 report) stands over what the screen shows: then this
/// says nothing.
///
/// Everything here runs on the watch's own queue, so a look at a big screen
/// doesn't hold up the session's output.
/// The program in front of a session, as liberttyd sees it: its name, its
/// arguments when they matter (a runtime's script, ssh's host), and the
/// coding agent it is. In `foreground` frames and attach headers.
public struct SessionProgram: Equatable, Sendable {
    public var name: String
    public var arguments: String
    public var agent: String?

    public init(name: String, arguments: String, agent: String? = nil) {
        self.name = name
        self.arguments = arguments
        self.agent = agent
    }

    var json: [String: Any] { ["name": name, "arguments": arguments, "agent": agent ?? ""] }

    /// From a frame or a header; nil for the shell itself (no name).
    init?(json: [String: Any]?) {
        guard let name = json?["name"] as? String, !name.isEmpty else { return nil }
        let agent = json?["agent"] as? String ?? ""
        self.init(name: name, arguments: json?["arguments"] as? String ?? "", agent: agent.isEmpty ? nil : agent)
    }
}

final class AgentWatch {
    /// What a look reads (under the session's lock).
    struct Sight {
        var screen: String
        var title: String
        var progress: String
    }

    typealias Program = SessionProgram

    /// The record the screen's state goes in (the app's is the same).
    static let record = "screen"
    /// A screen that stops showing work without showing it's at rest waits
    /// this long before it counts as idle (Kero's idleHold).
    static let idleHold: UInt64 = 700_000_000
    /// A turn's end is told this much later, so an agent that says so
    /// itself (Codex's notify) is the one that does.
    static let doneDelay = 1.5
    /// How often the process table is asked who's in front, at most.
    static let foregroundEvery: UInt64 = 1_000_000_000

    private let queue = DispatchQueue(label: "liberttyd.agent-watch", qos: .utility)
    private let foreground: () -> (pgid: pid_t, name: String)?
    private let sight: () -> Sight
    private let publish: (_ state: String, _ app: String) -> Void
    private let programChanged: (Program?) -> Void

    private var program: Program?
    private var identified: (pgid: pid_t, name: String)?
    private var foregroundAt: UInt64 = 0
    private var foregroundPending = false
    private var lookPending = false
    /// What the screen last showed, and what was last told (nil: nothing, or cleared).
    private var seen: AgentScreen.State?
    private var told: String?
    private var idleFrom: UInt64?
    private var ending: DispatchWorkItem?
    /// The program's own records (OSC 7501: its hooks), id → app, while they stand.
    private var reports: [String: (app: String, state: String)] = [:]
    private var ended = false

    init(foreground: @escaping () -> (pgid: pid_t, name: String)?, sight: @escaping () -> Sight,
         publish: @escaping (_ state: String, _ app: String) -> Void, programChanged: @escaping (Program?) -> Void) {
        self.foreground = foreground
        self.sight = sight
        self.publish = publish
        self.programChanged = programChanged
    }

    /// Output came: who's in front may have changed (once a second at most),
    /// and an agent's screen is looked at soon, once however much more comes.
    func poke() {
        queue.async { [self] in
            guard !ended else { return }
            checkForeground()
            if program?.agent != nil || told != nil { scheduleLook() }
        }
    }

    /// A report of the program's own (OSC 7501), as the session parsed it.
    func programReported(record: String, app: String, state: String) {
        queue.async { [self] in
            guard record != Self.record else { return }
            if state == "clear" {
                // An empty id clears them all; otherwise the id and what's under it.
                reports = record.isEmpty ? [:] : reports.filter { $0.key != record && !$0.key.hasPrefix(record + "/") }
            } else {
                reports[record] = (app, state)
            }
            if program?.agent != nil { scheduleLook() }
        }
    }

    /// The shell came back to its prompt: whatever reported itself there has
    /// ended, and so have its records, as far as this watch goes (a done one
    /// the app keeps until it's seen; here it would silence the next agent).
    func atPrompt() {
        queue.async { [self] in reports = [:] }
    }

    /// The session ended: what the screen said goes, but a turn's end.
    func end() {
        queue.async { [self] in
            ended = true
            ending?.cancel()
            if let told, told != "done" { publish("clear", program?.agent ?? "") }
            told = nil
        }
    }

    // MARK: Who's in front

    private func checkForeground() {
        let now = monotonicNanos()
        guard now - foregroundAt >= Self.foregroundEvery else {
            // Asked a moment ago: again once the second is over, in case
            // that was the last output for a while (an agent just started).
            guard !foregroundPending else { return }
            foregroundPending = true
            let wait = Double(Self.foregroundEvery - (now - foregroundAt)) / 1e9 + 0.01
            queue.asyncAfter(deadline: .now() + wait) { [self] in
                foregroundPending = false
                guard !ended else { return }
                checkForeground()
                if program?.agent != nil || told != nil { scheduleLook() }
            }
            return
        }
        foregroundAt = now
        let process = foreground()
        // The same process as last time, known for what it is: nothing to ask.
        // A runtime that isn't an agent yet may start one (tclaude: node, then claude).
        if let process, let identified, process == identified, let program,
           program.agent != nil || !AgentNames.runsAnotherProgram(process.name) { return }
        if process == nil, identified == nil { return }
        let next: Program?
        if let process {
            let found = ForegroundProgram.identify(process)
            next = Program(name: found.name, arguments: found.arguments, agent: ForegroundProgram.agent(found))
        } else {
            next = nil
        }
        identified = process
        guard next != program else { return }
        let agentChanged = next?.agent != program?.agent
        program = next
        programChanged(next)
        if agentChanged {
            // Another program: what the last one reported of itself is its
            // own (but a report that came first from the one now in front,
            // as a hook can before this looks, stands).
            reports = reports.filter { next?.agent != nil && AgentNames.key($0.value.app) == next?.agent }
            seen = nil
            idleFrom = nil
            ending?.cancel()
            ending = nil
            // The agent left: what its screen said goes, but a turn's end.
            if next?.agent == nil, let told, told != "done" {
                publish("clear", "")
                self.told = nil
            }
        }
    }

    // MARK: Its screen

    private func scheduleLook() {
        guard !lookPending else { return }
        lookPending = true
        queue.asyncAfter(deadline: .now() + 0.15) { [self] in
            lookPending = false
            guard !ended else { return }
            look()
        }
    }

    private func look() {
        guard let agent = program?.agent, let manifest = AgentScreen.manifest(for: agent) else { return }
        // What the program or its hooks report stands; Codex's notify only ends turns.
        if reports.contains(where: { $0.value.app != "codex" }) {
            seen = nil
            if told != nil, told != "done" { publish("clear", agent) }
            told = nil
            return
        }
        let s = sight()
        let result = AgentScreen.detect(manifest, .init(screen: s.screen, title: s.title, progress: s.progress))
        guard !result.skip, result.state != .unknown else { return }
        let state = result.state
        if state == seen {
            idleFrom = nil
            return
        }
        if state == .idle, !result.visible, told == "working" {
            let now = monotonicNanos(), from = idleFrom ?? now
            idleFrom = from
            if now - from < Self.idleHold {
                // Look again once the hold is over, whether or not more comes.
                queue.asyncAfter(deadline: .now() + Double(from + Self.idleHold - now) / 1e9 + 0.02) { [self] in
                    guard idleFrom == from, !ended else { return }
                    look()
                }
                return
            }
        }
        idleFrom = nil
        seen = state
        ending?.cancel()
        ending = nil
        switch state {
        case .working, .blocked:
            told = state.rawValue
            publish(state.rawValue, agent)
        default:
            let wasWorking = told == "working"
            if told != nil, told != "done" { publish("clear", agent) }
            told = nil
            guard wasWorking else { return }
            // A turn ended: done, unless the agent said so itself.
            let ending = DispatchWorkItem { [self] in
                guard seen == .idle, program?.agent == agent, !ended else { return }
                if reports.contains(where: { $0.value.state == "done" || $0.value.state == "error" }) { return }
                told = "done"
                publish("done", agent)
            }
            self.ending = ending
            queue.asyncAfter(deadline: .now() + Self.doneDelay, execute: ending)
        }
    }
}
