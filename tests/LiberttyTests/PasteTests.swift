import AppKit
import Testing
@testable import LiberttyApp

/// What a paste types: files as their paths, else the text, else an image
/// alone saved to a file and pasted as its path.
struct PasteTests {
    private func board() -> NSPasteboard {
        let b = NSPasteboard.withUniqueName()
        b.clearContents()
        return b
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("paste-test-\(UUID().uuidString)")
    }

    @Test func filesPasteTheirQuotedPaths() {
        let b = board()
        b.writeObjects([URL(fileURLWithPath: "/tmp/a b.png") as NSURL, URL(fileURLWithPath: "/tmp/c.txt") as NSURL])
        #expect(PasteContent.read(b, directory: directory()) == .paths("'/tmp/a b.png' /tmp/c.txt"))
    }

    @Test func textPastesAsText() {
        let b = board()
        b.setString("echo hi", forType: .string)
        #expect(PasteContent.read(b, directory: directory()) == .text("echo hi"))
        #expect(PasteContent.canPaste(b))
    }

    @Test func anImageAlonePastesTheFileItWasSavedTo() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let b = board()
        b.writeObjects([image])  // TIFF, as some apps copy a screenshot
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(PasteContent.canPaste(b))
        #expect(!PasteContent.canPaste(b, allowsImage: false))
        #expect(PasteContent.read(b, allowsImage: false, directory: dir) == .nothing)
        guard case .paths(let path) = PasteContent.read(b, directory: dir) else { Issue.record("no path"); return }
        #expect(path.hasPrefix(dir.path) && path.hasSuffix(".png"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))  // a PNG
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test func oldPastesArePrunedAndNothingElse() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("paste-old.png"), other = dir.appendingPathComponent("notes.png")
        try Data([1]).write(to: old); try Data([1]).write(to: other)
        let long = Date().addingTimeInterval(-30 * 24 * 3600)
        for url in [old, other] { try FileManager.default.setAttributes([.modificationDate: long], ofItemAtPath: url.path) }
        _ = try PasteContent.save(Data([0x89]), in: dir)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func anEmptyClipboardPastesNothing() {
        #expect(PasteContent.read(board(), directory: directory()) == .nothing)
        #expect(!PasteContent.canPaste(board()))
    }
}

/// The image peek's place and size.
struct ImagePeekTests {
    @Test func fitsAndPlaces() {
        #expect(ImagePeek.fitted(CGSize(width: 1280, height: 640)) == CGSize(width: 320, height: 160))
        #expect(ImagePeek.fitted(CGSize(width: 40, height: 20)) == CGSize(width: 40, height: 20))  // never enlarged
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        // Below the path when there's room…
        #expect(ImagePeek.frame(for: CGSize(width: 100, height: 100), near: CGRect(x: 50, y: 20, width: 80, height: 16), in: bounds).minY == 40)
        // …above it when there isn't, and inside the pane either way.
        let low = ImagePeek.frame(for: CGSize(width: 100, height: 100), near: CGRect(x: 560, y: 360, width: 30, height: 16), in: bounds)
        #expect(low.maxY <= 360 && low.maxX <= 596)
    }

    @Test func onlyLocalImages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("peek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("a.png"), txt = dir.appendingPathComponent("a.txt")
        try Data([0x89, 0x50]).write(to: png)
        try Data("x".utf8).write(to: txt)
        func link(_ url: String) -> TerminalLink { TerminalLink(url: url, spans: [], explicit: false) }
        #expect(ImagePeek.imageFile(link(png.absoluteString)) != nil)
        #expect(ImagePeek.imageFile(link(txt.absoluteString)) == nil)
        #expect(ImagePeek.imageFile(link("https://example.com/a.png")) == nil)
        #expect(ImagePeek.imageFile(link("file://elsewhere" + png.path)) == nil)
        #expect(ImagePeek.imageFile(link(dir.appendingPathComponent("gone.png").absoluteString)) == nil)
    }
}
