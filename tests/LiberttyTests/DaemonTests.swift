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
        chmod(dir, 0o755)
        #expect(Wire.privacyProblem(dir)?.contains("open to other users") == true)
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
}
