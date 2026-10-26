import AppKit
import LiberttyCore

/// Whether new sessions live in liberttyd (so they survive quitting Libertty) and
/// the machinery to get liberttyd going. Decided at launch — or a little later,
/// when liberttyd's first run takes long.
enum Persistence {
    /// New sessions are created in liberttyd.
    private(set) static var enabled = false
    /// Posted (main queue) when `enabled` changed after launch: liberttyd came
    /// up late, or it's gone and couldn't be started again.
    static let changed = Notification.Name("LiberttyPersistenceChanged")

    /// liberttyd ships next to the app's executable (Contents/MacOS/liberttyd).
    static var daemonExecutable: String? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = dir.appendingPathComponent("liberttyd").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// `$LIBERTTY_DAEMON_LOG` (tests, beside their private socket), else ~/Library/Logs/Libertty.
    static var logPath: String {
        if let path = ProcessInfo.processInfo.environment["LIBERTTY_DAEMON_LOG"], !path.isEmpty { return path }
        return (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Libertty/liberttyd.log")
    }

    /// Start (or upgrade) liberttyd if sessions should persist; on any failure
    /// Libertty runs its shells itself, as before.
    static func setUp(wanted: Bool) {
        guard wanted, let exe = daemonExecutable else {
            enabled = false
            return
        }
        // Keep the log from growing forever: start over past a megabyte.
        if let size = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.size] as? Int, size > 1 << 20 {
            try? FileManager.default.removeItem(atPath: logPath + ".old")
            try? FileManager.default.moveItem(atPath: logPath, toPath: logPath + ".old")
        }
        switch DaemonClient.start(executable: exe, logPath: logPath) {
        case .running:
            enabled = true
        case .failed:
            NSLog("Libertty: liberttyd didn't start; sessions won't outlive the app")
        case .starting(let pid):
            awaitLateStart(pid)
        }
    }

    /// liberttyd is still coming up (the system checking a new binary): the
    /// panes made meanwhile run here, the ones after it in liberttyd.
    private static func awaitLateStart(_ pid: pid_t) {
        NSLog("Libertty: liberttyd is slow to start; sessions persist once it answers")
        DispatchQueue.global().async {
            guard DaemonClient.awaitStart(of: pid, seconds: 120) else {
                return NSLog("Libertty: liberttyd didn't start; sessions won't outlive the app")
            }
            DispatchQueue.main.async { set(true) }
        }
    }

    private static func set(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// liberttyd isn't reachable any more (it exits when idle — as it does when
    /// its slow first start ended with no session yet — or it crashed): start
    /// it again for the session being made. Whether it answers now.
    /// Not answering in time either, sessions stop persisting meanwhile
    /// (no pane waits on it again): back on when it does come up.
    static func restart() -> Bool {
        guard enabled, let exe = daemonExecutable else { return false }
        NSLog("Libertty: liberttyd isn't reachable; starting it again")
        switch DaemonClient.start(executable: exe, logPath: logPath, seconds: 3) {
        case .running:
            return true
        case .starting(let pid):
            set(false)
            awaitLateStart(pid)
        case .failed:
            NSLog("Libertty: liberttyd didn't start again; sessions won't outlive the app")
            set(false)
        }
        return false
    }

    /// Sessions are named by the app, so a shell can know its own
    /// (`$LIBERTTY_SESSION`) from its first command on.
    static func newSessionID() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// End every session liberttyd keeps (Quit and End Sessions).
    static func endAllSessions() {
        _ = DaemonClient.request(.shutdown, timeout: 2)
    }
}
