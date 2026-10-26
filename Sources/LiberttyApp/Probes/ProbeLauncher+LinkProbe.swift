#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --link-probe COMMAND`: run COMMAND in a 40-column session and
    /// print every distinct link found at any cell (link detection test).
    static func linkProbe(command: String) -> Never {
        do {
            let session = try TerminalSession(size: GridSize(cols: 40, rows: 10, widthPx: 0, heightPx: 0))
            try session.start(workingDirectory: FileManager.default.currentDirectoryPath, command: command + "; sleep 1")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            var seen: [String] = []
            for row in 0..<10 {
                for col in 0..<40 {
                    guard let link = session.link(atCol: col, row: row) else { continue }
                    let key = "\(link.explicit ? "osc8" : "text") \(link.url)\(link.line.map { " line \($0)" } ?? "")\(link.column.map { " col \($0)" } ?? "") " + link.spans.map { "\($0.row):\($0.columns.lowerBound)-\($0.columns.upperBound)" }.joined(separator: ",")
                    if !seen.contains(key) { seen.append(key) }
                }
            }
            seen.forEach { print($0) }
            exit(0)
        } catch {
            print("link-probe: \(error)")
            exit(1)
        }
    }
}
#endif
