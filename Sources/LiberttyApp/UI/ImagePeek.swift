import AppKit

/// The picture an image path printed in a pane shows while ⌘ hovers it
/// (Kero's peek): a card beside the path with the image, as of its
/// modification time, and its name and size. Decoded off the main thread;
/// a huge file isn't read for a glance.
final class ImagePeek: NSView {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp", "svg", "ico"]
    static let maxBytes = 50 << 20
    /// The most the picture takes, in points.
    static let maxSide: CGFloat = 320

    /// The local file an image link names; nil for anything else.
    static func imageFile(_ link: TerminalLink) -> URL? {
        guard let url = URL(string: link.url) ?? URL(string: link.url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              url.isFileURL, extensions.contains(url.pathExtension.lowercased()) else { return nil }
        if let host = url.host, !host.isEmpty, host != "localhost" { return nil }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > 0, size <= maxBytes else { return nil }
        return url
    }

    /// Where the card goes: beside the link (below it, or above when there's
    /// no room), inside `bounds`.
    static func frame(for size: CGSize, near link: CGRect, in bounds: CGRect) -> CGRect {
        var x = link.minX
        // A flipped view: y grows downward.
        var y = link.maxY + 4
        if y + size.height > bounds.maxY - 4 { y = link.minY - 4 - size.height }
        y = max(bounds.minY + 4, min(y, bounds.maxY - size.height - 4))
        x = max(bounds.minX + 4, min(x, bounds.maxX - size.width - 4))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The picture's size in the card: no bigger than `maxSide`, never enlarged.
    static func fitted(_ image: CGSize, maxSide: CGFloat = maxSide) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(1, maxSide / max(image.width, image.height))
        return CGSize(width: (image.width * scale).rounded(), height: (image.height * scale).rounded())
    }

    private let picture = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    /// What it shows (a path and its modification date), so a hover over
    /// the same file shows it again without reading it.
    private(set) var showing: (path: String, modified: Date)?
    private static var cache: [String: (modified: Date, image: NSImage)] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Radius.floating
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        picture.imageScaling = .scaleProportionallyUpOrDown
        caption.font = Typeface.ui(11)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingMiddle
        addSubview(picture)
        addSubview(caption)
        isHidden = true
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /// Show `file` beside `link` (a rect in the superview), once decoded.
    func show(_ file: URL, near link: CGRect) {
        let modified = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date) ?? .distantPast
        if let showing, showing.path == file.path, showing.modified == modified, !isHidden { return }
        showing = (file.path, modified)
        if let cached = Self.cache[file.path], cached.modified == modified {
            present(cached.image, file: file, near: link)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = NSImage(contentsOf: file)
            DispatchQueue.main.async {
                guard let self, let image, self.showing?.path == file.path else { return }
                Self.cache[file.path] = (modified, image)
                if Self.cache.count > 16, let any = Self.cache.keys.first(where: { $0 != file.path }) { Self.cache[any] = nil }
                self.present(image, file: file, near: link)
            }
        }
    }

    func hide() {
        showing = nil
        isHidden = true
    }

    private func present(_ image: NSImage, file: URL, near link: CGRect) {
        guard let superview else { return }
        let pixels = image.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        let shown = Self.fitted(image.size)
        guard shown != .zero else { return hide() }
        picture.image = image
        caption.stringValue = file.lastPathComponent + "  \(Int(pixels.width))×\(Int(pixels.height))"
        picture.setAccessibleLabel(L10n.t("Image") + ", " + caption.stringValue)
        let pad: CGFloat = 8, captionHeight: CGFloat = 16
        let size = CGSize(width: max(shown.width, 140) + pad * 2, height: shown.height + captionHeight + pad * 2 + 2)
        frame = Self.frame(for: size, near: link, in: superview.bounds)
        picture.frame = CGRect(x: (size.width - shown.width) / 2, y: pad, width: shown.width, height: shown.height)
        caption.frame = CGRect(x: pad, y: pad + shown.height + 2, width: size.width - pad * 2, height: captionHeight)
        isHidden = false
    }
}
