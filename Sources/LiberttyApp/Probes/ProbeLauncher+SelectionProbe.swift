#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --selection-probe`: drag-select past the top edge (autoscroll),
    /// shift-click to extend, ⌥-drag a block; prints what got selected.
    static func selectionProbe() -> Never {
        do {
            let session = try TerminalSession(size: GridSize(cols: 20, rows: 5, widthPx: 200, heightPx: 100))
            try session.start(command: "for i in $(seq 1 30); do echo line$i; done; sleep 2")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            func at(_ col: Int, _ row: Int, y: Double? = nil) -> TerminalSession.Pointer {
                .init(col: col, row: row, positionPx: CGPoint(x: Double(col * 10 + 5), y: y ?? Double(row * 20 + 10)),
                      cellWidthPx: 10, paddingLeftPx: 0, surfaceHeightPx: 100)
            }
            func show(_ label: String) {
                print(label + ": " + (session.selectedText() ?? "(none)").replacingOccurrences(of: "\n", with: " | "))
            }
            // Screen now: line27..line30 and an empty last row. Drag from line29 up past the top.
            session.selectionGesture(.press, at(6, 2))
            let direction = session.selectionGesture(.drag, at(0, -1, y: -15))
            print("autoscroll: \(direction)")
            for _ in 0..<3 { session.selectionAutoscroll(direction, rows: 1, at(0, -1, y: -15), rectangle: false) }
            session.selectionGesture(.release, at(0, 0))
            show("drag up + 3 ticks")
            session.scrollToBottom()
            session.selectionGesture(.press, at(0, 1))
            session.selectionGesture(.drag, at(5, 1))
            session.selectionGesture(.release, at(5, 1))
            _ = session.extendSelection(to: at(3, 3))
            show("shift-click extend")
            session.selectionGesture(.press, at(4, 0))
            session.selectionGesture(.drag, at(5, 2), rectangle: true)
            session.selectionGesture(.release, at(5, 2))
            show("rectangle cols 4-5")
            exit(0)
        } catch {
            print("selection-probe: \(error)")
            exit(1)
        }
    }
}
#endif
