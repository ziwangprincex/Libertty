import AppKit
import CGhosttyVt

/// Prompts waiting for a pane (Otty's Prompt Queue): each goes out when the
/// pane is ready for it — a coding agent at rest (its status says it's
/// idle or done, or nothing; never while it waits for your answer), a
/// shell back at its prompt — and the next one only once the pane has
/// worked on the last and come to rest again.
struct PromptQueue: Equatable {
    struct Item: Equatable, Identifiable {
        let id: UUID
        var text: String

        init(_ text: String, id: UUID = UUID()) {
            self.text = text
            self.id = id
        }
    }

    /// How the pane is, as a step looks at it.
    struct Look {
        /// You typed into the pane a moment ago: a prompt pasted now would
        /// land on what you're writing there.
        var typing = false
        /// What its programs report (OSC 7501, the agent's screen, a password): the most urgent.
        var state: ProgramStatusStore.State?
        /// A coding agent is in front.
        var agent: Bool
        /// No program is in front of the shell (it waits at its prompt).
        var atPrompt: Bool
        /// Seconds since its program last printed.
        var quietFor: Double
        /// Output came since the last prompt went out.
        var printedSinceSend: Bool
        var now: Double
    }

    enum Phase: Equatable {
        /// Ready for the next as soon as the pane is.
        case waiting
        /// Sent at `since`: the pane hasn't been seen at work on it yet.
        case sent(since: Double)
        /// Seen at work on the last one: the next once it's at rest again.
        case working
    }

    private(set) var items: [Item] = []
    private(set) var phase = Phase.waiting
    /// Stopped by hand, or because the last couldn't go (a program without
    /// bracketed paste and a prompt of several lines): nothing goes until resumed.
    var paused = false

    var isEmpty: Bool { items.isEmpty }

    mutating func append(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        items.append(Item(clean))
    }

    mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    mutating func move(_ id: UUID, by offset: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(items.count - 1, i + offset))
        guard i != j else { return }
        items.insert(items.remove(at: i), at: j)
    }

    mutating func edit(_ id: UUID, to text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { items.remove(at: i) } else { items[i].text = clean }
    }

    mutating func clear() {
        items.removeAll()
        phase = .waiting
        paused = false
    }

    /// Whether the pane is busy with something: an agent at work or asking
    /// you, a command running at the shell.
    static func busy(_ look: Look) -> Bool {
        if look.state == .working || look.state == .blocked { return true }
        return !look.agent && !look.atPrompt
    }

    /// Whether the pane would take a prompt now. Not while anything waits for
    /// you (a permission, a question, a password); an agent at rest says so,
    /// or at least has stopped printing; a shell is at its prompt.
    static func ready(_ look: Look) -> Bool {
        if look.typing || look.state == .blocked || look.state == .working { return false }
        if look.agent { return look.quietFor >= 0.6 }
        return look.atPrompt && look.quietFor >= 0.3
    }

    /// How long after a prompt went out, never seen at work, the pane counts
    /// as done with it once quiet: a quick one finished between two looks,
    /// or an agent that tells nothing printed its answer and stopped.
    static func settle(agent: Bool) -> Double { agent ? 3 : 0.6 }

    /// One look at the pane: the prompt to send now, if any (taken off the
    /// queue; the caller sends it). Called a few times a second while
    /// there's something queued.
    mutating func step(_ look: Look) -> Item? {
        switch phase {
        case .sent(let since):
            if Self.busy(look) {
                phase = .working
                return nil
            }
            // Never seen at work: done with it once it printed and went quiet,
            // or (nothing printed) after a while.
            let settled = look.quietFor >= Self.settle(agent: look.agent)
                && (look.printedSinceSend || look.now - since >= 10)
            guard settled, Self.ready(look) else { return nil }
            phase = .waiting
        case .working:
            guard Self.ready(look) else { return nil }
            phase = .waiting
        case .waiting:
            break
        }
        guard !paused, !items.isEmpty, Self.ready(look) else { return nil }
        let next = items.removeFirst()
        phase = .sent(since: look.now)
        return next
    }

    /// The prompt taken by `step` couldn't go: back at the front, the queue paused.
    mutating func putBack(_ item: Item) {
        items.insert(item, at: 0)
        phase = .waiting
        paused = true
    }
}

/// Every pane's queue, by session (a pane keeps its queue as it moves to
/// another tab or window), and the clock that looks at them while any has
/// prompts. Main thread only.
final class PromptQueues {
    static let shared = PromptQueues()

    private init() { connectToWindows() }

    private struct Entry {
        weak var session: TerminalSession?
        var queue = PromptQueue()
        /// The output count when the last prompt went out.
        var outputAtSend: UInt64 = 0
        /// An agent was seen in front while prompts waited: it stays one until
        /// the shell is back (its report of being done, once you've looked at
        /// it, is gone; what runs in front is still the agent).
        var agentSeen = false
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var timer: Timer?
    /// Told when a queue changes (its count on the pane and the sidebar).
    static let changed = Notification.Name("LiberttyPromptQueueChanged")

    /// Whether a coding agent is in front of the session's pane (its window
    /// knows); set by the app, false in tests.
    var agentInFront: (TerminalSession) -> Bool = { _ in false }

    /// A session's entry: one left by a session gone, whose address a new
    /// one took, isn't this one's.
    private func entry(of session: TerminalSession) -> Entry? {
        guard let entry = entries[ObjectIdentifier(session)], entry.session === session else { return nil }
        return entry
    }

    func queue(of session: TerminalSession) -> PromptQueue { entry(of: session)?.queue ?? PromptQueue() }

    func count(of session: TerminalSession) -> Int { queue(of: session).items.count }

    /// Change a session's queue (adding, editing, reordering, clearing).
    func update(_ session: TerminalSession, _ change: (inout PromptQueue) -> Void) {
        let key = ObjectIdentifier(session)
        var entry = self.entry(of: session) ?? Entry(session: session)
        let before = entry.queue
        change(&entry.queue)
        entries[key] = entry.queue.isEmpty && entry.queue.phase == .waiting && !entry.queue.paused ? nil : entry
        if entry.queue != before { NotificationCenter.default.post(name: Self.changed, object: session) }
        startIfNeeded()
        // Ready already: the first goes now, not a tick later.
        tick()
    }

    func enqueue(_ text: String, for session: TerminalSession) {
        update(session) { $0.append(text) }
    }

    private func startIfNeeded() {
        guard timer == nil, entries.values.contains(where: { !$0.queue.isEmpty }) else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // What you type into a pane holds its queue a moment (Look.typing).
        typing = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let view = event.window?.firstResponder as? TerminalView { self?.typedAt[ObjectIdentifier(view.session)] = CACurrentMediaTime() }
            return event
        }
    }

    private var typing: Any?
    private var typedAt: [ObjectIdentifier: CFTimeInterval] = [:]
    /// How long a key typed into a pane holds its queue.
    static let typingHold: CFTimeInterval = 2.5

    /// Whether `session`'s pane takes a prompt: it shows in a window (one
    /// closed, its session kept a while for Undo, gets nothing until it comes
    /// back) and isn't read-only (Stop Sending Input).
    var takesInput: (TerminalSession) -> Bool = { _ in true }

    private func tick() {
        for (key, var entry) in entries {
            guard let session = entry.session, !session.hasExited else {
                // Its program ended: its queue goes with it.
                entries[key] = nil
                continue
            }
            guard takesInput(session) else { continue }
            guard !entry.queue.isEmpty else {
                if entry.queue.phase == .waiting { entries[key] = nil }
                continue
            }
            let mark = session.outputMark
            let atPrompt = !session.hasForegroundProgram
            entry.agentSeen = !atPrompt && (entry.agentSeen || agentInFront(session))
            let now = CACurrentMediaTime()
            let look = PromptQueue.Look(
                typing: typedAt[key].map { now - $0 < Self.typingHold } ?? false,
                state: session.programStatus.headline?.state, agent: entry.agentSeen,
                atPrompt: atPrompt, quietFor: CACurrentMediaTime() - mark.time,
                printedSinceSend: mark.count != entry.outputAtSend, now: CACurrentMediaTime())
            if let item = entry.queue.step(look) {
                if PromptSender.send(item.text, to: session) {
                    entry.outputAtSend = session.outputMark.count
                } else {
                    entry.queue.putBack(item)
                }
                entries[key] = entry
                NotificationCenter.default.post(name: Self.changed, object: session)
            } else {
                entries[key] = entry
            }
        }
        if !entries.values.contains(where: { !$0.queue.isEmpty }) {
            timer?.invalidate()
            timer = nil
            typing.map(NSEvent.removeMonitor)
            typing = nil
            typedAt.removeAll()
        }
    }
}

/// Typing a prompt into a pane: as one paste (bracketed, when the program
/// asked for it, so an agent takes several lines as one prompt), then
/// Return a moment later as its own key, so the agent's input doesn't take
/// it as part of the paste.
enum PromptSender {
    /// Whether it went. A prompt of several lines into a program that
    /// didn't ask for bracketed paste doesn't (each line would run).
    @discardableResult
    static func send(_ text: String, to session: TerminalSession, submit: Bool = true) -> Bool {
        guard !session.hasExited else { return false }
        switch session.paste(text, allowUnsafe: false) {
        case .needsConfirmation, .nothing: return false
        case .pasted: break
        }
        if submit { pressReturn(in: session) }
        return true
    }

    /// Return, a moment from now, as the program wants it encoded.
    static func pressReturn(in session: TerminalSession) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak session] in
            guard let session, !session.hasExited else { return }
            session.send(TerminalSession.Key(action: GHOSTTY_KEY_ACTION_PRESS, key: GHOSTTY_KEY_ENTER, mods: 0, consumedMods: 0,
                                             text: nil, unshiftedCodepoint: 0, composing: false))
        }
    }
}
