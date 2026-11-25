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
        // Open documents hear where their files went, whatever the outcome.
        defer { announce(done) }
        do {
            for (from, to) in pairs {
                try FileManager.default.moveItem(at: from, to: to)
                done.append((from, to))
            }
        } catch {
            // What moved stays undoable (nothing moved: nothing to undo); the rest says why it didn't.
            if !done.isEmpty { register(name, manager) { manager in moveBack(done.map { ($1, $0) }, name: name, manager) } }
            throw error
        }
        register(name, manager) { manager in moveBack(done.map { ($1, $0) }, name: name, manager) }
    }

    /// Undoing a move (or Move to Trash): each back where it was. One that
    /// can't go (a file made at its old name since, the Trash emptied) is
    /// said, with where it is still — never skipped in silence, as Edit ▸
    /// Undo had promised it. What did go back can be redone.
    private static func moveBack(_ pairs: [(URL, URL)], name: String, _ manager: UndoManager) {
        do { try move(pairs, name: name, undo: manager) } catch {
            let left = pairs.map(\.0).filter { FileManager.default.fileExists(atPath: $0.path) }
            let still = left.map { String(format: L10n.t("“%@” is still in %@."), $0.lastPathComponent,
                                          ($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath) }
            undoFailed(String(format: L10n.t("Couldn't undo %@"), L10n.t(name)),
                       ([error.localizedDescription] + still).joined(separator: "\n\n"), reveal: left)
        }
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
        register(name, manager) { manager in moveBack(back, name: name, manager) }
    }

    // MARK: Helpers

    /// Posted when files moved here (Rename, a move, and undoing them):
    /// `moves` maps each old place to its new one. An open document follows
    /// its file, so a save goes where the file is now, not to a new file at
    /// its old name. Move to Trash posts nothing: a document of a trashed
    /// file finds it gone and keeps its text, and a save puts the file back
    /// where it was rather than into the Trash, to be emptied with it.
    static let moved = Notification.Name("dev.libertty.terminal.files-moved")

    private static func announce(_ moves: [(URL, URL)]) {
        guard !moves.isEmpty else { return }
        NotificationCenter.default.post(name: moved, object: nil, userInfo: ["moves": Dictionary(moves) { $1 }])
    }

    /// What making `urls` is undone by: they go to the Trash.
    private static func registerTrash(_ urls: [URL], name: String, manager: UndoManager?) {
        guard !urls.isEmpty else { return }
        register(name, manager) { manager in
            trash(urls, name: name, undo: manager) { result in
                // Not done: said, as a move back that can't be done is.
                guard case .failure(let error) = result else { return }
                let left = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
                undoFailed(String(format: L10n.t("Couldn't undo %@"), L10n.t(name)), error.localizedDescription, reveal: left)
            }
        }
    }

    private static func register(_ name: String, _ given: UndoManager?, _ handler: @escaping (UndoManager) -> Void) {
        let manager = given ?? CloseUndo.shared.manager
        manager.registerUndo(withTarget: target) { _ in MainActor.assumeIsolated { handler(manager) } }
        manager.setActionName(name)
    }

    /// Where an undo that couldn't be done is said, in place of the alert (a test's own).
    static var reportUndoFailure: ((_ title: String, _ message: String) -> Void)?

    /// An alert on the window in front (Edit ▸ Undo's), offering to show
    /// what's left where it is.
    private static func undoFailed(_ title: String, _ message: String, reveal: [URL]) {
        if let reportUndoFailure { return reportUndoFailure(title, message) }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.t("OK"))
        if !reveal.isEmpty { alert.addButton(withTitle: L10n.t("Show in Finder")) }
        let done = { (response: NSApplication.ModalResponse) in
            if response == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting(reveal) }
        }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.windowController is TerminalWindowController }
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
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
