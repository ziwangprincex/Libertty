import Foundation
import Darwin

/// `libertty +pick` and `+input`: a script asks the person at this Mac,
/// over the window of the pane it runs in (the window in front outside
/// one), and prints the answer — the item picked (one a line with
/// `--multiple`), or the text typed. 0 answered, 1 cancelled (Esc; nothing
/// printed), 124 out of time, 5 busy (that window is asking something
/// already). This Mac's only: there's no `libertty` on a host, and over
/// ssh the screen it asks on isn't yours.
enum ScriptPromptCLI {
    static func run(_ args: [String], kind: ScriptPrompt.Kind) -> Int32 {
        let command = "+" + kind.rawValue
        guard CLI.host == nil else {
            CLI.fail("\(command) asks on this Mac's screen; --host doesn't apply to it")
            return CLI.ExitCode.usage
        }
        let environment = ProcessInfo.processInfo.environment
        let session = environment["LIBERTTY_SESSION"].flatMap { $0.isEmpty ? nil : $0 }
        // Logged in from elsewhere, outside a Libertty pane: the screen it
        // would ask on is this Mac's, where nobody may be looking.
        if session == nil, environment["SSH_CONNECTION"] != nil {
            CLI.fail("\(command) asks on this Mac's screen, not over ssh: run it in a Libertty pane here")
            return CLI.ExitCode.failure
        }
        let prompt: ScriptPrompt
        switch ScriptPrompt.parse(args, kind: kind, stdin: { readStandardInput(timeout: $0) }) {
        case .success(let parsed): prompt = parsed
        case .failure(let problem):
            CLI.fail(problem.message)
            return CLI.ExitCode.usage
        }
        guard CLI.liberttyRunning else { CLI.fail("Libertty isn't running"); return CLI.ExitCode.unreachable }
        var request = prompt.fields
        request["session"] = session ?? ""
        // While this command waits: the app takes the prompt down when it's gone (^C, killed).
        request["pid"] = String(getpid())
        // What's typed into a secure field comes back in a file of ours,
        // in a directory only this user can enter: never in the reply.
        var answerFile: String?
        if prompt.secure {
            guard let file = privateFile() else { CLI.fail("couldn't make a private file for the answer"); return CLI.ExitCode.failure }
            answerFile = file
            request["answerFile"] = file
        }
        defer {
            if let answerFile {
                unlink(answerFile)
                rmdir((answerFile as NSString).deletingLastPathComponent)
            }
        }
        switch ask(request, timeout: prompt.timeout, answerFile: answerFile) {
        case .answered(let answer):
            guard let text = prompt.output(for: answer) else { return CLI.ExitCode.failure }
            if answer != .chosen([]) { print(text) }
            return CLI.ExitCode.ok
        case .cancelled:
            return CLI.ExitCode.failure
        case .timedOut:
            // (Not on stdout: what a script reads as the answer stays empty.)
            let seconds = prompt.timeout ?? 0
            let shown = seconds == seconds.rounded() && seconds < 1e15 ? "\(Int(seconds))" : "\(seconds)"
            CLI.fail("no answer in \(shown) second\(seconds == 1 ? "" : "s")")
            return CLI.ExitCode.timeout
        case .busy:
            CLI.fail("that window is already asking something (another +pick or +input); answer it first")
            return CLI.ExitCode.busy
        case .refused(let message):
            CLI.fail(message)
            return CLI.ExitCode.failure
        case .gone(let why):
            CLI.fail(why)
            return CLI.ExitCode.failure
        case .silent:
            CLI.fail("Libertty didn't answer (one older than this command?)")
            return CLI.ExitCode.unreachable
        }
    }

    /// Items on stdin when it isn't the terminal (`ls | libertty +pick`).
    /// A stdin that says nothing for 10 seconds (or the prompt's timeout)
    /// isn't one with items: a script that left its stdin open and gave no
    /// items fails rather than waiting forever. Once lines come, to the end
    /// (within the timeout, when there is one).
    private static func readStandardInput(timeout: Double?) -> String? {
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        let start = Date()
        let firstWait = min(timeout ?? 10, 10)
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let limit = bytes.isEmpty ? firstWait : (timeout ?? .infinity)
            let left = limit - Date().timeIntervalSince(start)
            guard left > 0 else { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fds, 1, left.isFinite ? Int32(min(left * 1000, 60_000)) : 60_000)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { return nil }
            if ready == 0 { continue }
            let n = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(contentsOf: buffer[0..<n])
        }
    }

    /// A new empty file only this user can read, in a directory of its own.
    private static func privateFile() -> String? {
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("libertty-answer.XXXXXX").utf8CString)
        guard let dir = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }).map({ String(cString: $0) }) else { return nil }
        let path = (dir as NSString).appendingPathComponent("answer")
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            rmdir(dir)
            return nil
        }
        close(fd)
        return path
    }

    enum Outcome: Equatable {
        case answered(ScriptPrompt.Answer), cancelled, timedOut, busy, refused(String), gone(String), silent
    }

    /// Post the request, then wait: a few seconds for word that it's up,
    /// then for the answer, until `timeout` runs out (nil: as long as it takes).
    /// A copy of Libertty without the command's pane says `no-pane`: when
    /// no copy has asked half a second after one said so, it's asked again
    /// for the window in front (`fallback`).
    private static func ask(_ request: [String: String], timeout: Double?, answerFile: String?) -> Outcome {
        let token = UUID().uuidString
        var replies: [[String: String]] = []
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: RemoteControl.replied, object: nil, queue: .main) { note in
            guard let reply = note.userInfo as? [String: String], reply["token"] == token else { return }
            replies.append(reply)
        }
        defer { center.removeObserver(observer) }
        var request = request
        request["reply"] = token
        RemoteControl.post(request)
        let start = Date()
        var shown = false
        var noPaneSince: Date?
        var fellBack = false
        // The Libertty showing it: gone (quit, crashed), there's no answer to wait for.
        var app: pid_t?
        while true {
            while let reply = replies.first {
                replies.removeFirst()
                switch reply["result"] {
                case "shown":
                    shown = true
                    app = reply["pid"].flatMap { pid_t($0) }
                case "no-pane": if noPaneSince == nil { noPaneSince = Date() }
                case "busy": return .busy
                case "refused", "error": return .refused(reply["message"] ?? "it couldn't be asked")
                case "closed": return .gone(reply["message"] ?? "the question was taken down unanswered")
                case "timeout": return .timedOut
                default:
                    if reply["result"] == "answered", reply["file"] == "1" {
                        guard let answerFile, let data = FileManager.default.contents(atPath: answerFile) else {
                            return .refused("the answer couldn't be read")
                        }
                        return .answered(.text(String(decoding: data, as: UTF8.self)))
                    }
                    if let answer = ScriptPrompt.answer(in: reply) { return answer == .cancelled ? .cancelled : .answered(answer) }
                }
            }
            if !shown, let since = noPaneSince, Date().timeIntervalSince(since) >= 0.5 {
                if fellBack { return .refused("no Libertty window to ask in") }
                fellBack = true
                noPaneSince = nil
                request["fallback"] = "1"
                RemoteControl.post(request)
            }
            let waited = Date().timeIntervalSince(start)
            if let timeout, waited >= timeout { return .timedOut }
            if !shown, noPaneSince == nil, waited >= (fellBack ? 10 : 5) { return .silent }
            if let app, kill(app, 0) != 0, errno == ESRCH { return .gone("Libertty quit with the question unanswered") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
