import Foundation

/// The coding agents' conversations that ran in Libertty's panes (Kero's
/// Past conversations): what Claude Code's hooks and Codex's notify say as
/// they run (`+agent-setup`), kept in the data folder's conversations.json,
/// the last 200, so that one can be picked up again — after liberttyd lost
/// its pane (a reboot), from the palette (⌘⇧O), or `libertty +resume`.
struct Conversation: Codable, Equatable {
    /// "claude" or "codex".
    var agent: String
    /// The agent's own id for it, which its resume option takes.
    var id: String
    /// The liberttyd session of the pane it ran in, last.
    var session: String
    var directory: String
    /// The session's name (`+rename-session`, the agent naming its task), when it had one.
    var name: String = ""
    /// What it was about: the first prompt, cut short.
    var title: String = ""
    var started: Double
    var active: Double
    /// The agent ended it (it exited, or /clear began another): a pane
    /// coming back after a reboot doesn't resume it.
    var ended = false

    /// How it shows in a list.
    var label: String {
        if !name.isEmpty { return name }
        if !title.isEmpty { return title }
        return (directory as NSString).lastPathComponent
    }

    var agentName: String {
        switch agent {
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: AgentExtensions.Agent(rawValue: agent)?.name ?? agent
        }
    }
}

enum Conversations {
    static let limit = 200

    static var url: URL { Blocks.dataDirectory.appendingPathComponent("conversations.json") }

    /// An agent's id as resume options take it: nothing a shell would read.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }

    /// What the shell types to pick the conversation up again, as the agent's own resume option would.
    static func resumeCommand(_ c: Conversation) -> String? {
        guard isValidID(c.id) else { return nil }
        switch c.agent {
        case "claude": return "claude --resume \(c.id)"
        case "codex": return "codex resume \(c.id)"
        case "pi", "omp", "opencode": return "\(c.agent) --session \(c.id)"
        default: return nil
        }
    }

    /// What the shell types to start a new conversation from this one's
    /// transcript, the original left as it was (its own agent's fork):
    /// Claude Code's --fork-session, Codex's fork. Nil for agents without one.
    static func forkCommand(_ c: Conversation) -> String? {
        guard isValidID(c.id) else { return nil }
        switch c.agent {
        case "claude": return "claude --resume \(c.id) --fork-session"
        case "codex": return "codex fork \(c.id)"
        default: return nil
        }
    }

    /// Every conversation, the last to be active first.
    static func load(from url: URL = url) -> [Conversation] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Conversation].self, from: data) else { return [] }
        return list.sorted { $0.active > $1.active }
    }

    /// Changes the list under a lock (hooks of several panes write at once),
    /// keeping the newest `limit`, written whole or not at all.
    static func update(at url: URL = url, _ change: (inout [Conversation]) -> Void) {
        FileLock.withLock(url) {
            var list = load(from: url)
            let before = list
            change(&list)
            list.sort { $0.active > $1.active }
            if list.count > limit { list.removeLast(list.count - limit) }
            guard list != before, let data = try? JSONEncoder().encode(list) else { return }
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// A conversation running (again) in a pane: the agent's id, the pane's
    /// session, where. An agent starting another in a pane (Claude Code's
    /// /clear) ends the one before.
    static func record(agent: String, id: String, session: String, directory: String, title: String = "",
                       now: Double = Date().timeIntervalSince1970, at url: URL = url) {
        guard isValidID(id), !session.isEmpty else { return }
        update(at: url) { list in
            for i in list.indices where list[i].session == session && list[i].agent == agent && list[i].id != id {
                list[i].ended = true
            }
            if let i = list.firstIndex(where: { $0.agent == agent && $0.id == id }) {
                list[i].session = session
                if !directory.isEmpty { list[i].directory = directory }
                if list[i].title.isEmpty { list[i].title = shortTitle(title) }
                list[i].active = now
                list[i].ended = false
            } else {
                list.append(Conversation(agent: agent, id: id, session: session, directory: directory,
                                         title: shortTitle(title), started: now, active: now))
            }
        }
    }

    /// The agent ended it.
    static func end(agent: String, id: String, now: Double = Date().timeIntervalSince1970, at url: URL = url) {
        update(at: url) { list in
            for i in list.indices where list[i].agent == agent && list[i].id == id {
                list[i].ended = true
                list[i].active = now
            }
        }
    }

    /// `agent` left a pane of `session` (its shell is back in front, or the
    /// pane closed): what it ran there isn't running anymore. Only Claude
    /// Code says so itself (SessionEnd); without this, a Codex you quit long
    /// ago would be resumed in its pane after a reboot. A next prompt or turn
    /// in it (`record`) makes it running again.
    static func endRunning(session: String, agent: String, at url: URL = url) {
        guard !session.isEmpty else { return }
        update(at: url) { list in
            for i in list.indices where list[i].session == session && list[i].agent == agent && !list[i].ended {
                list[i].ended = true
            }
        }
    }

    /// The pane's session was named: its conversations go by the name.
    static func rename(session: String, to name: String, at url: URL = url) {
        guard !session.isEmpty else { return }
        update(at: url) { list in
            for i in list.indices where list[i].session == session && !list[i].ended { list[i].name = name }
        }
    }

    /// What a pane of `session` was running when it was lost: its last
    /// conversation, if the agent hadn't ended it.
    static func running(in session: String, among list: [Conversation]) -> Conversation? {
        list.first { $0.session == session && !$0.ended }
    }

    /// One by its id, a prefix of it, or its name.
    static func find(_ key: String, among list: [Conversation]) -> Conversation? {
        let k = key.lowercased()
        return list.first { $0.id.lowercased() == k } ?? list.first { $0.name.lowercased() == k }
            ?? list.first { $0.id.lowercased().hasPrefix(k) }
    }

    /// Those matching `query`, by name, title, folder or id.
    static func matching(_ query: String, among list: [Conversation]) -> [Conversation] {
        let q = query.lowercased()
        guard !q.isEmpty else { return list }
        return list.filter { c in
            [c.name, c.title, c.directory, c.id, c.agentName].contains { $0.lowercased().contains(q) }
        }
    }

    static func shortTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = ProgramStatusStore.sanitize(line).trimmingCharacters(in: .whitespaces)
        return clean.count > 80 ? String(clean.prefix(79)) + "…" : clean
    }
}
