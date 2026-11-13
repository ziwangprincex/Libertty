import CoreText
import Foundation

/// A font's first use costs CoreText milliseconds of its own: the bundled
/// fonts registered, each face's properties fetched from the font registry
/// the first time it lays out or draws. Done on another thread as the app
/// launches (`--startup-bench` measured ~25 ms of it on the main thread,
/// in the window's text fields and its first frame), they're ready when the
/// window wants them.
enum FontWarmup {
    static func start() {
        DispatchQueue.global(qos: .userInitiated).async {
            // The terminal's font as a pane makes it first (its config comes
            // later), the interface's (Typeface: Geist) and the system's.
            let fonts = FontSet(pointSize: 13, scale: 2)
            let interface = ["Geist-Regular", "Geist-Medium", "Geist-SemiBold"].map { CTFontCreateWithName($0 as CFString, 13, nil) }
            let faces = [fonts.font([]), fonts.font(.bold)] + interface
                + [CTFontCreateUIFontForLanguage(.system, 13, nil), CTFontCreateUIFontForLanguage(.emphasizedSystem, 13, nil)].compactMap { $0 }
            guard let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            for font in faces {
                let text = NSAttributedString(string: "Ag", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                let line = CTLineCreateWithAttributedString(text)
                context.textPosition = CGPoint(x: 2, y: 8)
                CTLineDraw(line, context)
            }
        }
    }
}
