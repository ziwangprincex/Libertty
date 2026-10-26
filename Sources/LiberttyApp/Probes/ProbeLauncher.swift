#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

/// The probes and benches (`Libertty --ui-probe …`, `--session-bench …`):
/// `runIfRequested` starts the one the arguments name, before the app does.
/// Each lives in a file of its own here (ProbeLauncher+NAME.swift); all of
/// Probes/ is in debug builds only (LIBERTTY_PROBES), never in a release.
enum ProbeLauncher {
    static func runIfRequested() {
        let args = CommandLine.arguments
        // A probe missing its arguments must stop here: run on, it would be
        // an ordinary launch, a real window that takes the focus.
        let arguments = ["--session-bench": 1, "--link-probe": 1, "--command-probe": 1, "--responsible-probe": 1,
                         "--ui-probe": 2, "--document-probe": 2, "--remote-probe": 1, "--output-probe": 1,
                         "--shell-probe": 2, "--parse-bench": 1, "--screen-probe": 1, "--screen-cover-probe": 1]
        // Not what follows -e: that's a command to run, its words its own.
        let own = args.firstIndex(of: "-e").map { Array(args[..<$0]) } ?? args
        for (flag, count) in arguments {
            guard let i = own.firstIndex(of: flag), i + count >= own.count else { continue }
            FileHandle.standardError.write(Data("\(flag) needs \(count == 1 ? "an argument" : "\(count) arguments")\n".utf8))
            exit(2)
        }
        // A probe or bench run by hand never reaches your liberttyd: without
        // a socket of its own (tests/run.sh gives one) it gets a private one,
        // so it can't take over, stop or fill the daemon your sessions live in.
        if args.dropFirst().contains(where: { $0.hasPrefix("--") && ($0.hasSuffix("-probe") || $0.hasSuffix("-bench")) }),
           (ProcessInfo.processInfo.environment["LIBERTTY_DAEMON_SOCKET"] ?? "").isEmpty {
            let dir = NSTemporaryDirectory() + "libertty-probe-\(getpid())"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            setenv("LIBERTTY_DAEMON_SOCKET", dir + "/liberttyd.sock", 1)
            setenv("LIBERTTY_DAEMON_LOG", dir + "/liberttyd.log", 1)
            setenv("LIBERTTY_STATE_FILE", dir + "/windows.json", 0)
            FileHandle.standardError.write(Data("(no LIBERTTY_DAEMON_SOCKET: a private liberttyd in \(dir))\n".utf8))
        }
        // A probe's blocks keep what they make (drawings, profiles) in a
        // folder of the run's, never Application Support.
        if args.dropFirst().contains(where: { $0.hasPrefix("--") && ($0.hasSuffix("-probe") || $0.hasSuffix("-bench")) }),
           (ProcessInfo.processInfo.environment["LIBERTTY_DATA_DIR"] ?? "").isEmpty {
            let socket = ProcessInfo.processInfo.environment["LIBERTTY_DAEMON_SOCKET"] ?? ""
            let dir = socket.isEmpty ? NSTemporaryDirectory() + "libertty-probe-\(getpid())" : (socket as NSString).deletingLastPathComponent
            setenv("LIBERTTY_DATA_DIR", dir, 1)
        }
        if args.contains("--resize-bench") { resizeBench() }
        if let i = args.firstIndex(of: "--session-bench"), i + 1 < args.count { sessionBench(file: args[i + 1]) }
        if let i = args.firstIndex(of: "--link-probe"), i + 1 < args.count { linkProbe(command: args[i + 1]) }
        if let i = args.firstIndex(of: "--command-probe"), i + 1 < args.count { commandProbe(shell: args[i + 1]) }
        if args.contains("--selection-probe") { selectionProbe() }
        if args.contains("--paste-probe") { pasteProbe() }
        if args.contains("--clear-probe") { clearProbe() }
        if args.contains("--scrollbar-probe") { scrollbarProbe() }
        if args.contains("--column-fit-probe") { columnFitProbe() }
        if args.contains("--git-probe") { gitProbe() }
        if let i = args.firstIndex(of: "--responsible-probe"), i + 1 < args.count {
            responsibleProbe(pid_t(args[i + 1]) ?? -1)
        }
        if args.contains("--ligature-config-probe") { ligatureConfigProbe() }
        if args.contains("--web-probe") { MainActor.assumeIsolated { webProbe() } }
        if args.contains("--kitty-reattach-probe") { kittyReattachProbe() }
        if args.contains("--kitty-key-probe") { kittyKeyProbe() }
        if let i = args.firstIndex(of: "--ui-probe"), i + 2 < args.count {
            MainActor.assumeIsolated { UIProbe.run(script: args[i + 1], output: args[i + 2]) }
        }
        if let i = args.firstIndex(of: "--screen-cover-probe"), i + 1 < args.count {
            MainActor.assumeIsolated { ScreenProbe.cover(seconds: Double(args[i + 1]) ?? 1.5) }
        }
        if let i = args.firstIndex(of: "--screen-probe"), i + 1 < args.count {
            MainActor.assumeIsolated { ScreenProbe.run(output: args[i + 1]) }
        }
        if args.contains("--resize-resync-probe") { resizeResyncProbe() }
        if args.contains("--slow-client-probe") { SlowClientProbe.run() }
        if args.contains("--layout-store-probe") { LayoutStoreProbe.run() }
        if let i = args.firstIndex(of: "--document-probe"), i + 2 < args.count {
            MainActor.assumeIsolated { documentProbe(args[i + 1], to: args[i + 2]) }
        }
        if args.contains("--web-serve-probe") { MainActor.assumeIsolated { webServeProbe() } }
        if let i = args.firstIndex(of: "--update-notes-probe"), i + 2 < args.count {
            MainActor.assumeIsolated { updateNotesProbe(feed: args[i + 1], to: args[i + 2]) }
        }
        if let i = args.firstIndex(of: "--remote-probe"), i + 1 < args.count { remoteProbe(host: args[i + 1]) }
        if let i = args.firstIndex(of: "--output-probe"), i + 1 < args.count { outputProbe(shell: args[i + 1]) }
        if let i = args.firstIndex(of: "--shell-probe"), i + 2 < args.count { shellProbe(shell: args[i + 1], input: args[i + 2]) }
        // `--parse-bench FILE [--cols N] [--rows N] [--seconds S]`: FILE fed
        // into a libghostty-vt terminal in a loop, with no pty, lock or
        // renderer; prints parse throughput. Next to vtebench's numbers it
        // separates the parser's cost from everything Libertty adds around it.
        guard let flag = args.firstIndex(of: "--parse-bench"), flag + 1 < args.count else { return }
        func value(_ name: String, _ fallback: Double) -> Double {
            guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) else { return fallback }
            return v
        }
        let cols = UInt16(value("--cols", 120)), rows = UInt16(value("--rows", 40))
        let seconds = value("--seconds", 3)
        guard let data = FileManager.default.contents(atPath: args[flag + 1]), !data.isEmpty else {
            FileHandle.standardError.write("parse-bench: cannot read \(args[flag + 1])\n".data(using: .utf8)!)
            exit(1)
        }

        var terminal: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &terminal, cols, rows) == GHOSTTY_SUCCESS, let terminal else { exit(1) }
        var lines = 10_000
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
        // `--scrollback-bytes N`: also cap history in bytes (libghostty's own default is 10000).
        if let i = args.firstIndex(of: "--scrollback-bytes"), i + 1 < args.count, var bytes = Int(args[i + 1]) {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes)
        } else {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, nil)
        }

        // Same chunking as the pty reader: 64 KiB writes.
        let chunk = 1 << 16
        var bytes = 0
        let start = Date()
        data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while Date().timeIntervalSince(start) < seconds {
                var offset = 0
                while offset < raw.count {
                    let n = min(chunk, raw.count - offset)
                    ghostty_terminal_vt_write(terminal, base + offset, n)
                    offset += n
                }
                bytes += raw.count
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "%.0f MB/s  (%d MB in %.2fs, %dx%d)", Double(bytes) / 1e6 / elapsed,
                     bytes / 1_000_000, elapsed, cols, rows))
        ghostty_terminal_free(terminal)
        exit(0)
    }

    final class Backdrop: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }
}
#endif
