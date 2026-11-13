import Foundation
import Testing
@testable import LiberttyApp

/// The file tree's changes to files, each undone and done again. (One at a
/// time: they share where Move to Trash puts things.)
@MainActor @Suite(.serialized)
struct FileOperationsTests {
    private let dir: URL
    private let manager = UndoManager()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fileops-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: dir.appendingPathComponent("a.txt"))
        manager.groupsByEvent = false
        FileOperations.trashFolder = dir.appendingPathComponent(".trash")
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) }

    /// One change as the app makes it: its own undo group.
    private func step<T>(_ body: () throws -> T) rethrows -> T {
        manager.beginUndoGrouping()
        defer { manager.endUndoGrouping() }
        return try body()
    }

    @Test func newFilesMakeTheirFoldersAndGoToTheTrashUndone() throws {
        let made = try step { try FileOperations.create("docs/notes.md", in: dir, isFolder: false, undo: manager) }
        #expect(made.path.hasSuffix("docs/notes.md") && exists("docs/notes.md"))
        manager.undo()
        // The folder made on the way goes too.
        #expect(!exists("docs"))
        manager.redo()
        #expect(exists("docs/notes.md"))
        #expect(throws: FileOperations.Failure.self) { try FileOperations.create("src", in: dir, isFolder: true, undo: manager) }
        #expect(throws: FileOperations.Failure.self) { try FileOperations.create("../out.txt", in: dir, isFolder: false, undo: manager) }
        #expect(throws: FileOperations.Failure.self) { try FileOperations.create("  ", in: dir, isFolder: false, undo: manager) }
    }

    @Test func renameAndBack() throws {
        let renamed = try step { try FileOperations.rename(dir.appendingPathComponent("a.txt"), to: "b.txt", undo: manager) }
        #expect(renamed.lastPathComponent == "b.txt" && exists("b.txt") && !exists("a.txt"))
        manager.undo()
        #expect(exists("a.txt") && !exists("b.txt"))
        manager.redo()
        #expect(exists("b.txt"))
        #expect(throws: FileOperations.Failure.self) { try FileOperations.rename(dir.appendingPathComponent("b.txt"), to: "x/y", undo: manager) }
        #expect(throws: FileOperations.Failure.self) { try FileOperations.rename(dir.appendingPathComponent("b.txt"), to: "src", undo: manager) }
        // A case change on a disk that doesn't tell cases apart is still itself.
        let upper = try step { try FileOperations.rename(dir.appendingPathComponent("b.txt"), to: "B.txt", undo: manager) }
        #expect(upper.lastPathComponent == "B.txt")
    }

    @Test func duplicatesAndDropsAreNumbered() throws {
        let a = dir.appendingPathComponent("a.txt")
        #expect(try step { try FileOperations.duplicate(a, undo: manager) }.lastPathComponent == "a copy.txt")
        #expect(try step { try FileOperations.duplicate(a, undo: manager) }.lastPathComponent == "a copy 2.txt")
        let src = dir.appendingPathComponent("src")
        #expect(try step { try FileOperations.drop([a], into: src, move: false, undo: manager) }.map(\.lastPathComponent) == ["a.txt"])
        #expect(try step { try FileOperations.drop([a], into: src, move: false, undo: manager) }.map(\.lastPathComponent) == ["a 2.txt"])
        manager.undo()
        #expect(!exists("src/a 2.txt") && exists("src/a.txt") && exists("a.txt"))
        // Into itself, or where it is already (moving), nothing happens.
        #expect(try FileOperations.drop([src], into: src, move: true, undo: manager).isEmpty)
        #expect(try FileOperations.drop([a], into: dir, move: true, undo: manager).isEmpty)
    }

    @Test func movedInAndBack() throws {
        let a = dir.appendingPathComponent("a.txt")
        let placed = try step { try FileOperations.drop([a], into: dir.appendingPathComponent("src"), move: true, undo: manager) }
        #expect(placed.map(\.lastPathComponent) == ["a.txt"] && !exists("a.txt") && exists("src/a.txt"))
        manager.undo()
        #expect(exists("a.txt") && !exists("src/a.txt"))
    }

    @Test func trashedAndPutBack() async throws {
        let a = dir.appendingPathComponent("a.txt")
        manager.beginUndoGrouping()
        let trashed: [URL: URL] = await withCheckedContinuation { done in
            FileOperations.trash([a], undo: manager) { result in done.resume(returning: (try? result.get()) ?? [:]) }
        }
        manager.endUndoGrouping()
        #expect(trashed.count == 1 && !exists("a.txt"))
        manager.undo()
        #expect(exists("a.txt"))
        manager.redo()
        #expect(!exists("a.txt"))
    }
}
