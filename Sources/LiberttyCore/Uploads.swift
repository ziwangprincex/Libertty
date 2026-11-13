#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
#if os(Linux)
import FoundationEssentials  // not Foundation: on Linux that brings 45 MB of ICU
#else
import Foundation
#endif

/// Files a window sends to the machine liberttyd runs on (Rex's and Kero's
/// uploads): a screenshot pasted into a pane on a remote host, files dropped
/// on it. Each batch goes in a folder of its own in liberttyd's private
/// directory (beside its socket, which only the user can enter), under the
/// names they had, so a program sees `paste-….png` or `notes.md`; batches
/// older than a week go as the next one comes.
public enum Uploads {
    public static let keep: Double = 7 * 24 * 3600
    /// The most one file may be (a frame is at most Wire.maxFrame).
    public static let maxFileBytes = 200 << 20

    /// liberttyd's uploads folder: beside its socket.
    public static var directory: String { Wire.socketPath.parentPath.appendingPath("uploads") }

    public struct Refusal: Error, CustomStringConvertible {
        public let description: String
    }

    /// Writes `bytes` as `relativePath` (a name, or a path inside a dropped
    /// folder) in batch `batch` (letters, digits and dashes: the window's
    /// name for one paste or drop), and returns where it is.
    public static func store(_ bytes: Data, batch: String, relativePath: String, in root: String = directory,
                             now: Double = Date().timeIntervalSince1970) throws -> String {
        guard !batch.isEmpty, batch.count <= 64,
              batch.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
        else { throw Refusal(description: "bad batch") }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains("\0") }),
              !relativePath.hasPrefix("/") else { throw Refusal(description: "bad name: \(relativePath)") }
        guard bytes.count <= maxFileBytes else { throw Refusal(description: "\(relativePath) is too big to upload") }
        prune(root, before: now - keep)
        var dir = root.appendingPath(batch)
        for part in parts.dropLast() { dir = dir.appendingPath(part) }
        try makeDirectory(dir)
        let path = dir.appendingPath(parts[parts.count - 1])
        // Never over anything (a batch is the window's; a second file of the
        // same name is a bug there, not something to clobber).
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Refusal(description: "can't write \(relativePath): \(SystemError(errno))") }
        defer { sysClose(fd) }
        var written = 0
        try bytes.withUnsafeBytes { raw in
            while written < raw.count {
                let n = sysWrite(fd, raw.baseAddress! + written, raw.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Refusal(description: "can't write \(relativePath): \(SystemError(errno))")
                }
                written += n
            }
        }
        return path
    }

    private static func makeDirectory(_ path: String) throws {
        var built = ""
        for part in path.split(separator: "/") {
            built += "/" + part
            if mkdir(built, 0o700) != 0, errno != EEXIST {
                throw Refusal(description: "can't make \(built): \(SystemError(errno))")
            }
        }
    }

    /// Batches last changed before `before`, and nothing else in the folder.
    static func prune(_ root: String, before: Double) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for name in names {
            let path = root.appendingPath(name)
            var st = stat()
            guard lstat(path, &st) == 0, Int(st.st_mode) & Int(S_IFMT) == Int(S_IFDIR) else { continue }
            #if os(Linux)
            let changed = Double(st.st_mtim.tv_sec)
            #else
            let changed = Double(st.st_mtimespec.tv_sec)
            #endif
            if changed < before { try? FileManager.default.removeItem(atPath: path) }
        }
    }
}
