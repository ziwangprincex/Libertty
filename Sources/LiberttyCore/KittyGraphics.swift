import CGhosttyVt
#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import Dispatch
import FoundationEssentials  // not Foundation: on Linux that brings 45 MB of ICU
#else
import Foundation
#endif
#if canImport(ImageIO)
import ImageIO
#endif

/// Kitty graphics pieces both sides need: the PNG decoder libghostty-vt
/// asks for, image pixels as RGBA, and (liberttyd) putting the visible images
/// back into a window that attaches, since a snapshot carries text only.
public enum KittyGraphics {
    /// libghostty-vt asks the embedder to decode PNGs: ImageIO, once per process.
    public static func installDecoder() {
        guard !installed else { return }
        installed = true
        #if canImport(ImageIO)
        ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, unsafeBitCast(decodePNG, to: UnsafeRawPointer.self))
        #endif
    }

    nonisolated(unsafe) private static var installed = false

    /// liberttyd's copy keeps images too (to put them back on attach), but only
    /// what arrives inline or as a file: a temporary file or shared memory is
    /// deleted by whoever reads it first, and that must be the window.
    public static func enableForDaemon(on terminal: GhosttyTerminal) {
        installDecoder()
        var limit: UInt64 = 320 << 20
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &limit)
        var yes = true
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &yes)
    }

    /// An image's pixels as RGBA8 (from RGB, gray and gray+alpha too).
    public static func rgba(_ image: GhosttyKittyGraphicsImage, width: Int, height: Int) -> [UInt8]? {
        var format = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA, compression = GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE
        var data: UnsafePointer<UInt8>?
        var length = 0
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &format)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_COMPRESSION, &compression)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &data)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &length)
        guard let data, compression == GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE else { return nil }
        let count = width * height
        let source = UnsafeBufferPointer(start: data, count: length)
        var out = [UInt8](repeating: 255, count: count * 4)
        switch format {
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA, GHOSTTY_KITTY_IMAGE_FORMAT_PNG:
            guard length >= count * 4 else { return nil }
            out.withUnsafeMutableBufferPointer { _ = memcpy($0.baseAddress, data, count * 4) }
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGB:
            guard length >= count * 3 else { return nil }
            for i in 0..<count {
                out[i * 4] = source[i * 3]; out[i * 4 + 1] = source[i * 3 + 1]; out[i * 4 + 2] = source[i * 3 + 2]
            }
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA:
            guard length >= count * 2 else { return nil }
            for i in 0..<count {
                let v = source[i * 2]
                out[i * 4] = v; out[i * 4 + 1] = v; out[i * 4 + 2] = v; out[i * 4 + 3] = source[i * 2 + 1]
            }
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY:
            guard length >= count else { return nil }
            for i in 0..<count {
                let v = source[i]
                out[i * 4] = v; out[i * 4 + 1] = v; out[i * 4 + 2] = v
            }
        default:
            return nil
        }
        return out
    }

    /// The images on screen as kitty commands: each image once (RGBA, in
    /// chunks), then each placement at its cell, then the cursor back where
    /// it was. Fed to a window right after the snapshot, its replica shows
    /// them again. Placements scrolled into the history aren't included.
    public static func replay(_ terminal: GhosttyTerminal) -> [UInt8] {
        var graphics: GhosttyKittyGraphics?
        var generation: UInt64 = 0
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics) == GHOSTTY_SUCCESS,
              let graphics, ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION, &generation) == GHOSTTY_SUCCESS,
              generation != 0 else { return [] }
        var iterator: GhosttyKittyGraphicsPlacementIterator?
        guard ghostty_kitty_graphics_placement_iterator_new(nil, &iterator) == GHOSTTY_SUCCESS, let iterator else { return [] }
        defer { ghostty_kitty_graphics_placement_iterator_free(iterator) }
        var it: GhosttyKittyGraphicsPlacementIterator? = iterator
        guard ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &it) == GHOSTTY_SUCCESS else { return [] }

        var out: [UInt8] = []
        var sent = Set<UInt32>()
        func write(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        while ghostty_kitty_graphics_placement_next(iterator) {
            var imageID: UInt32 = 0, placementID: UInt32 = 0, z: Int32 = 0, isVirtual = false
            var columns: UInt32 = 0, rows: UInt32 = 0, xOffset: UInt32 = 0, yOffset: UInt32 = 0
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &imageID)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID, &placementID)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z, &z)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL, &isVirtual)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS, &columns)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS, &rows)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET, &xOffset)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET, &yOffset)
            guard let image = ghostty_kitty_graphics_image(graphics, imageID) else { continue }
            var info = GhosttyKittyGraphicsPlacementRenderInfo()
            info.size = MemoryLayout<GhosttyKittyGraphicsPlacementRenderInfo>.size
            let visible = !isVirtual && ghostty_kitty_graphics_placement_render_info(iterator, image, terminal, &info) == GHOSTTY_SUCCESS
                && info.viewport_visible
            guard isVirtual || visible else { continue }

            if !sent.contains(imageID) {
                var width: UInt32 = 0, height: UInt32 = 0
                _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width)
                _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height)
                guard width > 0, height > 0, let pixels = rgba(image, width: Int(width), height: Int(height)) else { continue }
                let b64 = Array(Data(pixels).base64EncodedString().utf8)
                var offset = 0
                repeat {
                    let end = min(b64.count, offset + 4096)
                    let more = end < b64.count ? 1 : 0
                    write(offset == 0 ? "\u{1b}_Ga=t,f=32,s=\(width),v=\(height),i=\(imageID),q=2,m=\(more);" : "\u{1b}_Gm=\(more);")
                    out.append(contentsOf: b64[offset..<end])
                    write("\u{1b}\\")
                    offset = end
                } while offset < b64.count
                sent.insert(imageID)
            }
            let size = (columns > 0 ? ",c=\(columns)" : "") + (rows > 0 ? ",r=\(rows)" : "")
            let id = placementID > 0 ? ",p=\(placementID)" : ""
            if isVirtual {
                // Its placeholder cells are in the snapshot already.
                write("\u{1b}_Ga=p,U=1,i=\(imageID)\(id)\(size),q=2\u{1b}\\")
            } else {
                write("\u{1b}[\(info.viewport_row + 1);\(info.viewport_col + 1)H")
                write("\u{1b}_Ga=p,i=\(imageID)\(id)\(size),x=\(info.source_x),y=\(info.source_y),w=\(info.source_width),"
                      + "h=\(info.source_height),X=\(xOffset),Y=\(yOffset),z=\(z),C=1,q=2\u{1b}\\")
            }
        }
        guard !out.isEmpty else { return [] }
        var cx: UInt16 = 0, cy: UInt16 = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx)
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cy)
        write("\u{1b}[\(cy + 1);\(cx + 1)H")
        return out
    }
}

#if canImport(ImageIO)
/// PNG → straight (not premultiplied) RGBA8, in a buffer from libghostty's allocator.
private let decodePNG: GhosttySysDecodePngFn = { _, allocator, data, length, out in
    guard let data, let out, length > 0 else { return false }
    let cfData = CFDataCreateWithBytesNoCopy(nil, data, length, kCFAllocatorNull)
    guard let cfData, let source = CGImageSourceCreateWithData(cfData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return false }
    let width = image.width, height = image.height
    guard width > 0, height > 0, width <= 16384, height <= 16384 else { return false }
    let bytes = width * height * 4
    guard let buffer = ghostty_alloc(allocator, bytes) else { return false }
    guard let context = CGContext(data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        ghostty_free(allocator, buffer, bytes)
        return false
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    // CoreGraphics only draws premultiplied; the protocol's RGBA is straight.
    for i in stride(from: 0, to: bytes, by: 4) {
        let a = UInt32(buffer[i + 3])
        guard a != 0, a != 255 else { continue }
        buffer[i] = UInt8(min(255, (UInt32(buffer[i]) * 255 + a / 2) / a))
        buffer[i + 1] = UInt8(min(255, (UInt32(buffer[i + 1]) * 255 + a / 2) / a))
        buffer[i + 2] = UInt8(min(255, (UInt32(buffer[i + 2]) * 255 + a / 2) / a))
    }
    out.pointee.width = UInt32(width)
    out.pointee.height = UInt32(height)
    out.pointee.data = buffer
    out.pointee.data_len = bytes
    return true
}
#endif
