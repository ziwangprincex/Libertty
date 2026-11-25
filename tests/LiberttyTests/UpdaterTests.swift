import AppKit
import Testing
@testable import LiberttyApp

/// Installing an update swaps two bundles: whatever goes wrong, an app is
/// left where the app was.
struct UpdaterTests {
    /// A file manager whose Trash is a folder of the test's; `failsSwap`:
    /// the new bundle can't be moved into place.
    private final class SwapFileManager: FileManager, @unchecked Sendable {
        let trash: URL
        let failsSwap: Bool
        init(trash: URL, failsSwap: Bool) {
            self.trash = trash
            self.failsSwap = failsSwap
            super.init()
        }
        override func trashItem(at url: URL, resultingItemURL out: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            let put = trash.appendingPathComponent(url.lastPathComponent)
            try super.moveItem(at: url, to: put)
            out?.pointee = put as NSURL
        }
        override func moveItem(at source: URL, to destination: URL) throws {
            if failsSwap, source.lastPathComponent.hasPrefix(".Libertty-") { throw CocoaError(.fileWriteNoPermission) }
            try super.moveItem(at: source, to: destination)
        }
    }

    /// Two bundles told apart by a file inside: the old app, the staged new one.
    private func bundles() throws -> (dir: URL, app: URL, staged: URL, trash: URL) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("libertty-swap-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("Libertty.app"), staged = dir.appendingPathComponent(".Libertty-9.9.9-1.app")
        let trash = dir.appendingPathComponent("Trash")
        for (bundle, version) in [(app, "old"), (staged, "new")] {
            try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data(version.utf8).write(to: bundle.appendingPathComponent("version"))
        }
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        return (dir, app, staged, trash)
    }

    private func version(at app: URL) -> String? {
        (try? Data(contentsOf: app.appendingPathComponent("version"))).flatMap { String(data: $0, encoding: .utf8) }
    }

    @Test func theNewOneTakesTheOldOnesPlace() throws {
        let b = try bundles()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        try Updater.swap(b.staged, into: b.app, fileManager: SwapFileManager(trash: b.trash, failsSwap: false))
        #expect(version(at: b.app) == "new")
        // The old one stays in the Trash, for undoing an update by hand.
        #expect(version(at: b.trash.appendingPathComponent("Libertty.app")) == "old")
    }

    /// The old one went to the Trash and the new one couldn't take its
    /// place: the old one comes back, not no app at all.
    @Test func aFailedSwapPutsTheTrashedOneBack() throws {
        let b = try bundles()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        #expect(throws: Updater.Failure.self) {
            try Updater.swap(b.staged, into: b.app, fileManager: SwapFileManager(trash: b.trash, failsSwap: true))
        }
        #expect(version(at: b.app) == "old")
        // And the new one is still where the error says it is.
        #expect(version(at: b.staged) == "new")
    }

    /// A restart while you're in another app opens behind it, and says so
    /// to the new one, which then doesn't come forward.
    @Test func anIdleRestartStaysInTheBackground() {
        let quiet = Updater.relaunchScript(pid: 42, inBackground: true)
        #expect(quiet.contains("kill -0 42"))
        #expect(quiet.hasSuffix("/usr/bin/open -g \"$0\" --args \(Updater.relaunchedInBackground)"))
        let asked = Updater.relaunchScript(pid: 42, inBackground: false)
        #expect(asked.hasSuffix("/usr/bin/open \"$0\"") && !asked.contains(Updater.relaunchedInBackground))
    }

    /// The feed isn't signed: its notes' links open only on the releases'
    /// own site, over https; the rest show as text.
    @MainActor @Test func theNotesLinkOnlyToTheReleasesSite() {
        let notes = "- [page](https://github.com/x/y/releases/tag/v1) [file](file:///Applications/Calculator.app) "
            + "[scheme](x-man-page://ls) [web](http://github.com/x) [elsewhere](https://example.com/)"
        let text = UpdateController.render(notes: notes)
        var links: [String] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL { links.append(url.absoluteString) }
        }
        #expect(links == ["https://github.com/x/y/releases/tag/v1"])
        #expect(text.string.contains("elsewhere"))
        #expect(UpdateController.openable(URL(string: "https://GitHub.com/a")) != nil)
        #expect(UpdateController.openable(URL(string: "https://github.com.example.org/a")) == nil)
    }
}
