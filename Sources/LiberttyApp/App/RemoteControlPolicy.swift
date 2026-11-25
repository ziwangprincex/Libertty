import Foundation

/// `remote-control = false`: `libertty` commands — scripts, coding agents —
/// may still read (list sessions, capture a screen, wait, follow events)
/// and name their own session, but not drive Libertty or type into its
/// sessions. Both sides refuse: the command before it asks, the app (and
/// its panes' requests) when asked. It keeps well-behaved tools out; it's no
/// sandbox: a program that ignores it could write to liberttyd's socket itself.
enum RemoteControlPolicy {
    /// The commands it refuses: they change what's on screen or what runs.
    /// `+open`, `+diff` and `+browser` show something (the browser's reading
    /// and acting has browser-automation); `+daemon stop` and `restart`
    /// would end or move every session; `+pick` and `+input` put a question
    /// in front of whatever you're doing; `+set`, `+unset` and
    /// `+import-ghostty` write the config file — how every window looks,
    /// what a key does, what a new pane runs.
    static let driving: Set<String> = [
        "+action", "+focus", "+new-window", "+new-tab", "+attach", "+connect", "+split", "+move-pane", "+swap-pane",
        "+resize-pane", "+send", "+send-key", "+prompt", "+new-session", "+kill-session", "+resume", "+pick", "+input",
        "+set", "+unset",
    ]

    /// The requests the app still takes (`RemoteControl` kinds): they read,
    /// or show something, as the commands above. Every other one is refused —
    /// one without a kind (an action), and one of a kind it doesn't know:
    /// any program can post a request, and the app mustn't do what one
    /// slipped past this as.
    static let readingKinds: Set<String> = ["open", "browser", "list-panes"]

    static var message: String {
        "remote-control = false: Libertty doesn't let commands drive it (Settings ▸ Integrations ▸ Command Line)"
    }

    /// Why `command` may not run, or nil.
    static func refusal(_ command: String, _ args: [String], config: Config,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard !config.remoteControl else { return nil }
        if command == "+daemon" {
            let sub = args.first { !$0.hasPrefix("-") }
            return sub == "stop" || sub == "restart" ? message : nil
        }
        if command == "+queue" {
            // Prompts typed into a pane later: driving; what's queued: reading.
            return args.contains("--list") ? nil : message
        }
        if command == "+forward" {
            // A forward opens a port on this Mac and may open a page:
            // driving. Listing what's forwarded is reading.
            let sub = args.first { !$0.hasPrefix("-") }
            return sub == "ls" || sub == nil ? nil : message
        }
        if command == "+import-ghostty" {
            // What it would add: reading; adding it: driving.
            return args.contains("--dry-run") ? nil : message
        }
        if command == "+rename-session" {
            // An agent naming its own task: that pane's, given or implied.
            let mine = environment["LIBERTTY_SESSION"] ?? ""
            let own = args.count == 1 ? !mine.isEmpty : (args.count == 2 && !mine.isEmpty && args[0] == mine)
            return own ? nil : message
        }
        return driving.contains(command) ? message : nil
    }

    /// Whether the app refuses a request it was sent.
    static func refuses(_ info: [String: String], config: Config) -> Bool {
        guard !config.remoteControl else { return false }
        if info["kind"] == "queue" { return info["op"] != "list" }
        if info["kind"] == "forward" { return info["op"] != "ls" }
        return !readingKinds.contains(info["kind"] ?? "action")
    }
}
