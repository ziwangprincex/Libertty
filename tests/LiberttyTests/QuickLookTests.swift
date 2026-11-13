import Foundation
import Testing
@testable import LiberttyApp

/// What Quick Look previews of a pane's links: this Mac's files and web
/// pages, a host's files never; and a fetched page as a file it can show.
struct QuickLookTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quicklook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: dir.appendingPathComponent("a b.txt"))
        return dir
    }

    private func link(_ url: String, explicit: Bool = false) -> TerminalLink {
        TerminalLink(url: url, spans: [.init(row: 0, columns: 0...3)], explicit: explicit)
    }

    @Test func filesAndPagesNotFoldersOrMissing() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let links = [
            link(dir.appendingPathComponent("a b.txt").absoluteString),
            link(dir.appendingPathComponent("sub").absoluteString),
            link(dir.appendingPathComponent("missing.txt").absoluteString),
            link("https://example.com/x"),
            link("mailto:someone@example.com"),
            link("https:///no-host"),
        ]
        let items = QuickLookPreview.previewable(links, remote: false)
        #expect(items.map(\.previewItemTitle) == ["a b.txt", "https://example.com/x"])
        #expect(items[0].previewItemURL == dir.appendingPathComponent("a b.txt"))
        // A page has no file until it's fetched (the panel shows "loading").
        #expect(items[1].previewItemURL == nil)
        // A folder when asked for (⇧⌘-click on one).
        #expect(QuickLookPreview.previewable([links[1]], remote: false, folders: true).count == 1)
    }

    @Test func aHostsFilesAreNotThisMacs() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let links = [link(dir.appendingPathComponent("a b.txt").absoluteString), link("https://example.com/")]
        #expect(QuickLookPreview.previewable(links, remote: true).map(\.previewItemTitle) == ["https://example.com/"])
        // An OSC 8 link naming another machine, in this Mac's pane.
        let elsewhere = link("file://some-other-host.invalid\(dir.appendingPathComponent("a b.txt").path)", explicit: true)
        #expect(QuickLookPreview.previewable([elsewhere], remote: false).isEmpty)
    }

    @Test func aFetchedPageIsSavedForWhatItIs() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = URL(string: "https://example.com/docs/")!
        let html = try #require(QuickLookPreview.save(.success((Data("<html><head><title>x</title></head></html>".utf8), "text/html")),
                                                      of: page, as: "0", in: dir))
        #expect(html.pathExtension == "html")
        // Its own links and pictures resolve where it came from.
        #expect(try String(contentsOf: html, encoding: .utf8).contains("<head><base href=\"https://example.com/docs/\">"))
        let png = try #require(QuickLookPreview.save(.success((Data([0x89, 0x50]), "image/png")), of: page, as: "1", in: dir))
        #expect(png.pathExtension == "png")
        struct Offline: LocalizedError { var errorDescription: String? { "offline <now>" } }
        let failed = try #require(QuickLookPreview.save(.failure(Offline()), of: page, as: "2", in: dir))
        let said = try String(contentsOf: failed, encoding: .utf8)
        #expect(said.contains("https://example.com/docs/") && said.contains("offline &lt;now&gt;"))
    }
}
