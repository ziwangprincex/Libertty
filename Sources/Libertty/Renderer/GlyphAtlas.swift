import CoreText
import Metal

/// Rasterized glyphs packed into one texture. Text glyphs are white coverage
/// masks tinted in the shader; color glyphs (emoji) keep their own colors.
final class GlyphAtlas {
    struct Entry {
        /// Region in the atlas, in pixels. Zero size means nothing to draw (space).
        var x: UInt16, y: UInt16, width: UInt16, height: UInt16
        /// Offset of the region from the cell's top-left corner, in pixels.
        var offsetX: Int16, offsetY: Int16
        var isColor: Bool
    }

    private(set) var texture: MTLTexture
    private(set) var size: Int
    private let device: MTLDevice
    private let fonts: FontSet
    /// Fast path for the common case: one codepoint, keyed by codepoint|style|span.
    private var scalarCache: [UInt64: Entry] = [:]
    private var clusterCache: [String: Entry] = [:]
    private var shelfX = 0, shelfY = 0, shelfHeight = 0
    /// Bumped when the atlas is wiped; renderers must rebuild cached instances.
    private(set) var generation = 0

    init(device: MTLDevice, fonts: FontSet, size: Int = 4096) {
        self.device = device
        self.fonts = fonts
        self.size = size
        texture = Self.makeTexture(device, size)
    }

    private static func makeTexture(_ device: MTLDevice, _ size: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)!
    }

    /// The most it grows to: one screen of distinct glyphs at a very large
    /// size (a few hundred CJK characters at 72 pt) must fit at once.
    private static let largest = 8192

    func entry(scalar: UInt32, style: FontSet.Style, span: Int) -> Entry? {
        let key = UInt64(scalar) | UInt64(style.rawValue) << 32 | UInt64(span) << 40
        if let hit = scalarCache[key] { return hit }
        let entry: Entry?
        if BoxDrawing.handles(scalar), let drawn = rasterizeBox(scalar) {
            // Same shape for every style: borders mustn't change weight with bold.
            entry = drawn
        } else {
            guard let s = Unicode.Scalar(scalar) else { return nil }
            entry = rasterize(String(Character(s)), style: style, span: span)
        }
        scalarCache[key] = entry
        return entry
    }

    /// Box drawing and block elements, drawn to fill exactly one cell.
    private func rasterizeBox(_ cp: UInt32) -> Entry? {
        let w = fonts.cellWidth, h = fonts.cellHeight
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let drew: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            // BoxDrawing works top-down like the grid.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            return BoxDrawing.draw(cp, in: ctx, width: w, height: h)
        }
        guard drew else { return nil }
        guard let origin = allocateOrReset(width: w, height: h) else { return nil }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(origin.x, origin.y, w, h), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
        }
        return Entry(x: UInt16(origin.x), y: UInt16(origin.y), width: UInt16(w), height: UInt16(h),
                     offsetX: 0, offsetY: 0, isColor: false)
    }

    private func allocateOrReset(width: Int, height: Int) -> (x: Int, y: Int)? {
        if let origin = allocate(width: width, height: height) { return origin }
        reset()
        return allocate(width: width, height: height)
    }

    func entry(cluster: String, style: FontSet.Style, span: Int) -> Entry? {
        let key = "\(style.rawValue)\(span)\u{0}\(cluster)"
        if let hit = clusterCache[key] { return hit }
        let entry = rasterize(cluster, style: style, span: span)
        clusterCache[key] = entry
        return entry
    }

    /// A specific glyph of the style's font (a ligature's contextual
    /// alternate), drawn at its cell; it may reach several cells left or right.
    func entry(glyph: CGGlyph, style: FontSet.Style) -> Entry? {
        let key = UInt64(glyph) | UInt64(style.rawValue) << 32 | 1 << 62
        if let hit = scalarCache[key] { return hit }
        let entry = rasterize(nil, glyph: glyph, style: style, span: 1)
        scalarCache[key] = entry
        return entry
    }

    private func rasterize(_ text: String, style: FontSet.Style, span: Int) -> Entry? {
        rasterize(text, glyph: nil, style: style, span: span)
    }

    private func rasterize(_ text: String?, glyph: CGGlyph?, style: FontSet.Style, span: Int) -> Entry? {
        let cellW = fonts.cellWidth, cellH = fonts.cellHeight
        // Draw into a slot larger than the cell so overhangs (italics, emoji,
        // powerline glyphs) survive, then keep only the inked bounding box.
        // Ligature glyphs reach up to three cells to either side.
        let pad = max(4, cellH / 3)
        let padX = glyph == nil ? pad : max(pad, cellW * 3)
        let slotW = cellW * span + padX * 2
        let slotH = cellH + pad * 2

        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): fonts.font(style),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text ?? " ", attributes: attrs))
        // Center wide glyphs (CJK, emoji) in their two cells instead of
        // pinning them left, so full-width text spaces evenly.
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let centering = span > 1 ? max(0, (CGFloat(cellW * span) - advance) / 2) : 0
        let isColor = glyph == nil && (CTLineGetGlyphRuns(line) as! [CTRun]).contains { run in
            let runAttrs = CTRunGetAttributes(run) as NSDictionary
            guard let font = runAttrs[kCTFontAttributeName] else { return false }
            return CTFontGetSymbolicTraits(font as! CTFont).contains(.traitColorGlyphs)
        }

        let bytesPerRow = slotW * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * slotH)
        let drew: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: slotW, height: slotH, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.setAllowsFontSmoothing(true)
            ctx.setShouldSmoothFonts(false)  // no stem darkening: weight matches AppKit
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            ctx.setAllowsFontSubpixelPositioning(true)
            ctx.setShouldSubpixelPositionFonts(true)
            // CoreGraphics' origin is bottom-left: baseline sits `baseline` px below the cell top.
            let origin = CGPoint(x: CGFloat(padX) + centering, y: CGFloat(slotH - pad - fonts.baseline))
            if let glyph {
                var g = glyph
                var position = origin
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                CTFontDrawGlyphs(fonts.font(style), &g, &position, 1, ctx)
            } else {
                ctx.textPosition = origin
                CTLineDraw(line, ctx)
            }
            return true
        }
        guard drew else { return nil }

        // Tight bounding box of inked pixels (alpha is byte 3 in BGRA).
        var minX = slotW, minY = slotH, maxX = -1, maxY = -1
        for y in 0..<slotH {
            let row = y * bytesPerRow
            for x in 0..<slotW where pixels[row + x * 4 + 3] != 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else {
            return Entry(x: 0, y: 0, width: 0, height: 0, offsetX: 0, offsetY: 0, isColor: false)
        }
        let w = maxX - minX + 1, h = maxY - minY + 1

        // When the atlas is full, start over (the renderer rebuilds every row
        // on a generation change); a glyph larger than the whole atlas is dropped.
        guard let origin = allocateOrReset(width: w, height: h) else { return nil }
        pixels.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(origin.x, origin.y, w, h), mipmapLevel: 0,
                withBytes: raw.baseAddress! + minY * bytesPerRow + minX * 4, bytesPerRow: bytesPerRow)
        }
        return Entry(x: UInt16(origin.x), y: UInt16(origin.y), width: UInt16(w), height: UInt16(h),
                     offsetX: Int16(minX - padX), offsetY: Int16(minY - pad), isColor: isColor)
    }

    /// Shelf packing with a 1px gutter so linear sampling never bleeds.
    private func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
        if shelfX + width + 1 > size {
            shelfY += shelfHeight + 1
            shelfX = 0
            shelfHeight = 0
        }
        guard shelfY + height + 1 <= size, width + 1 <= size else { return nil }
        defer {
            shelfX += width + 1
            shelfHeight = max(shelfHeight, height)
        }
        return (shelfX, shelfY)
    }

    /// Full: start over — in a texture twice as big the first time (memory
    /// is only taken as glyphs fill it), wiped after that.
    private func reset() {
        if size < Self.largest {
            size *= 2
            texture = Self.makeTexture(device, size)
        }
        scalarCache.removeAll(keepingCapacity: true)
        clusterCache.removeAll(keepingCapacity: true)
        shelfX = 0; shelfY = 0; shelfHeight = 0
        generation += 1
    }
}
