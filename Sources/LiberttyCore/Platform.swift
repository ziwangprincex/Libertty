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

// The C library's I/O calls under one name on every platform liberttyd runs
// on (macOS; Linux, on a remote host): `Darwin.write` there is `Musl.write`.
@inline(__always) func sysRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { read(fd, buffer, count) }
@inline(__always) func sysWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { write(fd, buffer, count) }
@inline(__always) func sysClose(_ fd: Int32) { _ = close(fd) }
@inline(__always) func sysShutdown(_ fd: Int32) {
    #if os(Linux)
    _ = shutdown(fd, Int32(SHUT_RDWR))
    #else
    _ = shutdown(fd, SHUT_RDWR)
    #endif
}

/// A monotonic clock in nanoseconds.
@inline(__always) func monotonicNanos() -> UInt64 {
    #if os(Linux)
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    #else
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    #endif
}

/// Reap `pid` when it exits (a background thread; no process event sources on Linux).
func reapWhenDone(_ pid: pid_t) {
    let thread = Thread {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
    thread.name = "libertty.reaper"
    thread.start()
}

// MARK: Without Foundation's NSString and friends (see the imports)

extension String {
    /// The path without its last component ("/a/b" → "/a").
    var parentPath: String {
        guard let slash = lastIndex(of: "/") else { return "" }
        return slash == startIndex ? "/" : String(self[..<slash])
    }

    func appendingPath(_ component: String) -> String {
        hasSuffix("/") ? self + component : self + "/" + component
    }
}

/// This program's own file.
func currentExecutablePath() -> String? {
    #if os(Linux)
    var buffer = [CChar](repeating: 0, count: 4096)
    let n = readlink("/proc/self/exe", &buffer, buffer.count - 1)
    return n > 0 ? String(cString: buffer) : nil
    #else
    return Bundle.main.executablePath
    #endif
}

func userHomeDirectory() -> String {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return home }
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
    return "/"
}

/// 2026-10-16T08:12:03Z, for log lines.
func utcTimestamp() -> String {
    var now = time(nil)
    var parts = tm()
    gmtime_r(&now, &parts)
    var buffer = [CChar](repeating: 0, count: 32)
    let n = strftime(&buffer, buffer.count, "%Y-%m-%dT%H:%M:%SZ", &parts)
    return n > 0 ? String(cString: buffer) : ""
}

func writeError(_ text: String) {
    var bytes = Array(text.utf8)
    _ = bytes.withUnsafeMutableBytes { sysWrite(2, $0.baseAddress!, $0.count) }
}

/// A failed system call's errno.
public struct SystemError: Error, CustomStringConvertible {
    public let code: Int32
    init(_ code: Int32) { self.code = code }
    public var description: String { String(cString: strerror(code)) }
}

#if os(Linux)
// What FoundationEssentials leaves out and the daemon needs, on the C
// library: a mutex, a thread, and JSON objects as dictionaries.

public final class NSLock: @unchecked Sendable {
    private var mutex = pthread_mutex_t()
    public init() { pthread_mutex_init(&mutex, nil) }
    deinit { pthread_mutex_destroy(&mutex) }
    public func lock() { pthread_mutex_lock(&mutex) }
    public func unlock() { pthread_mutex_unlock(&mutex) }
    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}

public enum QualityOfService { case userInteractive, userInitiated, utility, background, `default` }

public final class Thread: @unchecked Sendable {
    private let body: () -> Void
    public var name: String?
    public var qualityOfService = QualityOfService.default
    public init(block: @escaping () -> Void) { body = block }

    public func start() {
        let box = Unmanaged.passRetained(self)
        #if canImport(Musl)
        var thread: pthread_t?  // a pointer type in musl
        #else
        var thread = pthread_t()
        #endif
        pthread_create(&thread, nil, { raw in
            let me = Unmanaged<Thread>.fromOpaque(raw!).takeRetainedValue()
            me.body()
            return nil
        }, box.toOpaque())
        #if canImport(Musl)
        if let thread { pthread_detach(thread) }
        #else
        pthread_detach(thread)
        #endif
    }

    public static func sleep(forTimeInterval seconds: Double) { usleep(useconds_t(max(0, seconds) * 1_000_000)) }
}

public final class NSCondition: @unchecked Sendable {
    private var mutex = pthread_mutex_t()
    private var condition = pthread_cond_t()
    public init() {
        pthread_mutex_init(&mutex, nil)
        pthread_cond_init(&condition, nil)
    }
    deinit {
        pthread_cond_destroy(&condition)
        pthread_mutex_destroy(&mutex)
    }
    public func lock() { pthread_mutex_lock(&mutex) }
    public func unlock() { pthread_mutex_unlock(&mutex) }
    public func wait() { pthread_cond_wait(&condition, &mutex) }
    public func signal() { pthread_cond_signal(&condition) }
    public func broadcast() { pthread_cond_broadcast(&condition) }
}

/// JSON objects as [String: Any] (the wire protocol's control messages),
/// through FoundationEssentials' JSON coder.
public enum JSONSerialization {
    private enum Value: Codable {
        case null, bool(Bool), int(Int), double(Double), string(String), array([Value]), object([String: Value])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let i = try? c.decode(Int.self) { self = .int(i) }
            else if let d = try? c.decode(Double.self) { self = .double(d) }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else if let a = try? c.decode([Value].self) { self = .array(a) }
            else { self = .object(try c.decode([String: Value].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let b): try c.encode(b)
            case .int(let i): try c.encode(i)
            case .double(let d): try c.encode(d)
            case .string(let s): try c.encode(s)
            case .array(let a): try c.encode(a)
            case .object(let o): try c.encode(o)
            }
        }

        var any: Any {
            switch self {
            case .null: return Optional<Any>.none as Any
            case .bool(let b): return b
            case .int(let i): return i
            case .double(let d): return d
            case .string(let s): return s
            case .array(let a): return a.map(\.any)
            case .object(let o): return o.mapValues(\.any)
            }
        }

        init(_ any: Any) {
            switch any {
            case let b as Bool: self = .bool(b)
            case let i as Int: self = .int(i)
            case let i as Int32: self = .int(Int(i))
            case let i as UInt16: self = .int(Int(i))
            case let u as UInt64: self = .int(Int(u))
            case let d as Double: self = .double(d)
            case let s as String: self = .string(s)
            case let a as [Any]: self = .array(a.map(Value.init))
            case let o as [String: Any]: self = .object(o.mapValues(Value.init))
            default: self = .null
            }
        }
    }

    public static func jsonObject(with data: Data) throws -> Any {
        try JSONDecoder().decode(Value.self, from: data).any
    }

    public static func data(withJSONObject object: Any) throws -> Data {
        try JSONEncoder().encode(Value(object))
    }
}
#endif
