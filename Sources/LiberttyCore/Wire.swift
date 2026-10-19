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

/// The wire format between Libertty (and `libertty +…` commands) and liberttyd.
///
/// One Unix-domain stream socket per connection; a message is one frame:
///
///     u32 length (little-endian, of what follows) | u8 type | payload
///
/// Control payloads are JSON objects; output, input and replies are raw
/// bytes. A connection that creates or attaches a session is bound to it:
/// from then on it carries that session's output and input. Closing the
/// connection detaches; the session lives on.
public enum Wire {
    /// Bumped whenever messages change meaning. A daemon with another
    /// version hands its sessions to a new one (see `takeover`).
    public static let version = 1

    public enum Kind: UInt8 {
        // Client → daemon
        case hello = 1        // {version}
        case create = 2       // CreateRequest
        case attach = 3       // {id, catchUp?}
        case input = 4        // bytes the user typed
        case reply = 5        // the terminal's answers to queries
        case resize = 6       // u16 cols, rows, widthPx, heightPx
        case kill = 7         // {id?}: end a session (the bound one without id)
        case list = 8         // → result {sessions: [SessionInfo]}
        case capture = 9      // {id, scrollback, format?: plain|ansi|html} → result {text, format}
        case send = 10        // {id, text}: type into a session
        case configure = 11   // {scrollback}
        case takeover = 12    // a newer liberttyd asks for every session
        case shutdown = 13    // end every session and exit
        case ack = 14         // takeover lockstep: frame parsed, send the descriptor
        case wait = 15        // {id, until?: exit|prompt|idle, idleMs?} → result {ok, status | reached} once it
                              // ends, or its shell shows a prompt, or its output is quiet for idleMs
        case clear = 16       // {atPrompt}: ⌘K, done by liberttyd so every copy clears at one point
        case storeLayout = 17 // header {client, local?} | a Mac's window layout, opaque (empty: none) → result {ok}
        case loadLayout = 18  // {client, local?} → result: header {client} | that Mac's, else (not local) the latest host layout
        case events = 19      // {kinds?: [String]} → result {ok}, then `event` frames until the connection closes

        // Daemon → client
        case welcome = 101    // {version, build, pid, features?}
        case attached = 102   // u32 header length | header JSON {id, pid, cols, rows} | snapshot
        case output = 103     // program output
        case exited = 104     // {status}
        case result = 105     // {ok, error?, …}
        case handoff = 106    // takeover: header | snapshot, then the pty master by SCM_RIGHTS
        case snapshot = 107   // the session as it is now, in place of output the window fell too far
                              // behind to be sent (only to a window that attached with catchUp)
        case event = 108      // what happened in a session (`events`): {event, id, time, …}
    }

    public static let maxFrame = 256 << 20

    /// liberttyd's socket: `$LIBERTTY_DAEMON_SOCKET`, else liberttyd.sock in a private
    /// directory under the per-user temporary directory.
    public static var socketPath: String {
        if let path = ProcessInfo.processInfo.environment["LIBERTTY_DAEMON_SOCKET"], !path.isEmpty { return path }
        #if os(Linux)
        // A private directory in /tmp, as tmux does. Not $XDG_RUNTIME_DIR:
        // systemd deletes it when the last login session ends, which is
        // when Libertty's ssh connections close, and the socket with it.
        return "/tmp/libertty-\(getuid())/liberttyd.sock"
        #else
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        let tmp = n > 0 ? String(cString: buf) : NSTemporaryDirectory()
        return tmp.appendingPath("libertty/liberttyd.sock")
        #endif
    }

    /// Make the socket's directory, private to the user.
    public static func prepareDirectory(for path: String) {
        let dir = path.parentPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
}

/// Where a liberttyd is and how to reach it: the local socket, or one on
/// another machine through ssh (each connection is an ssh channel to
/// `liberttyd --bridge` there, see RemoteHost in the app).
public struct DaemonAddress: Sendable {
    /// The host's name as the user gave it; empty for this Mac.
    public let host: String
    private let dialer: @Sendable () -> Connection?

    public init(host: String, dial: @escaping @Sendable () -> Connection?) {
        self.host = host
        dialer = dial
    }

    /// This Mac's liberttyd (the socket is looked up at each dial).
    public static let local = DaemonAddress(host: "") { Connection.connect() }

    public var isRemote: Bool { !host.isEmpty }
    public func connect() -> Connection? { dialer() }
}

/// What a new session runs. The app computes all of it (environment, shell
/// integration), so liberttyd only spawns.
public struct CreateRequest: Codable, Sendable {
    public var id: String
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    public var cols: UInt16
    public var rows: UInt16
    public var widthPx: UInt16
    public var heightPx: UInt16
    public var scrollback: Int
    /// Start from liberttyd's own environment and add `environment` to it
    /// (another machine's liberttyd knows its PATH, HOME, …; the app doesn't).
    public var inheritEnvironment: Bool?
    /// The creating window takes a catch-up snapshot mid-stream (`snapshot`)
    /// if it falls too far behind; without it, it's hung up instead.
    public var catchUp: Bool?

    public init(id: String, executable: String, arguments: [String], environment: [String: String],
                workingDirectory: String, size: GridSize, scrollback: Int, inheritEnvironment: Bool = false) {
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        cols = size.cols
        rows = size.rows
        widthPx = size.widthPx
        heightPx = size.heightPx
        self.scrollback = scrollback
        self.inheritEnvironment = inheritEnvironment ? true : nil
    }
}

/// One line of `libertty +list-sessions`.
public struct SessionInfo: Codable, Sendable {
    public var id: String
    public var pid: Int32
    public var title: String
    public var workingDirectory: String
    public var cols: UInt16
    public var rows: UInt16
    /// Windows showing it right now.
    public var clients: Int
    public var created: Double
    public var command: String

    /// The local directory in an OSC 7 `file://host/path` report (or a bare path).
    public static func directory(fromPwd raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("file://") { return URL(string: raw)?.path }
        return raw.hasPrefix("/") ? raw : nil
    }
}

/// A framed, bidirectional connection. Sends may come from any thread (they
/// are serialized); receiving belongs to one thread at a time.
public final class Connection {
    public let fd: Int32
    private let sendLock = NSLock()
    private var closed = false
    private let closeLock = NSLock()

    public init(fd: Int32) { self.fd = fd }

    deinit {
        sysClose(fd)
        storage.deallocate()
    }

    /// Connect to liberttyd (nil if nothing listens there).
    public static func connect(to path: String = Wire.socketPath) -> Connection? {
        let fd = libertty_sock_connect(path)
        return fd >= 0 ? Connection(fd: fd) : nil
    }

    /// Hang up: a blocked receive returns, sends fail. The descriptor itself
    /// closes with the object, so a reader still using it never sees a reused number.
    public func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        sysShutdown(fd)
    }

    /// Give up after `seconds` blocked in one send (a hung peer), or never with 0.
    public func setSendTimeout(_ seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public func setReceiveTimeout(_ seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: suseconds_t((seconds - Double(Int(seconds))) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public func setBufferSizes(_ bytes: Int32) {
        var size = bytes
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    // MARK: Sending

    @discardableResult
    public func send(_ kind: Wire.Kind, _ payload: UnsafeRawBufferPointer) -> Bool {
        var header = [UInt8](repeating: 0, count: 5)
        let length = UInt32(payload.count + 1)
        withUnsafeBytes(of: length.littleEndian) { for i in 0..<4 { header[i] = $0[i] } }
        header[4] = kind.rawValue
        sendLock.lock()
        defer { sendLock.unlock() }
        if payload.count <= 1 << 14 {
            // One write for small messages (keystrokes, control).
            header.append(contentsOf: payload)
            return header.withUnsafeBytes { writeAll($0) }
        }
        return header.withUnsafeBytes { writeAll($0) } && writeAll(payload)
    }

    @discardableResult
    public func send(_ kind: Wire.Kind, _ data: Data = Data()) -> Bool {
        data.withUnsafeBytes { send(kind, $0) }
    }

    @discardableResult
    public func send(_ kind: Wire.Kind, json: [String: Any]) -> Bool {
        send(kind, (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8))
    }

    @discardableResult
    public func send<T: Encodable>(_ kind: Wire.Kind, encoding value: T) -> Bool {
        send(kind, (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }

    /// A header JSON and a binary body in one frame (attached, handoff).
    @discardableResult
    public func send(_ kind: Wire.Kind, header: [String: Any], body: UnsafeRawBufferPointer) -> Bool {
        send(kind, Self.headed(header, body: body))
    }

    /// The payload of a header-and-body frame: u32 header length, the
    /// header's JSON, the body.
    public static func headed(_ header: [String: Any], body: UnsafeRawBufferPointer) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: header)) ?? Data("{}".utf8)
        var frame = Data(capacity: 4 + json.count + body.count)
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(json)
        frame.append(contentsOf: body)
        return frame
    }

    /// Pass a descriptor (SCM_RIGHTS), serialized with the frames.
    public func sendDescriptor(_ descriptor: Int32) -> Bool {
        sendLock.lock()
        defer { sendLock.unlock() }
        return libertty_sock_send_fd(fd, descriptor) == 0
    }

    private func writeAll(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard var p = bytes.baseAddress else { return true }
        var left = bytes.count
        while left > 0 {
            let n = sysWrite(fd, p, left)
            if n > 0 {
                p += n
                left -= n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    // MARK: Receiving

    public struct Frame {
        public let kind: Wire.Kind
        public let payload: Data

        public var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        }

        public func decode<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: payload) }

        /// Split an attached/handoff payload into its header and body.
        public var headerAndBody: ([String: Any], Data)? {
            guard payload.count >= 4 else { return nil }
            let n = Int(payload.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
            guard 4 + n <= payload.count else { return nil }
            let base = payload.startIndex
            let header = (try? JSONSerialization.jsonObject(with: payload[(base + 4)..<(base + 4 + n)])) as? [String: Any] ?? [:]
            return (header, Data(payload[(base + 4 + n)...]))
        }
    }

    // Received bytes not yet consumed are storage[head..<tail].
    private var storage = UnsafeMutableRawPointer.allocate(byteCount: 1 << 19, alignment: 16)
    private var capacity = 1 << 19
    private var head = 0
    private var tail = 0

    /// Block until a whole frame arrives; nil when the peer is gone (or on a
    /// timeout set with `setReceiveTimeout`).
    public func receive() -> Frame? {
        while true {
            if let (kind, payload) = nextBuffered() {
                return Frame(kind: kind, payload: Data(payload))
            }
            if !fill() { return nil }
        }
    }

    /// Block until at least one frame is in, then hand over every complete
    /// frame buffered, without copying (the pointer is valid during the call).
    /// Returns false once the peer is gone.
    public func receiveFrames(_ body: (Wire.Kind, UnsafeRawBufferPointer) -> Void) -> Bool {
        var any = false
        while true {
            while let (kind, payload) = nextBuffered() {
                body(kind, payload)
                any = true
            }
            if any { return true }
            if !fill() { return false }
        }
    }

    /// Read whatever is available (blocking once). False at end of stream.
    private func fill() -> Bool {
        if head == tail {
            head = 0
            tail = 0
        }
        // Room for the frame in progress (and a decent read).
        var needed = 1 << 16
        if tail - head >= 4 {
            let length = Int(UInt32(littleEndian: storage.loadUnaligned(fromByteOffset: head, as: UInt32.self)))
            needed = max(needed, 4 + min(length, Wire.maxFrame) - (tail - head))
        }
        if capacity - tail < needed {
            if head > 0 {
                memmove(storage, storage + head, tail - head)
                tail -= head
                head = 0
            }
            if capacity - tail < needed {
                let grown = max(capacity * 2, tail + needed)
                let bigger = UnsafeMutableRawPointer.allocate(byteCount: grown, alignment: 16)
                bigger.copyMemory(from: storage, byteCount: tail)
                storage.deallocate()
                storage = bigger
                capacity = grown
            }
        }
        var n = 0
        repeat { n = sysRead(fd, storage + tail, capacity - tail) } while n < 0 && errno == EINTR
        guard n > 0 else { return false }
        tail += n
        return true
    }

    private func nextBuffered() -> (Wire.Kind, UnsafeRawBufferPointer)? {
        while tail - head >= 5 {
            let length = Int(UInt32(littleEndian: storage.loadUnaligned(fromByteOffset: head, as: UInt32.self)))
            guard length >= 1, length <= Wire.maxFrame else {
                // Garbage: hang up; the caller sees the end of the stream next.
                head = tail
                sysShutdown(fd)
                return nil
            }
            guard tail - head >= 4 + length else { return nil }
            let kindByte = storage.load(fromByteOffset: head + 4, as: UInt8.self)
            let payload = UnsafeRawBufferPointer(start: storage + head + 5, count: length - 1)
            head += 4 + length
            if let kind = Wire.Kind(rawValue: kindByte) { return (kind, payload) }
        }
        return nil
    }

    /// Whether received bytes are still waiting to be parsed (a passed
    /// descriptor can only be taken when none are).
    public var hasBufferedBytes: Bool { tail > head }

    /// Receive a passed descriptor. Only valid when no frame bytes are
    /// buffered beyond the point the peer sent it.
    public func receiveDescriptor() -> Int32? {
        let fd = libertty_sock_recv_fd(self.fd)
        return fd >= 0 ? fd : nil
    }
}
