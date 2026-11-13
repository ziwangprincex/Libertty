import CPty
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
#if os(Linux)
import Dispatch
import FoundationEssentials  // not Foundation: on Linux that brings 45 MB of ICU
#else
import Foundation
#endif

/// What `libertty +daemon` and `+clients` ask liberttyd (the `admin` feature).
extension DaemonServer {
    /// The `clients` answer.
    struct Clients: Codable {
        var ok: Bool
        var clients: [ConnectedClient]
    }

    /// The file liberttyd's output goes to (Libertty starts it with its log
    /// as stdout and stderr); nil when that's no file (a terminal, /dev/null).
    static func logPath() -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard libertty_fd_path(STDERR_FILENO, &buffer, Int32(buffer.count)) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// The most a `log` answer carries.
    static let maxLogBytes = 1 << 20

    /// Its log from byte `from` on (at most maxLogBytes of it), or its last
    /// `lines` lines (all of it with neither, up to maxLogBytes from the
    /// end), and the offset the text ends at. A log that shrank since `from`
    /// (rotated, emptied) starts over at its beginning.
    public static func readLog(_ path: String, from: Int?, lines: Int?) -> (String, Int)? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { sysClose(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        let size = Int(st.st_size)
        var start: Int
        if let from {
            start = from <= size ? max(0, from) : 0
        } else {
            start = max(0, size - maxLogBytes)
        }
        let end = min(size, start + maxLogBytes)
        var bytes = [UInt8](repeating: 0, count: end - start)
        var got = 0
        while got < bytes.count {
            let n = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, $0.count - got, off_t(start + got)) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            got += n
        }
        bytes.removeLast(bytes.count - got)
        if from == nil, let lines, lines >= 0 {
            // The last `lines` of them: the text after the (lines + 1)th newline from the end,
            // not counting one that ends the file.
            var newlines = 0, cut = 0
            var i = bytes.count - 1
            if i >= 0, bytes[i] == 0x0A { i -= 1 }
            while i >= 0 {
                if bytes[i] == 0x0A {
                    newlines += 1
                    if newlines == lines { cut = i + 1; break }
                }
                i -= 1
            }
            if lines == 0 { cut = bytes.count }
            bytes.removeFirst(cut)
        } else if from == nil, start > 0, let first = bytes.firstIndex(of: 0x0A) {
            // Cut in the middle of a line: start at the next one.
            bytes.removeFirst(first + 1)
        }
        return (String(decoding: bytes, as: UTF8.self), start + got)
    }

    /// `restart`: a liberttyd from this one's own file, told to take over
    /// (as a newer build does), logging where this one does. Its pid, or nil.
    func restartFromOwnFile() -> pid_t? {
        guard let executable = currentExecutablePath() else { return nil }
        var env = ProcessInfo.processInfo.environment
        env["LIBERTTY_DAEMON_SOCKET"] = path
        // As it was started: answering for itself to macOS's privacy checks,
        // or (reached over ssh) under sshd's (see DaemonClient.spawn).
        let responsible: Int32 = env["LIBERTTY_DAEMON_RESPONSIBLE"] == "0" ? 0 : 1
        let words: [String] = ["liberttyd", "--takeover"]
        var argv = words.map { strdup($0) } + [nil]
        var envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        let pid = libertty_spawn_detached(executable, &argv, &envp, Self.logPath(), responsible)
        guard pid > 0 else {
            Self.log("restart: couldn't start \(executable): \(String(cString: strerror(errno)))")
            return nil
        }
        Self.log("restart asked; liberttyd[\(pid)] takes the sessions over")
        reapWhenDone(pid)
        return pid
    }
}
