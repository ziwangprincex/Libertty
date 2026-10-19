#if canImport(os)
import os

/// `os_unfair_lock` without `OSAllocatedUnfairLock`'s `@Sendable` closure
/// requirement, for state shared between the io queue and the main thread.
public final class UnfairLock {
    private let raw: UnsafeMutablePointer<os_unfair_lock>

    public init() {
        raw = .allocate(capacity: 1)
        raw.initialize(to: os_unfair_lock())
    }

    deinit {
        raw.deinitialize(count: 1)
        raw.deallocate()
    }

    @inline(__always)
    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        os_unfair_lock_lock(raw)
        defer { os_unfair_lock_unlock(raw) }
        return try body()
    }
}
#else
/// Linux (liberttyd on a remote host): a plain mutex.
public final class UnfairLock {
    private let lock = NSLock()
    public init() {}

    @inline(__always)
    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
#endif

/// A flag set by one thread and consumed by another.
public final class AtomicFlag {
    private let lock = UnfairLock()
    private var value = false

    public init() {}

    /// Sets the flag; returns true if it was previously clear.
    public func set() -> Bool {
        lock.withLock {
            defer { value = true }
            return !value
        }
    }

    /// Clears the flag; returns whether it was set.
    public func consume() -> Bool {
        lock.withLock {
            defer { value = false }
            return value
        }
    }
}
