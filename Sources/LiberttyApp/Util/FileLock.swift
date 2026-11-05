import Foundation

/// A file in the data folder that more than one process writes (the app,
/// an agent's hook, the command line): each change made under an advisory
/// lock beside it, `NAME.lock`, so none is lost to another's at the same time.
enum FileLock {
    static func withLock<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
        return try body()
    }
}
