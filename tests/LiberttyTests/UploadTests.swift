import Foundation
import Testing
@testable import LiberttyApp
@testable import LiberttyCore

/// Files sent to the machine liberttyd runs on (Uploads, RemoteUpload).
struct UploadTests {
    private func temporary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uploads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func storesUnderItsName() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try Uploads.store(Data("hi".utf8), batch: "b-1", relativePath: "notes.md", in: root.path)
        #expect(path == root.path + "/b-1/notes.md")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "hi")
        let nested = try Uploads.store(Data("x".utf8), batch: "b-1", relativePath: "dir/sub/a.txt", in: root.path)
        #expect(FileManager.default.fileExists(atPath: nested))
        // Only the user may read them.
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func refusesWhatLeavesItsFolder() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        for bad in ["../escape", "/etc/passwd", "a/../../b", ".", ""] {
            #expect(throws: Uploads.Refusal.self, "\(bad)") { try Uploads.store(Data(), batch: "b", relativePath: bad, in: root.path) }
        }
        for bad in ["../x", "a/b", "", "with space"] {
            #expect(throws: Uploads.Refusal.self, "\(bad)") { try Uploads.store(Data(), batch: bad, relativePath: "f", in: root.path) }
        }
        // Never over a file already there.
        _ = try Uploads.store(Data("1".utf8), batch: "b", relativePath: "f", in: root.path)
        #expect(throws: Uploads.Refusal.self) { try Uploads.store(Data("2".utf8), batch: "b", relativePath: "f", in: root.path) }
    }

    @Test func oldBatchesGo() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try Uploads.store(Data(), batch: "old", relativePath: "f", in: root.path)
        let then = Date().addingTimeInterval(-8 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: then], ofItemAtPath: (old as NSString).deletingLastPathComponent)
        try "keep".write(toFile: root.path + "/not-a-batch", atomically: true, encoding: .utf8)
        _ = try Uploads.store(Data(), batch: "new", relativePath: "f", in: root.path)
        #expect(!FileManager.default.fileExists(atPath: old))
        #expect(FileManager.default.fileExists(atPath: root.path + "/not-a-batch"))
    }

    /// A folder dropped goes with its files under it (links inside aren't
    /// followed); its path is the one typed.
    @Test func folders() throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "a".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "b".write(to: folder.appendingPathComponent("src/main.c"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        let file = dir.appendingPathComponent("one file.txt")
        try "c".write(to: file, atomically: true, encoding: .utf8)
        let (items, top) = try RemoteUpload.items(for: [folder, file])
        #expect(Set(items.map(\.relativePath)) == ["proj/README.md", "proj/src/main.c", "one file.txt"])
        #expect(top == ["proj", "one file.txt"])
    }
}
