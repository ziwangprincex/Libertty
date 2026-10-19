import Foundation

/// Files Libertty ships next to the binary: `Contents/Resources` in the app
/// bundle, or the repository's `Resources/` when running from `swift build`.
enum AppResources {
    static func url(_ relativePath: String) -> URL? {
        for base in bases {
            let url = base.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static var bases: [URL] {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL { dirs.append(resources) }
        // Sources/Libertty/Util/AppResources.swift -> repository root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        dirs.append(root.appendingPathComponent("Resources"))
        dirs.append(root.appendingPathComponent("assets/icon"))  // the favicon, run from a build
        return dirs
    }
}
