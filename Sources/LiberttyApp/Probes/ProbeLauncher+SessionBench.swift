#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --session-bench FILE [--mb N] [--persist]`: a program writes FILE
    /// over and over (N MB in all) and a windowless session parses it, as a
    /// window would but without drawing. With --persist the bytes go through
    /// liberttyd (pty → liberttyd → socket → this replica), else straight from the pty.
    static func sessionBench(file: String) -> Never {
        let args = CommandLine.arguments
        let mb = args.firstIndex(of: "--mb").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 200
        Persistence.setUp(wanted: args.contains("--persist"))
        final class Waiter: TerminalSessionDelegate {
            var exited = false
            func sessionNeedsRender(_ session: TerminalSession) {}
            func sessionTitleChanged(_ session: TerminalSession, title: String) {}
            func sessionBell(_ session: TerminalSession) {}
            func sessionProgramStatusChanged(_ session: TerminalSession) {}
            func sessionExited(_ session: TerminalSession, status: Int32) { exited = true }
        }
        do {
            let session = try TerminalSession(size: GridSize(cols: 120, rows: 40, widthPx: 1920, heightPx: 1240))
            let waiter = Waiter()
            session.delegate = waiter
            // One ~20 MB file, so the writer isn't a thousand `cat` launches.
            guard let one = FileManager.default.contents(atPath: file), !one.isEmpty else { throw TerminalError.libghostty("can't read \(file)") }
            var chunk = Data()
            while chunk.count < 20_000_000 { chunk.append(one) }
            let big = FileManager.default.temporaryDirectory.appendingPathComponent("libertty-bench-\(getpid()).bin")
            try chunk.write(to: big)
            defer { try? FileManager.default.removeItem(at: big) }
            let size = chunk.count
            let repeats = mb * 1_000_000 / size + 1
            let command = "for i in $(seq \(repeats)); do cat \(ShellQuote.quote(big.path)); done"
            let start = Date()
            try session.start(command: command)
            while !waiter.exited { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            let elapsed = Date().timeIntervalSince(start)
            let bytes = repeats * size
            print(String(format: "%@: %.0f MB/s (%d MB in %.2fs)", Persistence.enabled ? "via liberttyd" : "local pty",
                         Double(bytes) / 1e6 / elapsed, bytes / 1_000_000, elapsed))
            try? FileManager.default.removeItem(at: big)
            exit(0)
        } catch {
            print("session-bench: \(error)")
            exit(1)
        }
    }
}
#endif
