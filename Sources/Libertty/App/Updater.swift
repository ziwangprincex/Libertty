import AppKit
import CryptoKit

/// Libertty ▸ Check for Updates… and `auto-update` (Ghostty's names).
///
/// The feed is a small JSON file (`appcast.json`, written by
/// scripts/release.sh) naming the newest version and its zip. A zip is only
/// installed if its Ed25519 signature checks out against the public key
/// built into this app: the app isn't notarized, so this is what makes an
/// update trustworthy, whoever serves the files. Installing swaps the app
/// bundle and relaunches; programs keep running in liberttyd meanwhile and the
/// windows come back as they were.
enum Updater {
    /// One entry of the feed.
    struct Release: Decodable, Equatable {
        var version: String
        var url: String
        var sha256: String
        /// Base64 Ed25519 signature of the zip's bytes.
        var signature: String
        var size: Int
        var notes: String?
        var minimumSystemVersion: String?
    }

    enum Failure: LocalizedError {
        case noFeed, unreachable(String), badFeed, tooOld(String), download(String), verification(String), install(String)

        var errorDescription: String? {
            switch self {
            case .noFeed: "This build has no update feed."
            case .unreachable(let why): "Couldn't reach the update server (\(why))."
            case .badFeed: "The update server sent something that isn't an update feed."
            case .tooOld(let needed): "The new version needs macOS \(needed) or later."
            case .download(let why): "The download failed (\(why))."
            case .verification(let why): "The download didn't verify, so it wasn't installed (\(why))."
            case .install(let why): "The update couldn't be installed (\(why))."
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `$LIBERTTY_UPDATE_FEED` (tests, mirrors), else the one in Info.plist.
    static var feedURL: URL? {
        let env = ProcessInfo.processInfo.environment["LIBERTTY_UPDATE_FEED"]
        let plist = Bundle.main.object(forInfoDictionaryKey: "LiberttyUpdateFeed") as? String
        return (env?.isEmpty == false ? env : plist).flatMap(URL.init(string:))
    }

    private static var publicKey: Curve25519.Signing.PublicKey? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "LiberttyUpdatePublicKey") as? String,
              let raw = Data(base64Encoded: text) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    // MARK: Checking

    /// The release to update to, or nil when this is the newest.
    static func check() async throws -> Release? {
        guard let feed = feedURL else { throw Failure.noFeed }
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Libertty/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw http.statusCode == 404 ? Failure.unreachable("no release has been published yet")
                : Failure.unreachable("HTTP \(http.statusCode)")
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { throw Failure.badFeed }
        guard Version(release.version) > Version(currentVersion) else { return nil }
        if let needed = release.minimumSystemVersion, Version(needed) > Version(osVersion) { throw Failure.tooOld(needed) }
        return release
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // MARK: Downloading and verifying

    /// Download the release's zip and check its size, SHA-256 and signature.
    static func download(_ release: Release, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let url = URL(string: release.url) else { throw Failure.badFeed }
        let delegate = ProgressDelegate(expected: release.size, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let temporary: URL, response: URLResponse
        do {
            (temporary, response) = try await session.download(from: url)
        } catch {
            throw Failure.download(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.download("HTTP \(http.statusCode)") }
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("Libertty-\(release.version)-\(UUID().uuidString).zip")
        try? FileManager.default.removeItem(at: zip)
        try FileManager.default.moveItem(at: temporary, to: zip)
        do {
            try verify(zip, release)
        } catch {
            try? FileManager.default.removeItem(at: zip)
            throw error
        }
        return zip
    }

    static func verify(_ zip: URL, _ release: Release) throws {
        guard let data = try? Data(contentsOf: zip, options: .mappedIfSafe) else { throw Failure.verification("unreadable") }
        guard data.count == release.size else { throw Failure.verification("size \(data.count), expected \(release.size)") }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256.lowercased() else { throw Failure.verification("SHA-256 mismatch") }
        guard let key = publicKey else { throw Failure.verification("this build has no update key") }
        guard let signature = Data(base64Encoded: release.signature), key.isValidSignature(signature, for: data) else {
            throw Failure.verification("bad signature")
        }
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let expected: Int
        let progress: @Sendable (Double) -> Void
        init(expected: Int, progress: @escaping @Sendable (Double) -> Void) {
            self.expected = expected
            self.progress = progress
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : Double(max(1, expected))
            progress(min(1, Double(totalBytesWritten) / total))
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    // MARK: Installing

    /// Unpack a verified zip and put its Libertty.app where `app` is. The old
    /// bundle goes to the Trash (so an update can be undone by hand).
    static func install(_ zip: URL, release: Release, over app: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("libertty-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let new = work.appendingPathComponent("Libertty.app")
        guard let info = NSDictionary(contentsOf: new.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == release.version else {
            throw Failure.install("the archive doesn't hold Libertty \(release.version)")
        }
        // Verified above with our own key; Gatekeeper's quarantine would only
        // stop an ad-hoc signed app from opening.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", new.path])
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw Failure.install("no permission to write \(app.deletingLastPathComponent().path)")
        }
        // Move the new bundle next to the old one first (same volume, so the
        // swap below is two renames and can't leave a half-copied app).
        let staged = app.deletingLastPathComponent().appendingPathComponent(".Libertty-\(release.version)-\(getpid()).app")
        try? fm.removeItem(at: staged)
        do {
            try fm.copyItem(at: new, to: staged)
        } catch {
            throw Failure.install(error.localizedDescription)
        }
        var aside: URL?
        do {
            var trashed: NSURL?
            try fm.trashItem(at: app, resultingItemURL: &trashed)
        } catch {
            // No Trash on this volume: move the old one aside instead.
            let path = app.deletingLastPathComponent().appendingPathComponent(".Libertty-old-\(getpid()).app")
            try? fm.removeItem(at: path)
            do { try fm.moveItem(at: app, to: path) } catch {
                try? fm.removeItem(at: staged)
                throw Failure.install(error.localizedDescription)
            }
            aside = path
        }
        do {
            try fm.moveItem(at: staged, to: app)
        } catch {
            // Put the old one back rather than leave no app at all.
            if let aside { try? fm.moveItem(at: aside, to: app) }
            throw Failure.install("the new version is at \(staged.path): \(error.localizedDescription)")
        }
        if let aside { try? fm.removeItem(at: aside) }
    }

    /// After install: start the app at `path` once this process has quit.
    static func relaunch(_ path: String) {
        let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, path]
        try? p.run()
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure.install("\((tool as NSString).lastPathComponent) failed") }
    }
}

/// Dotted version numbers compared numerically ("0.10.0" > "0.9.2").
struct Version: Comparable {
    let parts: [Int]
    init(_ text: String) {
        let core = text.hasPrefix("v") ? String(text.dropFirst()) : text
        parts = core.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
    static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
    static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}
