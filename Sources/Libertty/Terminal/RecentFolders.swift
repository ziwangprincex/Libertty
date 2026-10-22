import Foundation

/// The folders this Mac's shells have been in lately (OSC 7), newest first:
/// what the palette's Folders lists beside the panes' own (Go to Directory,
/// after Rex). Kept in the data folder; main thread only.
final class RecentFolders {
    static let shared = RecentFolders()
    private static let limit = 100

    private struct Entry: Codable {
        var path: String
        var at: Double
    }

    private var entries: [Entry]
    private let file = Blocks.dataDirectory.appendingPathComponent("recent-folders.json")
    private var pendingSave: DispatchWorkItem?

    private init() {
        entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))) ?? []
    }

    /// Newest first, those still there. (Those on other volumes aren't
    /// checked: a network share that's gone could hang the palette.)
    var paths: [String] {
        entries.sorted { $0.at > $1.at }.map(\.path)
            .filter { $0.hasPrefix("/Volumes/") || FileManager.default.fileExists(atPath: $0) }
    }

    func record(_ path: String) {
        guard path.hasPrefix("/") else { return }
        entries.removeAll { $0.path == path }
        entries.append(Entry(path: path, at: Date().timeIntervalSince1970))
        if entries.count > Self.limit { entries = Array(entries.sorted { $0.at > $1.at }.prefix(Self.limit)) }
        // A shell moving around writes once a moment, not at every cd.
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSave = nil
            self?.save()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Save now what's waiting to be (quitting).
    func flush() {
        guard let work = pendingSave else { return }
        work.cancel()
        pendingSave = nil
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
}
