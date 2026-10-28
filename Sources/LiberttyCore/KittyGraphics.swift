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
/// asks for, image pixels as RGBA, and how much the images may take.
public enum KittyGraphics {
    /// Image storage per screen: kitty's and Ghostty's default. A window's
    /// copy, liberttyd's and one restored from a snapshot all keep this much.
    public static let storageLimit: UInt64 = 320 << 20

    /// libghostty-vt asks the embedder to decode PNGs: ImageIO, once per process.
    public static func installDecoder() {
        guard !installed else { return }
        installed = true
        #if canImport(ImageIO)
        ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, unsafeBitCast(decodePNG, to: UnsafeRawPointer.self))
        #endif
    }

    nonisolated(unsafe) private static var installed = false

    /// liberttyd's copy keeps images too (a window that attaches gets them in
    /// the snapshot), but only what arrives inline or as a file: a temporary
    /// file or shared memory is deleted by whoever reads it first, and that
    /// must be the window.
    public static func enableForDaemon(on terminal: GhosttyTerminal) {
        installDecoder()
        var limit = storageLimit
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
