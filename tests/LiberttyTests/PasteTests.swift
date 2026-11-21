import AppKit
import Testing
import UniformTypeIdentifiers
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

/// Attach from Photos…: which form of an item to ask for, the name its
/// file is kept under, and keeping it where pasted images are.
struct PhotoExportTests {
    @Test func picturesAndVideosKeepTheirFormat() {
        func name(_ suggested: String?, _ type: UTType, _ ext: String) -> String {
            let (base, ext) = PhotoExport.name(suggested: suggested, type: type, fileExtension: ext, stamp: "20261121-101500")
            return ext.isEmpty ? base : base + "." + ext
        }
        #expect(name("IMG_1234", .heic, "heic") == "photo-20261121-101500-IMG_1234.heic")
        #expect(name("IMG_1234.HEIC", .heic, "") == "photo-20261121-101500-IMG_1234.heic")
        #expect(name(nil, .quickTimeMovie, "") == "photo-20261121-101500.mov")
        #expect(name("IMG_0042", .mpeg4Movie, "MP4") == "photo-20261121-101500-IMG_0042.mp4")
        // The file's own extension when it's the format's; else the format's.
        #expect(name("a/b: c", .jpeg, "JPG") == "photo-20261121-101500-a-b-c.jpg")
        #expect(name(" ..hidden", .png, "tmp") == "photo-20261121-101500-hidden.png")
        #expect(name("照片 1", .png, "png") == "photo-20261121-101500-照片-1.png")
        #expect(name("---", .png, "") == "photo-20261121-101500.png")
    }

    @Test func asksForThePictureOrTheVideo() {
        #expect(PhotoExport.fileType(among: ["public.plain-text", "public.heic", "public.jpeg"]) == .heic)
        #expect(PhotoExport.fileType(among: ["com.apple.quicktime-movie"]) == .quickTimeMovie)
        #expect(PhotoExport.fileType(among: ["public.plain-text"]) == nil)
        #expect(PhotoExport.fileType(among: []) == nil)
    }

    @Test func keptBesidePastedImages() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("photo-test-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("libertty-paste"), from = root.appendingPathComponent("picker")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: from, withIntermediateDirectories: true)
        let long = Date().addingTimeInterval(-30 * 24 * 3600)
        // What the picker hands over may carry the day the photo was taken.
        func picked(_ name: String) throws -> URL {
            let url = from.appendingPathComponent(name)
            try Data([1, 2, 3]).write(to: url)
            try fm.setAttributes([.modificationDate: long], ofItemAtPath: url.path)
            return url
        }
        let first = try PhotoExport.keep(try picked("x.heic"), suggested: "IMG_1", type: .heic, stamp: "S", in: dir)
        #expect(first.lastPathComponent == "photo-S-IMG_1.heic")
        #expect(try Data(contentsOf: first) == Data([1, 2, 3]))
        #expect(try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int == 0o700)
        #expect(try fm.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int == 0o600)
        // Never over another; and dated now, so the next one doesn't prune it.
        let second = try PhotoExport.keep(try picked("y.heic"), suggested: "IMG_1", type: .heic, stamp: "S", in: dir)
        #expect(second.lastPathComponent == "photo-S-IMG_1-2.heic")
        #expect(fm.fileExists(atPath: first.path))
        // An old one goes as the next comes; what isn't Libertty's stays.
        let old = dir.appendingPathComponent("photo-old.mov"), other = dir.appendingPathComponent("notes.mov")
        for url in [old, other] {
            try Data([1]).write(to: url)
            try fm.setAttributes([.modificationDate: long], ofItemAtPath: url.path)
        }
        _ = try PhotoExport.keep(try picked("z.png"), suggested: nil, type: .png, stamp: "T", in: dir)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: other.path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("photo-T.png").path))
    }
}
