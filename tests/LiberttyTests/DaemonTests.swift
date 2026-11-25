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
}
