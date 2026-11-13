import Foundation
import Darwin

/// `libertty +surface …`: the surface protocol (SurfaceProtocol) for shell
/// scripts — the sequences printed to the terminal the command runs in,
/// and events read back from it.
///
///     libertty +surface query
///     libertty +surface show ID [--rows N | --overlay POSITION [--cols N] [--rows N]] [--title T] [--update] ELEMENTS
///     libertty +surface remove ID
///     libertty +surface clear
///     libertty +surface read [--timeout S]
///
/// ELEMENTS is a JSON list of elements (or `-`: read from stdin).
enum SurfaceCLI {
    static func run(_ args: [String]) -> Int32 {
        guard let verb = args.first else { return usage() }
        var rest = Array(args.dropFirst())
        func option(_ name: String) -> String? {
            guard let i = rest.firstIndex(of: name), i + 1 < rest.count else { return nil }
            let v = rest[i + 1]
            rest.removeSubrange(i...(i + 1))
            return v
        }
        switch verb {
        case "query":
            guard let tty = openTTY() else { return fail("no terminal") }
            defer { close(tty) }
            guard let reply = ask(tty, "\u{1b}]7502;q\u{7}", prefix: "\u{1b}]7502;q;", timeout: 0.5) else { return 1 }
            print(reply)
            return 0
        case "show":
            let title = option("--title") ?? ""
            let overlay = option("--overlay")
            let cols = option("--cols").flatMap(Int.init)
            let rows = option("--rows").flatMap(Int.init)
            // Again, changed: where it is stays, no rows printed for it.
            let update = rest.contains("--update")
            rest.removeAll { $0 == "--update" }
            guard rest.count == 2, SurfaceProtocol.isID(rest[0]) else { return usage() }
            let source = rest[1] == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : rest[1]
            guard let data = source.data(using: .utf8), let elements = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                return fail("ELEMENTS is a JSON list, e.g. '[{\"type\":\"text\",\"text\":\"hi\"}]'")
            }
            var spec: [String: Any] = ["id": rest[0], "title": title, "elements": elements]
            if let overlay {
                spec["placement"] = "overlay"
                spec["position"] = overlay
                if let cols { spec["cols"] = cols }
                if let rows { spec["rows"] = rows }
            } else {
                let n = max(1, min(SurfaceProtocol.maxInlineRows, rows ?? 4))
                spec["rows"] = n
                // Its rows, blank, first: the card sits over them.
                if !update { write(String(repeating: "\n", count: n)) }
            }
            guard let json = try? JSONSerialization.data(withJSONObject: spec) else { return fail("bad elements") }
            write("\u{1b}]7502;s;b64:\(json.base64EncodedString())\u{7}")
            return 0
        case "remove":
            guard rest.count == 1, SurfaceProtocol.isID(rest[0]) else { return usage() }
            write("\u{1b}]7502;d;\(rest[0])\u{7}")
            return 0
        case "clear":
            write("\u{1b}]7502;c\u{7}")
            return 0
        case "read":
            let timeout = option("--timeout").flatMap(Double.init)
            guard let tty = openTTY() else { return fail("no terminal") }
            defer { close(tty) }
            guard let body = read(tty, prefix: "\u{1b}]7502;e;", timeout: timeout) else { return 124 }
            guard body.hasPrefix("b64:"), let data = Data(base64Encoded: String(body.dropFirst(4))) else { return fail("a bad event") }
            print(String(decoding: data, as: UTF8.self))
            return 0
        default:
            return usage()
        }
    }

    private static func usage() -> Int32 {
        fail("usage: libertty +surface query | show ID [--rows N | --overlay POSITION [--cols N] [--rows N]] [--title T] ELEMENTS | remove ID | clear | read [--timeout S]")
        return 2
    }

    @discardableResult
    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data(("libertty: " + message + "\n").utf8))
        return 1
    }

    /// To the terminal: stdout when it's one, else the controlling tty.
    private static func write(_ s: String) {
        let bytes = Array(s.utf8)
        if isatty(1) != 0 {
            _ = bytes.withUnsafeBytes { Darwin.write(1, $0.baseAddress, $0.count) }
        } else if let tty = openTTY() {
            _ = bytes.withUnsafeBytes { Darwin.write(tty, $0.baseAddress, $0.count) }
            close(tty)
        }
    }

    private static func openTTY() -> Int32? {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY)
        return fd >= 0 ? fd : nil
    }

    /// Writes `request` and waits for a reply starting with `prefix`, the
    /// terminal in cbreak (unechoed) for it.
    private static func ask(_ tty: Int32, _ request: String, prefix: String, timeout: Double) -> String? {
        rawly(tty) {
            let bytes = Array(request.utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(tty, $0.baseAddress, $0.count) }
            return frame(tty, prefix: prefix, timeout: timeout)
        }
    }

    private static func read(_ tty: Int32, prefix: String, timeout: Double?) -> String? {
        rawly(tty) { frame(tty, prefix: prefix, timeout: timeout) }
    }

    private static func rawly<T>(_ tty: Int32, _ body: () -> T) -> T {
        var old = termios()
        guard tcgetattr(tty, &old) == 0 else { return body() }
        var raw = old
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        tcsetattr(tty, TCSANOW, &raw)
        defer { tcsetattr(tty, TCSADRAIN, &old) }
        return body()
    }

    private static func frame(_ tty: Int32, prefix: String, timeout: Double?) -> String? {
        var buffer: [UInt8] = []
        let want = Array(prefix.utf8)
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            if let start = find(want, in: buffer), let end = buffer[(start + want.count)...].firstIndex(of: 7) {
                return String(decoding: buffer[(start + want.count)..<end], as: UTF8.self)
            }
            var pfd = pollfd(fd: tty, events: Int16(POLLIN), revents: 0)
            let wait = deadline.map { Int32(max(0, $0.timeIntervalSinceNow) * 1000) } ?? -1
            if let deadline, deadline.timeIntervalSinceNow <= 0 { return nil }
            guard poll(&pfd, 1, wait) > 0 else { if deadline != nil { return nil } else { continue } }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(tty, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer += chunk.prefix(n)
        }
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i..<(i + needle.count)].elementsEqual(needle) { return i }
        return nil
    }
}
