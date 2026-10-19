import AppKit
import LiberttyCore

/// Whether new sessions live in liberttyd (so they survive quitting Libertty) and
/// the machinery to get liberttyd going. Decided once at launch.
enum Persistence {
    /// New sessions are created in liberttyd.
    private(set) static var enabled = false

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
        enabled = DaemonClient.ensureRunning(executable: exe, logPath: logPath)
        if !enabled { NSLog("Libertty: liberttyd didn't start; sessions won't outlive the app") }
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
