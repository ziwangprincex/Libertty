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

public struct GridSize: Equatable, Sendable {
    public var cols: UInt16
    public var rows: UInt16
    public var widthPx: UInt16
    public var heightPx: UInt16

    public init(cols: UInt16, rows: UInt16, widthPx: UInt16, heightPx: UInt16) {
        self.cols = cols
        self.rows = rows
        self.widthPx = widthPx
        self.heightPx = heightPx
    }
}

/// Where a terminal's bytes come from and go to: a pty of our own (`PTY`), or
/// a session liberttyd keeps (`RemotePTY`). Callbacks arrive on the queue given
/// at creation.
public protocol TerminalBackend: AnyObject {
    var pid: pid_t { get }
    /// Called with output, in order, possibly many reads coalesced.
    var onOutput: ((UnsafeBufferPointer<UInt8>) -> Void)? { get set }
    /// Called once, after the last output, with the program's wait status.
    var onExit: ((Int32) -> Void)? { get set }
    /// What the user typed or pasted.
    func write(_ data: Data)
    /// The terminal's answers to the program's queries (device attributes,
    /// cursor reports): with several windows on one session only one answers.
    func writeReply(_ data: Data)
    func resize(_ size: GridSize)
    /// Whether something other than the shell owns the terminal right now.
    var hasForegroundProgram: Bool { get }
    /// End the program (closing its pane).
    func terminate()
    /// The window is going away but the program may live on: let go of it.
    func detach()
    /// ⌘K. True when the backend does it (liberttyd: it clears its copy and
    /// sends every window the same clear at the same point of the output);
    /// false when the window must clear its own terminal.
    func clear(atPrompt: Bool) -> Bool
}

extension TerminalBackend {
    public func clear(atPrompt: Bool) -> Bool { false }
}

/// A child process on a pseudo-terminal.
///
/// Output flows reader thread → `ByteQueue` → `queue`, so reading the pty and
/// parsing what it produced run in parallel (Tern's design).
/// `onOutput` and `onExit` are called on `queue` once `startReading()` is
/// called; writes are serialized on a private queue so a large paste never
/// blocks the caller.
public final class PTY: TerminalBackend {
    public let pid: pid_t
    public var master: Int32 { fd.raw }

    public var onOutput: ((UnsafeBufferPointer<UInt8>) -> Void)?
    public var onExit: ((Int32) -> Void)?

    private let fd: FileDescriptor
    private let wakeWrite: Int32
    private let wakeRead: Int32
    private var wakeClosed = false
    private var reading = false
    private let writeQueue = DispatchQueue(label: "libertty.pty.write", qos: .userInteractive)
    private let queue: DispatchQueue
    private var exited = false
    /// Set by `release()`: the reader stops without reaping the child.
    private var released = false
    private var releaseDone: DispatchSemaphore?

    public convenience init(executable: String, arguments: [String], environment: [String: String],
                            workingDirectory: String?, size: GridSize, queue: DispatchQueue) throws {
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var master: Int32 = -1
        let pid = libertty_pty_spawn(executable, &argv, &envp, workingDirectory,
                                  size.cols, size.rows, size.widthPx, size.heightPx, &master)
        guard pid > 0 else { throw SystemError(errno) }
        try self.init(adopting: master, pid: pid, queue: queue)
    }

    /// Take over a pty master someone else opened (a previous liberttyd handing
    /// its sessions to a new one). `pid` may not be our child.
    public init(adopting master: Int32, pid: pid_t, queue: DispatchQueue) throws {
        self.pid = pid
        self.queue = queue
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        fd = FileDescriptor(master)

        // Closing the write end wakes the reader so it can stop.
        var wake: [Int32] = [-1, -1]
        guard pipe(&wake) == 0 else { throw SystemError(errno) }
        for end in wake { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        wakeWrite = wake[1]

        wakeRead = wake[0]
    }

    /// Begin delivering output; set `onOutput` and `onExit` first.
    public func startReading() {
        guard !reading else { return }
        reading = true
        let bytes = ByteQueue()
        let queue = self.queue
        let reader = PTYReader(fd: fd, wakeRead: wakeRead, queue: bytes) { [weak self] in
            queue.async { [weak self] in self?.drain(bytes) ?? bytes.discardAll() }
        }
        let thread = Thread { reader.run() }
        thread.name = "libertty.pty.reader"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    deinit {
        if !released { terminate() }
        closeWake()
        if !reading { close(wakeRead) }
    }

    private func closeWake() {
        guard !wakeClosed else { return }
        wakeClosed = true
        close(wakeWrite)
    }

    // MARK: Output (queue)

    private func drain(_ bytes: ByteQueue) {
        while true {
            switch bytes.take() {
            case .bytes(let chunk):
                chunk.withUnsafeBufferPointer { onOutput?($0) }
            case .closed:
                if released {
                    releaseDone?.signal()
                } else {
                    childClosed()
                }
                return
            case .idle:
                return
            }
        }
    }

    private func childClosed() {
        guard !exited else { return }
        exited = true
        var status: Int32 = 0
        // Not our child (adopted from another liberttyd): the status is unknown.
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { status = 0; break }
        }
        onExit?(status)
    }

    // MARK: Input

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        let fd = self.fd  // keeps the descriptor open until this write finishes
        writeQueue.async {
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let n = sysWrite(fd.raw, base + offset, raw.count - offset)
                    if n >= 0 {
                        offset += n
                    } else if errno == EAGAIN {
                        // The master is non-blocking: wait until the child reads.
                        var p = pollfd(fd: fd.raw, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&p, 1, -1)
                    } else if errno != EINTR {
                        return
                    }
                }
            }
        }
    }

    public func writeReply(_ data: Data) { write(data) }

    public func resize(_ size: GridSize) {
        _ = libertty_pty_resize(master, size.cols, size.rows, size.widthPx, size.heightPx)
    }

    public var hasForegroundProgram: Bool {
        let pgid = libertty_pty_foreground_pgid(master)
        return pgid > 0 && pgid != pid
    }

    public func terminate() {
        guard !exited, !released else { return }
        kill(pid, SIGHUP)
    }

    /// A pty of our own can't outlive us: closing the window ends it.
    public func detach() { terminate() }

    /// Stop reading, deliver everything already read, and hand out the master
    /// descriptor (a duplicate the caller owns). The child keeps running.
    /// Must not be called on `queue`.
    public func release() -> Int32? {
        let done = DispatchSemaphore(value: 0)
        let alive: Bool = queue.sync {
            guard !exited else { return false }
            released = true
            releaseDone = done
            return true
        }
        guard alive else { return nil }
        closeWake()
        if reading { done.wait() }
        // The child may have exited meanwhile: then the output above was its last.
        let copy = dup(fd.raw)
        return copy >= 0 ? copy : nil
    }
}

/// Owns the pty master; it closes when the last owner (PTY, reader thread,
/// in-flight write) lets go, so a reused descriptor number is never touched.
private final class FileDescriptor {
    let raw: Int32
    init(_ raw: Int32) { self.raw = raw }
    deinit { close(raw) }
}

/// Bytes from a reader thread to the parser, with backpressure: the reader
/// waits while the parser is more than `limit` behind, so a program flooding
/// the terminal can't grow memory without bound.
final class ByteQueue {
    enum Taken {
        case bytes([UInt8])
        case closed
        case idle
    }

    static let limit = 1 << 20

    private let cond = NSCondition()
    private var pending: [UInt8] = []
    private var scheduled = false
    private var closed = false
    private var closeTaken = false

    /// Reader thread. Returns whether the consumer must be woken; repeated
    /// pushes before it runs wake it once.
    func push(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        while pending.count >= Self.limit { cond.wait() }
        pending.append(contentsOf: bytes)
        defer { scheduled = true }
        return !scheduled
    }

    /// Reader thread, after the last push. Returns whether to wake the consumer.
    func close() -> Bool {
        cond.lock()
        defer { cond.unlock() }
        closed = true
        defer { scheduled = true }
        return !scheduled
    }

    /// Consumer: everything queued so far, then `.closed` once, then `.idle`
    /// (after which the next push wakes the consumer again).
    func take() -> Taken {
        cond.lock()
        defer { cond.unlock() }
        if !pending.isEmpty {
            let chunk = pending
            pending = []
            pending.reserveCapacity(chunk.count)
            cond.broadcast()
            return .bytes(chunk)
        }
        if closed && !closeTaken {
            closeTaken = true
            return .closed
        }
        scheduled = false
        return .idle
    }

    /// The consumer is gone: keep the reader from blocking on backpressure.
    func discardAll() {
        while case .bytes = take() {}
    }
}

/// The reader thread's loop (Tern's):
/// - macOS hands out ~1 KiB per read(); sleeping in a blocking read for each
///   one caps throughput near 190 MB/s. Spinning on EAGAIN a few dozen times
///   before poll() keeps up with the writer (~390 MB/s measured).
/// - Under 1 KiB pending (typing, prompts) goes to the parser immediately, so
///   echo has no added latency. Bulk output is coalesced up to 64 KiB or 3 ms
///   so per-batch costs (lock, wake-up, render request) are amortized.
private final class PTYReader {
    private static let capacity = 1 << 16
    private static let flushBelow = 1 << 10
    private static let spins = 64
    private static let maxBatchNanos: UInt64 = 3_000_000

    private let fd: FileDescriptor
    private let wakeRead: Int32
    private let queue: ByteQueue
    private let wake: () -> Void

    init(fd: FileDescriptor, wakeRead: Int32, queue: ByteQueue, wake: @escaping () -> Void) {
        self.fd = fd
        self.wakeRead = wakeRead
        self.queue = queue
        self.wake = wake
    }

    func run() {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.capacity)
        defer {
            buffer.deallocate()
            close(wakeRead)
            if queue.close() { wake() }
        }
        let fd = self.fd.raw
        var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]

        func deliver(_ count: Int) {
            guard count > 0 else { return }
            if queue.push(UnsafeBufferPointer(start: buffer, count: count)) { wake() }
        }

        while true {
            fds[0].revents = 0
            fds[1].revents = 0
            if poll(&fds, 2, -1) < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 { return }  // the PTY was released
            if fds[0].revents & Int16(POLLNVAL) != 0 { return }

            var count = 0, misses = 0
            var batchStart: UInt64 = 0
            batch: while true {
                let n = read(fd, buffer + count, Self.capacity - count)
                if n > 0 {
                    if count == 0 { batchStart = monotonicNanos() }
                    count += n
                    misses = 0
                    if count == Self.capacity {
                        deliver(count)
                        count = 0
                    }
                    continue
                }
                if n == 0 || (errno != EAGAIN && errno != EINTR) {
                    // EOF, or EIO once every slave descriptor is closed.
                    deliver(count)
                    return
                }
                if errno == EINTR { continue }

                // EAGAIN: nothing right now.
                if count < Self.flushBelow { break batch }
                misses += 1
                if misses <= Self.spins { continue }
                if monotonicNanos() - batchStart < Self.maxBatchNanos {
                    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    if poll(&p, 1, 1) > 0 {
                        misses = 0
                        continue
                    }
                }
                break batch
            }
            deliver(count)
        }
    }
}
