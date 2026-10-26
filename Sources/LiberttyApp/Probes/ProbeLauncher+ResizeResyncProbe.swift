#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --resize-resync-probe`: resizing a session in liberttyd that
    /// runs on the alternate screen must be followed, once the size settles,
    /// by the daemon re-sending its screen to every window (painted over
    /// theirs cleared). A window resizes its own copy at its own moment
    /// while the program's output — drawn for the old size — is in flight,
    /// so the copies can drift apart, and a full-screen program repaints
    /// only what it thinks changed (GoRex's race and its fix). A plain
    /// shell reflows the same on both sides and gets nothing.
    static func resizeResyncProbe() -> Never {
        Persistence.setUp(wanted: true)
        var failures = 0
        let prefix = Data("\u{1b}[?1049h\u{1b}[H\u{1b}[2J".utf8)
        /// What a resize brought back: no repaint, or one that does or
        /// doesn't paint exactly the session's screen on a cleared terminal
        /// of the new size — what a window does with it.
        enum Outcome { case none, right, wrong, failed }
        // A second client attached by id, which asks for the resize and
        // watches what arrives back.
        func watchResize(of command: String) -> Outcome {
            do {
                let session = try TerminalSession(size: GridSize(cols: 40, rows: 10, widthPx: 640, heightPx: 200))
                try session.start(command: command + "; sleep 20")
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                guard let id = session.persistentID,
                      let c = DaemonAddress.local.connect() else { return .failed }
                defer {
                    c.close()
                    session.terminate()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                }
                c.setBufferSizes(1 << 18)
                c.send(.attach, json: ["id": id])
                c.setReceiveTimeout(5)
                guard c.receive()?.kind == .attached else { return .failed }
                c.setReceiveTimeout(0.3)
                var payload = Data(capacity: 8)
                for v in [UInt16(20), UInt16(5), UInt16(320), UInt16(100)] {
                    withUnsafeBytes(of: v.littleEndian) { payload.append(contentsOf: $0) }
                }
                c.send(.resize, payload)
                // The repaint goes out 150 ms after the resize settles.
                let deadline = Date().addingTimeInterval(1.0)
                var repaint: Data?
                while repaint == nil, Date() < deadline {
                    guard let frame = c.receive() else { continue }
                    if frame.kind == .output, frame.payload.starts(with: prefix) { repaint = frame.payload }
                }
                guard let repaint else { return .none }
                guard repaint.range(of: Data("GHOSTSNP".utf8)) == nil else { return .wrong }  // a binary snapshot
                var fresh: GhosttyTerminal?
                guard ghostty_terminal_new(nil, &fresh, 20, 5) == GHOSTTY_SUCCESS, let fresh else { return .failed }
                defer { ghostty_terminal_free(fresh) }
                repaint.withUnsafeBytes { ghostty_terminal_vt_write(fresh, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
                let painted = Snapshots.plainText(fresh, scrollback: false)
                let theirs = DaemonClient.request(.capture, json: ["id": id, "scrollback": false])?.json["text"] as? String
                if painted != theirs { print("      painted: \(painted.debugDescription)\n      session: \((theirs ?? "").debugDescription)") }
                return painted == theirs && painted.contains("ALT") ? .right : .wrong
            } catch {
                print("resize-resync: \(error)")
                return .failed
            }
        }
        switch watchResize(of: "printf 'MARK\\033[?1049h\\033[2;3HALT\\033[1mBOLD\\033[0m\\033[4;1Hrow4'") {
        case .right: print("ok    resize-resync alternate screen repainted as the session has it")
        case .wrong: print("FAIL  resize-resync alternate screen: the repaint doesn't paint the session's screen"); failures += 1
        case .none, .failed: print("FAIL  resize-resync alternate screen: no repaint"); failures += 1
        }
        if watchResize(of: "printf 'MARK'") == .none {
            print("ok    resize-resync plain shell")
        } else {
            print("FAIL  resize-resync plain shell")
            failures += 1
        }
        print(failures == 0 ? "resize-resync: all passed" : "resize-resync: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
