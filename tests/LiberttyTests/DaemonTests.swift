import Foundation
import Testing
import CPty
@testable import LiberttyCore

/// liberttyd's own machinery: the ptys it spawns programs on, its sessions,
/// the files it keeps beside its socket.
struct DaemonTests {
    /// Everything a program on a new pty prints, until it exits.
    private func run(_ arguments: [String]) throws -> String {
        let queue = DispatchQueue(label: "test.pty")
        let pty = try PTY(executable: arguments[0], arguments: arguments, environment: ["PATH": "/bin:/usr/bin"],
                          workingDirectory: "/", size: GridSize(cols: 200, rows: 24, widthPx: 0, heightPx: 0), queue: queue)
        let ended = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var output = Data()
        pty.onOutput = { output.append($0.baseAddress!, count: $0.count) }
        pty.onExit = { _ in ended.signal() }
        pty.startReading()
        #expect(ended.wait(timeout: .now() + 10) == .success)
        return queue.sync { String(decoding: output, as: UTF8.self) }
    }

    /// A program on a pty gets the terminal and nothing else of ours: not a
    /// descriptor opened without close-on-exec, nor another pane's pty
    /// caught between its openpty and its close-on-exec (which would keep
    /// that pane from seeing its own shell exit).
    @Test func aPtyProgramInheritsOnlyItsTerminal() throws {
        var ends: [Int32] = [-1, -1]
        #expect(pipe(&ends) == 0)
        let stray: Int32 = 200
        #expect(dup2(ends[1], stray) == stray)
        defer {
            close(stray)
            ends.forEach { close($0) }
        }
        let listed = try run(["/bin/ls", "/dev/fd"])
        let open = Set(listed.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) })
        #expect(open.isSuperset(of: [0, 1, 2]))
        #expect(!open.contains(stray))
    }

    /// liberttyd's own directory (in /tmp on Linux) must be its user's
    /// alone: one another user made first, or a link, isn't used.
    @Test func itsDirectoryIsPrivate() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("libertty-dir-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let dir = base + "/mine"
        #expect(mkdir(base, 0o700) == 0 && mkdir(dir, 0o700) == 0)
        #expect(Wire.privacyProblem(dir) == nil)
        // Others may look in: made private.
        chmod(dir, 0o755)
        #expect(Wire.privacyProblem(dir) == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? Int == 0o700)
        // Others may write in it (and may have left a socket or a link there): not used.
        chmod(dir, 0o777)
        #expect(Wire.privacyProblem(dir)?.contains("other users may write") == true)
        chmod(dir, 0o700)
        let link = base + "/link"
        #expect(symlink(dir, link) == 0)
        #expect(Wire.privacyProblem(link)?.contains("isn't a directory") == true)
        #expect(Wire.privacyProblem(base + "/none") != nil)
        // Another user's: the root directory, say.
        #expect(Wire.privacyProblem("/")?.contains("another user") == true)
        // A socket chosen with $LIBERTTY_DAEMON_SOCKET: its folder as it is.
        #expect(Wire.prepareDirectory(for: "/tmp/libertty-test.sock") == nil)
    }

    /// A session as liberttyd makes one, running `arguments`.
    private func session(_ arguments: [String]) throws -> DaemonSession {
        let request = CreateRequest(id: UUID().uuidString, executable: arguments[0], arguments: arguments,
                                    environment: ["PATH": "/bin:/usr/bin"], workingDirectory: "/",
                                    size: GridSize(cols: 80, rows: 24, widthPx: 0, heightPx: 0), scrollback: 1000)
        return try DaemonSession(request: request)
    }

    /// A window's connection and its other end (no SIGPIPE, as liberttyd's own).
    private func pair() -> (Connection, Connection) {
        var fds: [Int32] = [0, 0]
        precondition(libertty_socketpair(&fds) == 0)
        return (Connection(fd: fds[0]), Connection(fd: fds[1]))
    }

    /// A program that ends at once is still heard ending: nothing of it is
    /// read before liberttyd has the session (`onEnd` set), or it would stay
    /// listed for good, and liberttyd never go idle.
    @Test func aProgramThatEndsAtOnceIsHeard() throws {
        let s = try session(["/usr/bin/true"])
        // Gone by now; liberttyd only hears it once the session is started.
        Thread.sleep(forTimeInterval: 0.3)
        let ended = DispatchSemaphore(value: 0)
        s.onEnd = { _ in ended.signal() }
        s.start()
        #expect(ended.wait(timeout: .now() + 5) == .success)
    }

    /// Two windows showing one session close their panes at once: one lets
    /// go, the other ends it. Never both letting go, the program running on
    /// with no window.
    @Test func mirrorsClosingTogetherEndIt() throws {
        let rounds = 20
        let ended = DispatchSemaphore(value: 0)
        var held: [(session: DaemonSession, windows: [Connection], peers: [Connection])] = []
        for _ in 0..<rounds {
            let s = try session(["/bin/sleep", "30"])
            s.onEnd = { _ in ended.signal() }
            let (a, peerA) = pair(), (b, peerB) = pair()
            s.attach(a, sendSnapshot: false, catchUp: true)
            s.attach(b, sendSnapshot: false, catchUp: true)
            s.start()
            held.append((s, [a, b], [peerA, peerB]))
        }
        for (s, windows, _) in held {
            DispatchQueue.concurrentPerform(iterations: 2) { s.close(from: windows[$0]) }
        }
        for _ in 0..<rounds { #expect(ended.wait(timeout: .now() + 5) == .success) }
    }

    /// Windows resizing at once: the program's pty ends at the size
    /// liberttyd says it has, never at one it replaced meanwhile.
    @Test func resizesAtOnceAgree() throws {
        let s = try session(["/bin/sleep", "30"])
        let ended = DispatchSemaphore(value: 0)
        s.onEnd = { _ in ended.signal() }
        let pairs = (0..<6).map { _ in pair() }
        let windows = pairs.map(\.0)
        defer {
            // Ended before the windows hang up: nothing writes to one gone.
            s.terminate()
            _ = ended.wait(timeout: .now() + 5)
            pairs.forEach { $0.0.close(); $0.1.close() }
        }
        windows.forEach { s.attach($0, sendSnapshot: false, catchUp: true) }
        s.start()
        guard let (_, master) = s.guardianCopy() else { Issue.record("no pty"); return }
        defer { close(master) }
        for round in 0..<2000 {
            DispatchQueue.concurrentPerform(iterations: windows.count) { i in
                let cols = UInt16(40 + i * 30 + round % 20)
                s.resize(GridSize(cols: cols, rows: UInt16(20 + i), widthPx: 0, heightPx: 0), from: windows[i])
            }
            var ws = winsize()
            #expect(ioctl(master, TIOCGWINSZ, &ws) == 0)
            let info = s.info()
            #expect(ws.ws_col == info.cols && ws.ws_row == info.rows, "round \(round)")
            if ws.ws_col != info.cols { break }
        }
    }
}
