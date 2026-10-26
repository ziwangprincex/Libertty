#if LIBERTTY_PROBES
import CGhosttyVt
import Foundation
import LiberttyCore

/// `Libertty --slow-client-probe`: a window that stops reading must hold up
/// nobody. A session floods 60 MB while a second client attached to it
/// reads nothing; the session's own window must see the flood end about as
/// soon as it does alone, and typing must still get through. Then the stuck
/// client reads again: one that can catch up gets the session's state as a
/// snapshot and live output after it; one that can't is hung up (a window
/// would redial). Before, liberttyd waited on it for up to 10 s per write,
/// holding the program and every other window meanwhile.
enum SlowClientProbe {
    static func run() -> Never {
        Persistence.setUp(wanted: true)
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "ok    slow-client \(what)" : "FAIL  slow-client \(what)")
            if !ok { failures += 1 }
        }

        guard let alone = flood(stuck: nil) else {
            print("slow-client: the flood never finished in a window alone")
            exit(1)
        }
        print("      alone: \(seconds(alone.elapsed)), typing reached the program in \(seconds(alone.typed))")
        alone.session.terminate()

        for catchUp in [true, false] {
            let kind = catchUp ? "catching up" : "without catch-up"
            guard let run = flood(stuck: catchUp), let stuck = run.stuck else {
                check(false, "\(kind): flood ended in the window")
                continue
            }
            print("      with a stuck client \(kind): \(seconds(run.elapsed)), typing in \(seconds(run.typed))")
            check(run.elapsed < alone.elapsed + 2, "\(kind): a stuck client holds nobody up")
            check(run.typed < 2, "\(kind): typing gets through during the flood")
            if catchUp {
                // The stuck client attached last, so its answers are the
                // ones that count — but it never sees the question while
                // it's skipping. The shell's cursor query must still be
                // answered, by liberttyd.
                check(answered(run), "\(kind): a query the stuck window never sees is still answered")
            }

            // The stuck client reads again.
            stuck.setReceiveTimeout(2)
            if catchUp {
                var snapshot: Data?
                let deadline = Date().addingTimeInterval(15)
                while snapshot == nil, Date() < deadline, let frame = stuck.receive() {
                    if frame.kind == .snapshot { snapshot = frame.payload }
                }
                let text = snapshot.flatMap(screen(of:)) ?? ""
                check(text.contains(marker), "\(kind): its snapshot has the flood's end")
                // Live again: what comes next reaches it as output (the
                // line discipline echoes typing).
                run.session.sendText("AFTER-SKIP")
                var live = Data()
                let until = Date().addingTimeInterval(5)
                while Date() < until, !String(decoding: live, as: UTF8.self).contains("AFTER-SKIP"),
                      let frame = stuck.receive() {
                    if frame.kind == .output { live.append(frame.payload) }
                }
                check(String(decoding: live, as: UTF8.self).contains("AFTER-SKIP"), "\(kind): live output follows it")
            } else {
                // Hung up: it reads what was on its way, then the end.
                var hungUp = false
                let deadline = Date().addingTimeInterval(15)
                while Date() < deadline {
                    guard stuck.receive() != nil else { hungUp = true; break }
                }
                check(hungUp, "\(kind): it's hung up (and would redial)")
            }
            stuck.close()
            run.session.terminate()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        print(failures == 0 ? "slow-client: all passed" : "slow-client: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// The flood's end: printed after it, and not in the command's own text.
    private static let marker = "FLOOD-42-DONE"

    /// Whether the session's shell got an answer to the cursor-position
    /// query (DSR 6) it asks right after the flood, while the window whose
    /// answers count is still skipping output and never sees the question.
    private static func answered(_ run: (session: TerminalSession, elapsed: Double, typed: Double,
                                         stuck: Connection?, report: String)) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: run.report, encoding: .utf8), text.contains("033") { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    /// A window's session floods; with `stuck` set, a client that attaches
    /// before it starts and then reads nothing (`true`: one that can take a
    /// catch-up snapshot). How long until the window shows the flood's end,
    /// and how long a line typed a second into the flood took to reach the
    /// program — which reads it while the flood runs in the background, so
    /// its arrival doesn't wait on any output.
    private static func flood(stuck catchUp: Bool?)
        -> (session: TerminalSession, elapsed: Double, typed: Double, stuck: Connection?, report: String)? {
        let typedFile = NSTemporaryDirectory() + "libertty-slow-client-\(getpid())-\(UUID().uuidString)"
        let report = typedFile + "-dsr"
        let session: TerminalSession
        let started = Date()
        do {
            session = try TerminalSession(size: GridSize(cols: 80, rows: 24, widthPx: 800, heightPx: 480))
            // After the flood, the shell asks where the cursor is (DSR 6)
            // and writes down the answer: the window whose answers count
            // may be one skipping output, which never sees the question.
            try session.start(command: "sleep 1.5; (yes LIBERTTY-FLOOD | head -c 30000000; echo FLOOD-$((40+2))-DONE) & "
                + "read -t 40 line; echo \"$line\" > \(typedFile); wait; "
                + "stty -echo raw; printf '\\033[6n'; dd bs=1 count=6 2>/dev/null | od -c > \(report); stty sane; sleep 60")
        } catch {
            print("slow-client: \(error)")
            return nil
        }
        defer { unlink(typedFile) }
        var stuck: Connection?
        if let catchUp {
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let id = session.persistentID, let c = DaemonAddress.local.connect() else { return nil }
            c.setBufferSizes(1 << 16)
            var request: [String: Any] = ["id": id]
            if catchUp { request["catchUp"] = true }
            c.send(.attach, json: request)
            c.setReceiveTimeout(5)
            guard c.receive()?.kind == .attached else { return nil }
            stuck = c  // and from here on, it reads nothing
        }
        // A second into the flood, a line is typed — through liberttyd's
        // `send`, which doesn't make our window the one whose answers count
        // (typing in it would): the stuck client stays that one.
        guard wait(10, for: "LIBERTTY-FLOOD", in: session), let id = session.persistentID else { return nil }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let typedAt = Date()
        _ = DaemonClient.request(.send, json: ["id": id, "text": "TYPED-OK\r"])
        var typed = Double.infinity
        guard wait(40, for: marker, in: session, meanwhile: {
            if typed.isInfinite, (try? String(contentsOfFile: typedFile, encoding: .utf8))?.contains("TYPED-OK") == true {
                typed = Date().timeIntervalSince(typedAt)
            }
        }) else { return nil }
        if typed.isInfinite, (try? String(contentsOfFile: typedFile, encoding: .utf8))?.contains("TYPED-OK") == true {
            typed = Date().timeIntervalSince(typedAt)
        }
        return (session, Date().timeIntervalSince(started), typed, stuck, report)
    }

    private static func wait(_ seconds: Double, for text: String, in session: TerminalSession,
                             meanwhile: () -> Void = {}) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if session.viewportText().lines.contains(where: { $0.contains(text) }) { return true }
            meanwhile()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return false
    }

    /// The screen a snapshot holds, as text.
    private static func screen(of snapshot: Data) -> String? {
        guard let terminal = Snapshots.decode(snapshot, trackContinuation: false) else { return nil }
        defer { ghostty_terminal_free(terminal) }
        return Snapshots.plainText(terminal, scrollback: false)
    }

    private static func seconds(_ t: Double) -> String { String(format: "%.2f s", t) }
}
#endif
