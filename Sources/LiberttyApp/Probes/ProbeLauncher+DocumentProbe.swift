#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --document-probe FILE|URL OUT.png`: show it as a document pane
    /// in a window off screen (never in front, never focused) and save
    /// what it shows.
    @MainActor
    static func documentProbe(_ target: String, to output: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let url = target.hasPrefix("http") ? URL(string: target)! : URL(fileURLWithPath: target)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 760, height: 520),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let doc = DocumentView(url: url, theme: Config().resolvedTheme, renderMarkdown: true)
        doc.frame = window.contentView!.bounds
        doc.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(doc)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        var saved = false
        doc.snapshot { image in
            if let image, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                saved = CGImageDestinationFinalize(dest)
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while !saved, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print(saved ? "document: \(doc.title) → \(output)" : "document: no snapshot")
        exit(saved ? 0 : 1)
    }
}
#endif
