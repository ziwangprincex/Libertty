import AppKit
import LiberttyCore
import ImageIO
import Metal
import UniformTypeIdentifiers

/// `Libertty --snapshot out.png [--cols N] [--rows N] [--font-size PT] -- COMMAND`
///
/// Runs COMMAND in a terminal of the given size without opening a window,
/// waits for it to exit, and writes the final frame as a PNG. Used for visual
/// checks and regression tests of the renderer.
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot"), flag + 1 < args.count else { return }
        let output = args[flag + 1]
        func value(_ name: String, _ fallback: Int) -> Int {
            guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1]) else { return fallback }
            return v
        }
        let cols = value("--cols", 80), rows = value("--rows", 24)
        // Defaults, not the user's config, unless asked: snapshots are regression references.
        var config = args.contains("--use-config") ? ConfigStore.shared.config : Config()
        // Test images don't change with the system's light/dark appearance.
        if !args.contains("--use-config") { config.theme = ThemeSpec(light: Theme.defaultName, dark: Theme.defaultName) }
        let fontSize = CGFloat(value("--font-size", Int(config.fontSize)))
        let command = args.firstIndex(of: "--").map { args[($0 + 1)...].joined(separator: " ") } ?? "true"
        // `--shell`: the login shell with integration, instead of a command;
        // `--resize COLSxROWS` after `--wait MS`, then `--settle MS`; prints the screen text.
        let shell = args.contains("--shell")
        // `--resize 25x12,90x12`: one or more sizes, visited in order.
        let resize: [(Int, Int)] = args.firstIndex(of: "--resize").map { i in
            guard i + 1 < args.count else { return [] }
            return args[i + 1].split(separator: ",").compactMap { step in
                let n = step.split(separator: "x").compactMap { Int($0) }
                return n.count == 2 ? (n[0], n[1]) : nil
            }
        } ?? []
        let frames = value("--render-frames", 0)
        // `--scroll-up N --offset PERCENT`: N rows into the history, and that
        // share of a row further (smooth scrolling's in-between position).
        scrollUp = value("--scroll-up", 0)
        offsetPercent = value("--offset", 0)

        do {
            try render(command: shell ? nil : command, config: config, cols: cols, rows: rows, fontSize: fontSize,
                       to: output, benchFrames: frames, resize: resize,
                       wait: Double(value("--wait", 1500)) / 1000, settle: Double(value("--settle", 800)) / 1000)
            print(output)
            exit(0)
        } catch {
            FileHandle.standardError.write("snapshot failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    nonisolated(unsafe) private static var scrollUp = 0
    nonisolated(unsafe) private static var offsetPercent = 0

    private final class ExitWaiter: TerminalSessionDelegate {
        var exited = false
        func sessionNeedsRender(_ session: TerminalSession) {}
        func sessionTitleChanged(_ session: TerminalSession, title: String) {}
        func sessionBell(_ session: TerminalSession) {}
        func sessionProgramStatusChanged(_ session: TerminalSession) {}
        func sessionExited(_ session: TerminalSession, status: Int32) { exited = true }
    }

    private static func render(command: String?, config: Config, cols: Int, rows: Int, fontSize: CGFloat,
                               to path: String, benchFrames: Int, resize: [(Int, Int)] = [],
                               wait: Double = 0, settle: Double = 0) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw TerminalError.libghostty("no Metal device") }
        let scale: CGFloat = 2
        let fonts = FontSet(family: config.fontFamily, pointSize: fontSize, scale: scale)
        let initStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let renderer = try TerminalRenderer(device: device, fonts: fonts)
        renderer.selectionColor = config.resolvedTheme.selection
        renderer.ligatures = config.ligatures
        renderer.backgroundOpacity = config.backgroundOpacity
        if benchFrames > 0 {
            FileHandle.standardError.write(String(format: "renderer init: %.1f ms\n",
                Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - initStart) / 1e6).data(using: .utf8)!)
        }

        let session = try TerminalSession(size: GridSize(
            cols: UInt16(cols), rows: UInt16(rows),
            widthPx: UInt16(cols * fonts.cellWidth), heightPx: UInt16(rows * fonts.cellHeight)), config: config)
        let waiter = ExitWaiter()
        session.delegate = waiter
        session.setCellSize(widthPx: UInt32(fonts.cellWidth), heightPx: UInt32(fonts.cellHeight))
        try session.start(command: command)
        func run(for seconds: Double) {
            let until = Date().addingTimeInterval(seconds)
            while !waiter.exited, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        if command == nil {
            // An interactive shell never exits by itself.
            run(for: wait)
            var current = cols
            for (c, r) in resize {
                // A column per frame, as a drag or a split animation goes.
                while current != c {
                    current += c < current ? -1 : 1
                    session.resize(to: GridSize(cols: UInt16(current), rows: UInt16(r),
                                                widthPx: UInt16(current * fonts.cellWidth), heightPx: UInt16(r * fonts.cellHeight)),
                                   cellWidthPx: UInt32(fonts.cellWidth), cellHeightPx: UInt32(fonts.cellHeight))
                    run(for: 0.008)
                }
                run(for: settle)
            }
            session.selectAll()
            print(session.selectedText() ?? "", terminator: "\n----\n")
            session.clearSelection()
        } else {
            run(for: 10)
        }

        let p = config.padding
        renderer.origin = SIMD2(Float(p.left * scale), Float(p.top * scale))
        if scrollUp > 0 { session.scroll(rows: -scrollUp) }
        renderer.pixelOffset = Float(fonts.cellHeight * offsetPercent) / 100
        let width = Int((CGFloat(cols * fonts.cellWidth) + (p.left + p.right) * scale).rounded(.up))
        let height = Int((CGFloat(rows * fonts.cellHeight) + (p.top + p.bottom) * scale).rounded(.up))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { throw TerminalError.libghostty("texture") }
        renderer.renderOffscreen(session, into: texture)

        if benchFrames > 0 {
            // Forced full redraws (what a resize or split drag costs per frame), CPU + GPU.
            var times: [Double] = []
            for _ in 0..<benchFrames {
                let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                renderer.renderOffscreen(session, into: texture)
                times.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6)
            }
            times.sort()
            FileHandle.standardError.write(String(
                format: "full frame %dx%d: median %.2f ms, p95 %.2f ms\n",
                cols, rows, times[times.count / 2], times[times.count * 95 / 100]).data(using: .utf8)!)
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let image: CGImage? = pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?
                .makeImage()
        }
        guard let image,
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else { throw TerminalError.libghostty("png") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw TerminalError.libghostty("png write") }
    }
}
