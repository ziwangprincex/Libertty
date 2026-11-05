import AppKit

/// What a paste into a terminal types, from the clipboard as it is: files
/// copied in Finder as their quoted paths (as dropping them does); else the
/// text; else an image alone, as a screenshot copied to the clipboard is,
/// saved to a file of its own and pasted as that file's path, which agents
/// such as Claude Code attach as an image (Kero's paste).
enum PasteContent: Equatable {
    case text(String)
    /// Shell-quoted paths, one word each: no confirmation needed.
    case paths(String)
    case nothing

    /// Where images pasted into panes are kept, which only the user can
    /// enter; files older than `keep` go as the next image is saved.
    static var imageDirectory: URL {
        let base = ProcessInfo.processInfo.environment["LIBERTTY_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("libertty-paste", isDirectory: true)
    }
    static let keep: TimeInterval = 7 * 24 * 3600

    /// `allowsImage`: false for a pane on another machine, where a file on
    /// this Mac means nothing (files keep pasting their paths, as a drop does).
    static func read(_ pasteboard: NSPasteboard, allowsImage: Bool = true, directory: URL = imageDirectory) -> PasteContent {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .paths(urls.map { ShellQuote.quote($0.path) }.joined(separator: " "))
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty { return .text(text) }
        guard allowsImage, let png = pngData(pasteboard),
              let path = try? save(png, in: directory) else { return .nothing }
        return .paths(ShellQuote.quote(path))
    }

    /// Whether `read` would find anything, without saving an image.
    static func canPaste(_ pasteboard: NSPasteboard, allowsImage: Bool = true) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.fileURL) || types.contains(.string) { return true }
        return allowsImage && (types.contains(.png) || types.contains(.tiff))
    }

    /// The clipboard's image as PNG: as it is when it is one, else
    /// converted (screenshots come as TIFF from some apps).
    static func pngData(_ pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png), !png.isEmpty { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes the image to a new file in `directory` and returns its path.
    static func save(_ png: Data, in directory: URL, now: Date = Date()) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        prune(directory, before: now.addingTimeInterval(-keep))
        let stamp = Self.stamp.string(from: now)
        var url = directory.appendingPathComponent("paste-\(stamp).png")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("paste-\(stamp)-\(n).png"); n += 1
        }
        try png.write(to: url, options: .withoutOverwriting)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url.path
    }

    /// Removes earlier pastes' images last written before `before`, and nothing else.
    static func prune(_ directory: URL, before: Date) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("paste-") && name.hasSuffix(".png") {
            let url = directory.appendingPathComponent(name)
            if let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, date < before {
                try? fm.removeItem(at: url)
            }
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
