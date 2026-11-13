import AppKit

/// What the sidebar's file tree does to files (Kero's Files): new files and
/// folders, rename, duplicate, Move to Trash, and files dropped in. Each can
/// be undone (Edit ▸ Undo, ⌘Z), with the windows' shared undo manager: what
/// it made goes to the Trash, what it trashed or moved comes back.
@MainActor
enum FileOperations {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Nothing the undo handlers need: one target for all of them (the
    /// manager doesn't keep its targets).
    private static let target = NSObject()

    // Each takes the undo manager to register with: nil is the windows' shared one.

    // MARK: Making

    /// A file or folder from a typed name: `docs/notes.md` makes the
    /// folders on the way. Fails if it's there already.
    @discardableResult
    static func create(_ typed: String, in folder: URL, isFolder: Bool, undo manager: UndoManager? = nil) throws -> URL {
        let parts = typed.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !typed.trimmingCharacters(in: .whitespaces).hasPrefix("/") else {
            throw Failure(message: L10n.t("Type a name for it, in this folder."))
        }
        if let bad = parts.first(where: { $0 == "." || $0 == ".." || $0.contains("\0") }) {
            throw Failure(message: String(format: L10n.t("“%@” can't be part of a name."), bad))
        }
        var url = folder
        for part in parts { url.appendPathComponent(part) }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Failure(message: String(format: L10n.t("“%@” is there already."), parts.joined(separator: "/")))
        }
        // The folders on the way that aren't there yet: undone with it.
        var made = url
        while made.deletingLastPathComponent().path != folder.path,
              !FileManager.default.fileExists(atPath: made.deletingLastPathComponent().path) {
            made.deleteLastPathComponent()
        }
        if isFolder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw Failure(message: String(format: L10n.t("Couldn't make “%@”."), url.lastPathComponent))
            }
        }
        registerTrash([made], name: isFolder ? "New Folder" : "New File", manager: manager)
        return url
    }

    /// `name copy.ext`, `name copy 2.ext`…, beside it.
    @discardableResult
    static func duplicate(_ url: URL, undo manager: UndoManager? = nil) throws -> URL {
        let copy = available(url.lastPathComponent, in: url.deletingLastPathComponent(), copy: true)
        try FileManager.default.copyItem(at: url, to: copy)
        registerTrash([copy], name: "Duplicate", manager: manager)
        return copy
    }

    // MARK: Renaming and moving

    @discardableResult
    static func rename(_ url: URL, to typed: String, undo manager: UndoManager? = nil) throws -> URL {
        let name = typed.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != ".." else { throw Failure(message: L10n.t("Type a name for it.")) }
        guard !name.contains("/"), !name.contains("\0") else { throw Failure(message: L10n.t("A name can't have “/” in it.")) }
        let to = url.deletingLastPathComponent().appendingPathComponent(name)
        guard to.lastPathComponent != url.lastPathComponent else { return url }
        // On a disk that doesn't tell cases apart, `a.txt` → `A.txt` is still itself.
        if FileManager.default.fileExists(atPath: to.path), !sameItem(url, to) {
            throw Failure(message: String(format: L10n.t("“%@” is there already."), name))
        }
        try move([(url, to)], name: "Rename", undo: manager)
        return to
    }

    /// Each `from` to its `to`; undone by moving them back.
    static func move(_ pairs: [(URL, URL)], name: String, undo manager: UndoManager? = nil) throws {
        var done: [(URL, URL)] = []
        do {
            for (from, to) in pairs {
                try FileManager.default.moveItem(at: from, to: to)
                done.append((from, to))
            }
        } catch {
            // What moved stays undoable; the rest says why it didn't.
            register(name, manager) { manager in try? move(done.map { ($1, $0) }, name: name, undo: manager) }
            throw error
        }
        register(name, manager) { manager in try? move(done.map { ($1, $0) }, name: name, undo: manager) }
    }

    /// Files dropped on a folder: copied in (moved with `move`), a name
    /// taken already getting a number (`name 2.ext`). What's dropped where
    /// it is already, or into itself, is left alone.
    static func drop(_ urls: [URL], into folder: URL, move moving: Bool, undo manager: UndoManager? = nil) throws -> [URL] {
        let target = folder.standardizedFileURL.resolvingSymlinksInPath()
        let urls = urls.filter { url in
            let source = url.standardizedFileURL.resolvingSymlinksInPath()
            // Into itself, or a folder of its own.
            if target.path == source.path || target.path.hasPrefix(source.path + "/") { return false }
            return !(moving && source.deletingLastPathComponent().path == target.path)
        }
        guard !urls.isEmpty else { return [] }
        var placed: [URL] = []
        if moving {
            let pairs = urls.map { ($0, available($0.lastPathComponent, in: folder, copy: false)) }
            try move(pairs, name: "Move", undo: manager)
            placed = pairs.map(\.1)
        } else {
            defer { registerTrash(placed, name: "Copy", manager: manager) }
            for url in urls {
                let to = available(url.lastPathComponent, in: folder, copy: false)
                try FileManager.default.copyItem(at: url, to: to)
                placed.append(to)
            }
        }
        return placed
    }

    // MARK: The Trash

    /// Where Move to Trash puts things in place of the Trash (a probe's or a test's own folder).
    static var trashFolder: URL?

    /// To the Trash (undone: put back where they were). `done` with what
    /// went, by where it went.
    static func trash(_ urls: [URL], name: String = "Move to Trash", undo manager: UndoManager? = nil,
                      done: @escaping (Result<[URL: URL], Error>) -> Void) {
        if let folder = trashFolder {
            var trashed: [URL: URL] = [:]
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for url in urls {
                    let to = available(url.lastPathComponent, in: folder, copy: false)
                    try FileManager.default.moveItem(at: url, to: to)
                    trashed[url] = to
                }
            } catch {
                put(trashed, name: name, manager)
                return done(.failure(error))
            }
            put(trashed, name: name, manager)
            return done(.success(trashed))
        }
        NSWorkspace.shared.recycle(urls) { trashed, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    put(trashed, name: name, manager)
                    if let error, trashed.count < urls.count { done(.failure(error)) } else { done(.success(trashed)) }
                }
            }
        }
    }

    /// What went to the Trash comes back by undoing.
    private static func put(_ trashed: [URL: URL], name: String, _ manager: UndoManager?) {
        guard !trashed.isEmpty else { return }
        let back = trashed.map { ($0.value, $0.key) }
        register(name, manager) { manager in try? move(back, name: name, undo: manager) }
    }

    // MARK: Helpers

    /// What making `urls` is undone by: they go to the Trash.
    private static func registerTrash(_ urls: [URL], name: String, manager: UndoManager?) {
        guard !urls.isEmpty else { return }
        register(name, manager) { manager in trash(urls, name: name, undo: manager) { _ in } }
    }

    private static func register(_ name: String, _ given: UndoManager?, _ handler: @escaping (UndoManager) -> Void) {
        let manager = given ?? CloseUndo.shared.manager
        manager.registerUndo(withTarget: target) { _ in MainActor.assumeIsolated { handler(manager) } }
        manager.setActionName(name)
    }

    /// `name` in `folder`, or the first free one after it: `a copy.txt`,
    /// `a copy 2.txt` for a duplicate; `a 2.txt`, `a 3.txt` otherwise.
    static func available(_ name: String, in folder: URL, copy: Bool) -> URL {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        func named(_ n: Int) -> URL {
            let base: String
            if copy { base = n == 1 ? "\(stem) copy" : "\(stem) copy \(n)" } else { base = n == 1 ? stem : "\(stem) \(n)" }
            return folder.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        }
        var n = 1
        while FileManager.default.fileExists(atPath: named(n).path) { n += 1 }
        return named(n)
    }

    private static func sameItem(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let x = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
              let y = try? b.resourceValues(forKeys: key).fileResourceIdentifier else { return false }
        return x.isEqual(y)
    }
}
