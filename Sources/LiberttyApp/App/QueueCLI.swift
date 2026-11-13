import AppKit
import LiberttyCore

/// `libertty +queue [ID] TEXT…`, `+queue [ID] --list | --clear`: a prompt
/// for a pane's queue (PromptQueue), or what's queued, from a script or
/// another agent. The prompt's text goes by a file only the user can write
/// (in the data folder), never in the request itself: requests to the app
/// travel as notifications other programs could post, and a prompt is
/// typing into a terminal.
enum QueueCLI {
    static let usage = "usage: libertty +queue [ID] TEXT... | libertty +queue [ID] --list | --clear"

    /// Where prompts wait for the app to take them.
    static var directory: URL { Blocks.dataDirectory.appendingPathComponent("queue-requests", isDirectory: true) }

    static func run(_ args: [String]) -> Int32 {
        var words = args
        var op = "add"
        if let i = words.firstIndex(of: "--list") { op = "list"; words.remove(at: i) }
        if let i = words.firstIndex(of: "--clear") { op = op == "add" ? "clear" : "both"; words.remove(at: i) }
        guard op != "both", !words.contains(where: { $0.hasPrefix("--") }) else { return fail(usage, 2) }
        // The ID first, unless the pane's own ($LIBERTTY_SESSION) is meant:
        // a first word that's none of liberttyd's sessions is the text.
        var id = ProcessInfo.processInfo.environment["LIBERTTY_SESSION"].flatMap { $0.isEmpty ? nil : $0 }
        if let first = words.first, words.count > 1 || op != "add" || id == nil,
           id == nil || (DaemonClient.sessions() ?? []).contains(where: { $0.id == first }) {
            id = first
            words.removeFirst()
        }
        guard let id else { return fail(usage + " (outside a Libertty session, give the pane's ID)", 2) }
        var info = ["kind": "queue", "id": id, "op": op]
        if op == "add" {
            let text = words.joined(separator: " ")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fail(usage, 2) }
            guard let token = try? write(text) else { return fail("couldn't write the prompt to \(directory.path)", 1) }
            info["file"] = token
        } else if !words.isEmpty {
            return fail(usage, 2)
        }
        guard let answer = RemoteControl.request(info, timeout: 5) else {
            if let token = info["file"] { try? FileManager.default.removeItem(at: directory.appendingPathComponent(token)) }
            return fail("Libertty didn't answer (is it running?)", 1)
        }
        switch answer["result"] {
        case "queued":
            print(answer["count"] ?? "")
            return 0
        case "ok":
            if let text = answer["text"], !text.isEmpty { print(text) }
            return 0
        case "no-pane":
            return fail("no window shows session \(id) (libertty +list-sessions)", 1)
        default:
            return fail(answer["message"] ?? "Libertty refused it", 1)
        }
    }

    private static func fail(_ message: String, _ status: Int32) -> Int32 {
        FileHandle.standardError.write(Data("libertty: \(message)\n".utf8))
        return status
    }

    /// The prompt in a file of its own, readable by the user alone; its name.
    static func write(_ text: String) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let token = UUID().uuidString
        let url = directory.appendingPathComponent(token)
        guard fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return token
    }

    /// The prompt a request names, taken (the file goes): only a regular
    /// file of the user's own, written alone, in the folder; nil otherwise.
    static func take(_ token: String) -> String? {
        guard let uuid = UUID(uuidString: token), uuid.uuidString == token.uppercased() else { return nil }
        let url = directory.appendingPathComponent(uuid.uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var st = stat()
        guard lstat(url.path, &st) == 0, Int(st.st_mode) & Int(S_IFMT) == Int(S_IFREG), st.st_uid == getuid(),
              Int(st.st_mode) & 0o077 == 0, st.st_size < 1 << 20,
              let data = FileManager.default.contents(atPath: url.path) else { return nil }
        // Old ones the app never took (it wasn't running) go as a new one comes.
        prune()
        return String(data: data, encoding: .utf8)
    }

    private static func prune() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let before = Date().addingTimeInterval(-3600)
        for name in names {
            let url = directory.appendingPathComponent(name)
            if let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, date < before {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// The app's side: the request for a pane some window shows.
    static func handle(_ info: [String: String], in controllers: [TerminalWindowController]) {
        guard let id = info["id"], let pane = controllers.lazy.compactMap({ $0.pane(showing: id) }).first else {
            if let token = info["file"] { _ = take(token) }
            return RemoteControl.answer(info, ["result": "no-pane"])
        }
        let session = pane.session
        switch info["op"] {
        case "add":
            guard let token = info["file"], let text = take(token) else {
                return RemoteControl.answer(info, ["result": "error", "message": "the prompt's file wasn't there, or wasn't yours"])
            }
            PromptQueues.shared.enqueue(text, for: session)
            RemoteControl.answer(info, ["result": "queued", "count": String(PromptQueues.shared.count(of: session))])
        case "list":
            let queue = PromptQueues.shared.queue(of: session)
            let lines = queue.items.enumerated().map { "\($0.offset + 1)\t" + $0.element.text.replacingOccurrences(of: "\n", with: "\\n") }
            let paused = queue.paused && !queue.isEmpty ? ["(paused)"] : []
            RemoteControl.answer(info, ["result": "ok", "text": (paused + lines).joined(separator: "\n")])
        case "clear":
            PromptQueues.shared.update(session) { $0.clear() }
            RemoteControl.answer(info, ["result": "ok"])
        default:
            RemoteControl.answer(info, ["result": "error", "message": "unknown request"])
        }
    }
}
