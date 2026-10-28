#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
#if os(Linux)
import Dispatch
import FoundationEssentials
#else
import Foundation
#endif

/// A window attached to a session, and the frames on their way to it. A
/// thread of its own writes them, so a window that stops reading — a hung
/// app, a link to a host that stalled — holds up nobody: not the program,
/// not the other windows, not typing (GoRex's attached writer).
///
/// A window that falls more than `budget` behind skips ahead instead of
/// holding the session back: the output it hasn't been sent is dropped and
/// none is queued for it, and once it has written everything it had, it
/// gets the session as it is then, a snapshot in place of what it missed —
/// tmux redraws a client that fell behind the same way. A window that
/// can't take a snapshot mid-stream (it didn't attach with `catchUp`) is
/// hung up instead, and redials (GoRex).
final class Outbox {
    let connection: Connection
    /// Unsent output a window may fall behind by. One that reads as fast as
    /// it parses stays far below; past it, a snapshot is cheaper than the
    /// backlog, and the window is current sooner.
    static let budget = 8 << 20
    /// Consecutive output merges into frames up to this size: fewer, larger
    /// writes for a window that's behind.
    private static let merge = 1 << 20

    private struct Frame {
        var kind: Wire.Kind
        var data: Data
        /// Program output, which counts against the budget (not a snapshot
        /// or what comes with it, not `exited`).
        var budgeted: Bool
    }

    private let catchUp: Bool
    private let cond = NSCondition()
    private var frames: [Frame] = []
    /// Budgeted bytes in `frames`.
    private var unsent = 0
    /// Skipping: owed a catch-up once it has written what it's writing.
    private var behind = false
    /// The catch-up was asked for and hasn't come yet.
    private var asked = false
    /// The last frames are queued: write them, then hang up.
    private var finishing = false
    /// Hung up: nothing more goes out.
    private var gone = false
    /// Asked for the catch-up, and told when the window is gone.
    private weak var session: DaemonSession?

    init(_ connection: Connection, catchUp: Bool, session: DaemonSession) {
        self.connection = connection
        self.catchUp = catchUp
        self.session = session
    }

    /// Writing starts; queue the first frames before, under the session's
    /// lock, so nothing can come ahead of them.
    func start() {
        let thread = Thread { [self] in write() }
        thread.name = "liberttyd.outbox"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Program output, written when the window gets to it. Never blocks.
    /// False once the window is gone (let go for falling behind, or hung
    /// up): the session drops it from its list then.
    @discardableResult
    func output(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return true }
        cond.lock()
        defer { cond.unlock() }
        guard !gone else { return false }
        guard !finishing, !behind else { return true }
        guard unsent + bytes.count <= Self.budget else {
            fallBehind()
            return !gone
        }
        unsent += bytes.count
        if let last = frames.indices.last, frames[last].budgeted,
           frames[last].data.count + bytes.count <= Self.merge {
            frames[last].data.append(base.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        } else {
            frames.append(Frame(kind: .output, data: Data(bytes: base, count: bytes.count), budgeted: true))
        }
        cond.signal()
        return true
    }

    /// Hung up, by itself or by us: nothing more reaches it.
    var isGone: Bool {
        cond.lock()
        defer { cond.unlock() }
        return gone
    }

    /// Too far behind (under `cond`). What's queued is moot: the catch-up
    /// covers it. (Queries in the output it skips are answered by the
    /// session meanwhile: see DaemonSession.terminalWantsToReply.)
    private func fallBehind() {
        frames.removeAll { $0.budgeted }
        unsent = 0
        guard catchUp else {
            // It can't take a snapshot mid-stream: let it go, and it redials.
            gone = true
            frames = []
            cond.signal()
            connection.close()
            DaemonServer.log("let go of a window \(Self.budget >> 20) MB behind (it redials)")
            return
        }
        behind = true
        cond.signal()  // a writer waiting for frames sees it's owed one
    }

    /// A frame that goes out whatever the budget: the attach snapshot and
    /// the images after it, `exited`.
    func send(_ kind: Wire.Kind, _ data: Data) {
        cond.lock()
        defer { cond.unlock() }
        guard !gone, !finishing else { return }
        frames.append(Frame(kind: kind, data: data, budgeted: false))
        cond.signal()
    }

    /// Whether it's skipping, waiting for a catch-up.
    var isBehind: Bool {
        cond.lock()
        defer { cond.unlock() }
        return behind
    }

    /// The session's catch-up (a snapshot, with its images): the
    /// skipping ends, and output queues after it. Under the session's lock,
    /// so no output can come between the snapshot and the queue.
    func caughtUp(_ catchUp: [(Wire.Kind, Data)]) {
        cond.lock()
        defer { cond.unlock() }
        guard !gone else { return }
        for (kind, data) in catchUp { frames.append(Frame(kind: kind, data: data, budgeted: false)) }
        behind = false
        asked = false
        cond.signal()
    }

    /// The last frames are queued: write them, then hang up.
    func finish() {
        cond.lock()
        defer { cond.unlock() }
        finishing = true
        cond.signal()
    }

    /// Hang up now; what's queued is dropped.
    func hangUp() {
        cond.lock()
        gone = true
        frames = []
        unsent = 0
        cond.signal()
        cond.unlock()
        connection.close()  // and a write blocked on a peer that doesn't read returns
    }

    // MARK: Writing (its own thread)

    private func write() {
        while let frame = next() {
            guard connection.send(frame.kind, frame.data) else { break }
        }
        hangUp()
        session?.forget(self)
    }

    /// The next frame to write, once there is one; nil when there's nothing
    /// more to write.
    private func next() -> Frame? {
        cond.lock()
        defer { cond.unlock() }
        while true {
            if gone { return nil }
            if !frames.isEmpty {
                let frame = frames.removeFirst()
                if frame.budgeted { unsent -= frame.data.count }
                return frame
            }
            if finishing { return nil }
            if behind, !asked {
                // A session gone without ending (it can't be): nothing to
                // catch up to, so don't wait for it.
                guard let session else { return nil }
                // All it had is written: time to catch it up. The session
                // locks itself and then us, so ask unlocked.
                asked = true
                cond.unlock()
                session.catchUp(self)
                cond.lock()
                continue
            }
            cond.wait()
        }
    }
}
