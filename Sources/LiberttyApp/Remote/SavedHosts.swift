import Foundation

/// The hosts you keep (Settings ▸ Remote Hosts, `libertty +hosts`), in your
/// order: added there or by connecting, removed only by you. Kept beside
/// the app's other data (`hosts.json`); the first time, the hosts you'd
/// connected to before come in as they were.
enum SavedHosts {
    /// Told (on the main thread) when the list changes.
    static let changed = Notification.Name("LiberttySavedHostsChanged")

    private static var url: URL { Blocks.dataDirectory.appendingPathComponent("hosts.json") }

    static var all: [String] {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([String].self, from: data) else {
            return ConnectPanel.recentHosts
        }
        return list
    }

    /// An ssh destination one can keep: no option, no space (ssh would read either as something else).
    static func isValid(_ destination: String) -> Bool {
        !destination.isEmpty && !destination.hasPrefix("-") && !destination.contains(where: \.isWhitespace)
    }

    /// At the end, unless it's there already. Whether it was added.
    @discardableResult
    static func add(_ destination: String) -> Bool {
        var list = all
        guard isValid(destination), !list.contains(destination) else { return false }
        list.append(destination)
        save(list)
        return true
    }

    @discardableResult
    static func remove(_ destination: String) -> Bool {
        var list = all
        guard let i = list.firstIndex(of: destination) else { return false }
        list.remove(at: i)
        save(list)
        return true
    }

    /// The hosts at `offsets` to before `destination` (SwiftUI's onMove).
    static func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        save(reordered(all, fromOffsets: offsets, toOffset: destination))
    }

    static func reordered(_ list: [String], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [String] {
        let moving = offsets.sorted().filter { $0 < list.count }.map { list[$0] }
        let before = list[..<min(max(0, destination), list.count)].filter { !moving.contains($0) }.count
        var rest = list.filter { !moving.contains($0) }
        rest.insert(contentsOf: moving, at: before)
        return rest
    }

    private static func save(_ list: [String]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: url, options: .atomic) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
    }
}
