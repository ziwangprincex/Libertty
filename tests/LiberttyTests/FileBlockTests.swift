import Foundation
import Testing
@testable import LiberttyApp

/// A file block (a board, a drawing, a notebook) writing its file.
struct FileBlockTests {
    private func call(_ block: FileBlock, _ method: String, _ params: [String: Any]) async -> [String: Any] {
        await withCheckedContinuation { done in
            block.handle(method, params) { result in
                done.resume(returning: (try? result.get()) as? [String: Any] ?? [:])
            }
        }
    }

    /// Saved through a replacement, as the editor saves: what the file
    /// carries besides its bytes stays with it.
    @Test func aSaveKeepsWhatTheFileCarries() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fileblock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("plan.md")
        try Data("# Plan\n".utf8).write(to: file)
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o640, .creationDate: created], ofItemAtPath: file.path)
        let tag = Data("kept".utf8)
        #expect(tag.withUnsafeBytes { setxattr(file.path, "dev.libertty.test", $0.baseAddress, tag.count, 0, 0) } == 0)
        try (file as NSURL).setResourceValue(["Red"], forKey: .tagNamesKey)

        guard let block = FileBlock(url: Blocks.url("board", ["file": file.path])) else { Issue.record("no block"); return }
        defer { block.close() }
        let read = await call(block, "read", [:])
        let written = await call(block, "write", ["text": "# Plan\n\n- [ ] one\n", "base": read["base"] as? String ?? ""])
        #expect(written["written"] as? Bool == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == "# Plan\n\n- [ ] one\n")

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect(attributes[.creationDate] as? Date == created)
        var buffer = [UInt8](repeating: 0, count: 16)
        let size = getxattr(file.path, "dev.libertty.test", &buffer, buffer.count, 0, 0)
        #expect(size == tag.count && Data(buffer.prefix(max(size, 0))) == tag)
        let tags = try URL(fileURLWithPath: file.path).resourceValues(forKeys: [.tagNamesKey]).tagNames
        #expect(tags == ["Red"])
    }

    /// Renamed in the file tree: it writes the file where it is now — not a
    /// conflict over a file gone from its old name — and its address is the
    /// one opening the renamed file finds.
    @MainActor @Test func aMovedFileIsWrittenWhereItIsNow() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fileblock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("plan.board.md"), moved = dir.appendingPathComponent("sprint.board.md")
        try Data("# Plan\n".utf8).write(to: file)
        let address = Blocks.url("board", ["file": file.path])
        guard let block = BoardBlock(url: address) else { Issue.record("no block"); return }
        defer { block.close() }
        let read = await call(block, "read", [:])
        try FileManager.default.moveItem(at: file, to: moved)
        block.moved(to: moved)
        #expect(block.file == moved.standardizedFileURL && block.title == "sprint.board.md")
        let written = await call(block, "write", ["text": "# Plan\n\n- [ ] one\n", "base": read["base"] as? String ?? ""])
        #expect(written["written"] as? Bool == true)
        #expect(try String(contentsOf: moved, encoding: .utf8) == "# Plan\n\n- [ ] one\n")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(Blocks.address(address, file: moved) == Blocks.address(forFile: moved))
    }
}
