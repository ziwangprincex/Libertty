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
        switch ScriptPrompt.parse(args, kind: kind, stdin: readStandardInput) {
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
        switch ask(request, timeout: prompt.timeout) {
        case .answered(let answer):
            guard let text = prompt.output(for: answer) else { return CLI.ExitCode.failure }
            if answer != .chosen([]) { print(text) }
            return CLI.ExitCode.ok
        case .cancelled:
            return CLI.ExitCode.failure
        case .timedOut:
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
    private static func readStandardInput() -> String? {
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }

    enum Outcome: Equatable {
        case answered(ScriptPrompt.Answer), cancelled, timedOut, busy, refused(String), gone(String), silent
    }

    /// Post the request, then wait: a few seconds for word that it's up,
    /// then for the answer, until `timeout` runs out (nil: as long as it takes).
    private static func ask(_ request: [String: String], timeout: Double?) -> Outcome {
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
        // The Libertty showing it: gone (quit, crashed), there's no answer to wait for.
        var app: pid_t?
        while true {
            while let reply = replies.first {
                replies.removeFirst()
                switch reply["result"] {
                case "shown":
                    shown = true
                    app = reply["pid"].flatMap { pid_t($0) }
                case "busy": return .busy
                case "refused", "error": return .refused(reply["message"] ?? "it couldn't be asked")
                case "closed": return .gone(reply["message"] ?? "the question was taken down unanswered")
                case "timeout": return .timedOut
                default:
                    if let answer = ScriptPrompt.answer(in: reply) { return answer == .cancelled ? .cancelled : .answered(answer) }
                }
            }
            let waited = Date().timeIntervalSince(start)
            if let timeout, waited >= timeout { return .timedOut }
            if !shown, waited >= 5 { return .silent }
            if let app, kill(app, 0) != 0, errno == ESRCH { return .gone("Libertty quit with the question unanswered") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
