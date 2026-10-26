#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --paste-probe [--persist]`: paste 2 MB into a program reading the
    /// pty raw; it must receive every byte (the pty fills up and the writer
    /// waits on EAGAIN, many times over).
    static func pasteProbe() -> Never {
        Persistence.setUp(wanted: CommandLine.arguments.contains("--persist"))
        do {
            let session = try TerminalSession(size: GridSize(cols: 60, rows: 5, widthPx: 600, heightPx: 100))
            try session.start(command: "stty raw -echo; head -c 2000000 | wc -c; sleep 2")
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let started = Date()
            _ = session.paste(String(repeating: "a", count: 2_000_000), allowUnsafe: true)
            var text = ""
            while Date().timeIntervalSince(started) < 10 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                session.selectAll()
                text = session.selectedText() ?? ""
                if text.contains("2000000") { break }
            }
            let count = text.split(whereSeparator: \.isWhitespace).first { Int($0) != nil } ?? "nothing"
            print(String(format: "pasted 2000000 bytes, program read %@ (%.2fs, %@)", String(count),
                         Date().timeIntervalSince(started), Persistence.enabled ? "via liberttyd" : "local pty"))
            exit(0)
        } catch {
            print("paste-probe: \(error)")
            exit(1)
        }
    }
}
#endif
