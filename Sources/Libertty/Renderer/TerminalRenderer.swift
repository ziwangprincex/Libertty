import CGhosttyVt
import Metal
import QuartzCore

struct RectInstance {
    var rect: SIMD4<Float>
    var color: UInt32
    var pad: (UInt32, UInt32, UInt32) = (0, 0, 0)
}

struct GlyphInstance {
    var rect: SIMD4<Float>
    var uv: SIMD4<Float>
    var color: UInt32
    var flags: UInt32
    var pad: (UInt32, UInt32) = (0, 0)
}

struct Uniforms {
    var viewport: SIMD2<Float>
    var atlasSize: SIMD2<Float>
    var offset: SIMD2<Float> = .zero
}

/// Draws one terminal's render state into a CAMetalLayer.
///
/// Instances are cached per viewport row and only dirty rows are rebuilt, so a
/// frame where one line changed costs one line of work plus a memcpy.
final class TerminalRenderer {
    private struct Row {
        var rects: [RectInstance] = []
        var glyphs: [GlyphInstance] = []
        /// Column of each glyph, to find the one under the cursor.
        var glyphColumns: [UInt16] = []
        /// Columns where a wide character (CJK, emoji) starts: the cursor
        /// there covers both its cells.
        var wideColumns: Set<UInt16> = []
        /// Kitty Unicode placeholder cells (an image shows there instead).
        var placeholders: [KittyPlaceholders.Cell] = []
        /// Its cells' own backgrounds, as runs of one color (columns
        /// start..<end): what `window-padding-color = extend` carries out.
        var backgrounds: [(start: Int, end: Int, color: UInt32)] = []
        /// Not to be carried up or down (`extend`, after Ghostty): a cell in
        /// the default background (it's the padding's color already), a
        /// powerline glyph (drawn to fit its cell), or a prompt.
        var keepsPadding = false
    }

    /// `window-padding-color`: the padding in the background color, or in
    /// the colors of the cells at the grid's edges, carried out to the
    /// pane's edges (`extend`: not above or below a row that wouldn't look
    /// right so, on the normal screen; `extend-always`: every edge).
    enum PaddingColor: String, CaseIterable {
        case background, extend
        case extendAlways = "extend-always"
    }

    private final class FrameBuffers {
        var rects: MTLBuffer?
        var glyphs: MTLBuffer?
        var bands: MTLBuffer?
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let rectPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private(set) var fonts: FontSet
    private var atlas: GlyphAtlas

    private let state: GhosttyRenderState
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    private var rows: [Row] = []

    private let frames = [FrameBuffers(), FrameBuffers(), FrameBuffers()]
    private var frameIndex = 0
    private let inFlight = DispatchSemaphore(value: 2)

    private var scratchRects: [RectInstance] = []
    /// The padding above and below the grid in its edge rows' colors
    /// (`window-padding-color`): drawn first, where smooth scrolling doesn't move them.
    private var bandRects: [RectInstance] = []
    private var scratchGlyphs: [GlyphInstance] = []
    private var codepoints = [UInt32](repeating: 0, count: 32)

    /// Grid origin inside the drawable, in pixels.
    var origin = SIMD2<Float>(0, 0)

    /// Smooth scrolling: how far (drawable px, under one row) the content is
    /// moved up from the row grid. The row below the viewport shows through
    /// at the bottom, read from the terminal's grid (GridRowCells).
    var pixelOffset: Float = 0
    private var drawnOffset: Float = 0
    private var belowRow: Row?
    private var columnCount: UInt16 = 0
    private(set) var background = Theme.named(Theme.defaultName).background
    var selectionColor = Theme.named(Theme.defaultName).selection
    /// Below 1 the default background is translucent (`background-opacity`);
    /// cells with their own background color stay opaque.
    var backgroundOpacity: Double = 1
    var paddingColor = PaddingColor.background
    /// A full-screen program's screen: `extend` carries its edges anyway.
    private var alternateScreen = false
    /// Far enough past the grid to reach every drawable's edge (the GPU clips).
    private static let beyond: Float = 65536
    /// Find-in-scrollback matches in the viewport, drawn under the text.
    var searchHighlights: [SearchResult.Highlight] = []
    /// The cursor's blink phase (the view's timer flips it) and whether the
    /// last frame's cursor blinks at all (terminal modes, `cursor-style-blink`).
    var blinkOn = true
    private(set) var cursorBlinks = false

    /// The link under the pointer while ⌘ is held, underlined.
    var linkSpans: [TerminalLink.Span] = []

    // Kitty graphics: this frame's placements, and textures by image id.
    private let imagePipeline: MTLRenderPipelineState
    private var imageDraws: [KittyImages.Draw] = []
    private var virtualPlacements: [KittyPlaceholders.Virtual] = []
    /// Images placed by placeholder cells this frame.
    private var placeholderDraws: [KittyImages.Draw] = []
    private var imageTextures: [UInt32: (generation: UInt64, texture: MTLTexture)] = [:]
    /// Input-method composition (e.g. Pinyin before a candidate is chosen),
    /// drawn underlined at the cursor over whatever the grid has there.
    var preedit = ""

    init(device: MTLDevice, fonts: FontSet) throws {
        self.device = device
        self.fonts = fonts
        guard let queue = device.makeCommandQueue() else { throw TerminalError.libghostty("command queue") }
        self.queue = queue
        atlas = GlyphAtlas(device: device, fonts: fonts)

        let library = try device.makeLibrary(source: shaderSource, options: nil)
        func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            let color = desc.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .one  // shaders output premultiplied color
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        rectPipeline = try pipeline("rect_vertex", "rect_fragment")
        glyphPipeline = try pipeline("glyph_vertex", "glyph_fragment")
        imagePipeline = try pipeline("image_vertex", "image_fragment")

        var s: GhosttyRenderState?
        guard ghostty_render_state_new(nil, &s) == GHOSTTY_SUCCESS, let s,
              ghostty_render_state_row_iterator_new(nil, &rowIterator) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_cells_new(nil, &rowCells) == GHOSTTY_SUCCESS
        else { throw TerminalError.libghostty("render state") }
        state = s
    }

    deinit {
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(state)
    }

    func setFonts(_ fonts: FontSet) {
        self.fonts = fonts
        atlas = GlyphAtlas(device: device, fonts: fonts)
        rows.removeAll()
        rowsGeneration = -1
    }

    // MARK: Frame

    /// Draw a frame if anything changed. `force` redraws even when the
    /// terminal is clean (resize, focus, font change). Returns whether a frame
    /// was presented.
    @discardableResult
    func render(_ session: TerminalSession, into layer: CAMetalLayer, focused: Bool, force: Bool,
                onPresented: ((CFTimeInterval) -> Void)? = nil) -> Bool {
        if prepare(session, focused: focused, force: force) { contentVersion &+= 1 }
        // Each layer showing this terminal (the pane, a picture in picture)
        // gets every new frame, whichever display link built it.
        let key = ObjectIdentifier(layer)
        guard force || presentedVersions[key] != contentVersion else { return false }
        presentedVersions[key] = contentVersion
        return present(into: layer, onPresented: onPresented)
    }

    /// Bumped whenever the instances change.
    private var contentVersion = 0
    private var presentedVersions: [ObjectIdentifier: Int] = [:]

    /// A layer that no longer shows this terminal.
    func forget(_ layer: CAMetalLayer) { presentedVersions[ObjectIdentifier(layer)] = nil }

    /// Render the current state into an offscreen texture and wait for the
    /// GPU (snapshots and visual tests).
    func renderOffscreen(_ session: TerminalSession, into texture: MTLTexture) {
        prepare(session, focused: true, force: true)
        contentVersion &+= 1
        inFlight.wait()
        guard let commands = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        encode(target: texture, commands: commands)
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        commands.commit()
        commands.waitUntilCompleted()
    }

    /// The current frame as an image (tab overview thumbnails), `width` ×
    /// `height` drawable pixels.
    func snapshotImage(_ session: TerminalSession, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        renderOffscreen(session, into: texture)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?
                .makeImage()
        }
    }

    /// Snapshot the session and rebuild instances. Returns false when there
    /// is nothing new to draw.
    @discardableResult
    private func prepare(_ session: TerminalSession, focused: Bool, force: Bool) -> Bool {
        session.updateRenderState(state)
        let highlights = session.searchResult.highlights
        let highlightsChanged = highlights != searchHighlights
        searchHighlights = highlights
        let imagesChanged = updateImages(session)

        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        let offsetChanged = pixelOffset != drawnOffset
        drawnOffset = pixelOffset
        // The composition's glyphs go into the atlas before the rows are
        // placed: one that fills it then wipes it before them, not after.
        warmPreedit()
        // Wiped since the rows were placed (by a composition, last frame):
        // they point at overwritten space, every one of them.
        let atlasMoved = atlas.generation != rowsGeneration
        let changed = dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE || force || highlightsChanged || imagesChanged || atlasMoved
        guard changed || offsetChanged else { return false }
        // Only the offset moved: the instances stand; the shader shifts them.
        if !changed, pixelOffset == 0 || belowRow != nil {
            if pixelOffset == 0 { belowRow = nil }
            assembleInstances(colors: defaultColors(), focused: lastFocused)
            return true
        }
        lastFocused = focused

        var cols: UInt16 = 0, rowCount: UInt16 = 0
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rowCount)
        columnCount = cols

        let colors = defaultColors()
        background = colors.background
        alternateScreen = session.renderedAlternateScreen

        let rebuildAll = dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL || rows.count != Int(rowCount) || force || atlasMoved
        if rows.count != Int(rowCount) { rows = Array(repeating: Row(), count: Int(rowCount)) }

        // Ligatures break at the cursor: the rows it left and entered are rebuilt.
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor)
        let now: (row: Int, col: Int)? = cursor.viewport_has_value ? (Int(cursor.viewport_y), Int(cursor.viewport_x)) : nil
        var extra = Set<Int>()
        if ligatures, now?.row != shapingCursor?.row || now?.col != shapingCursor?.col {
            if let old = shapingCursor?.row { extra.insert(old) }
            if let new = now?.row { extra.insert(new) }
        }
        shapingCursor = now

        var generation = atlas.generation
        rebuildRows(all: rebuildAll, colors: colors, also: extra)
        updateBelowRow(session, colors: colors)
        // The atlas was wiped mid-frame (full: a long run of new CJK, a big
        // font): every glyph placed before it points at overwritten space.
        // Again until a pass fits (a few at most: one pass is one screen).
        for _ in 0..<3 where atlas.generation != generation {
            generation = atlas.generation
            rebuildRows(all: true, colors: colors, also: [])
            updateBelowRow(session, colors: colors)
        }
        rowsGeneration = atlas.generation
        _ = ghostty_render_state_clean(state)
        updatePlaceholderDraws()

        assembleInstances(colors: colors, focused: focused)
        return true
    }

    private var lastFocused = true

    /// Images shown by placeholder cells, from this frame's rows.
    private func updatePlaceholderDraws() {
        guard !virtualPlacements.isEmpty else {
            placeholderDraws = []
            return
        }
        placeholderDraws = rows.enumerated().flatMap { y, row in
            row.placeholders.isEmpty ? [] : KittyPlaceholders.draws(row.placeholders, y: y, virtuals: virtualPlacements,
                                                                     cellWidth: fonts.cellWidth, cellHeight: fonts.cellHeight)
        }
    }

    /// This frame's 256 colors (underline colors may name one).
    private var framePalette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)

    /// SGR 58: the underline's own color, when a program set one (Neovim's diagnostics).
    private func underlineColor(_ style: GhosttyStyle) -> UInt32? {
        let c = style.underline_color
        switch c.tag {
        case GHOSTTY_STYLE_COLOR_PALETTE:
            let p = framePalette[Int(c.value.palette)]
            return RGB(p.r, p.g, p.b).packed()
        case GHOSTTY_STYLE_COLOR_RGB:
            return RGB(c.value.rgb.r, c.value.rgb.g, c.value.rgb.b).packed()
        default:
            return nil
        }
    }

    /// The row under the viewport, while smooth scrolling shows part of it.
    private func updateBelowRow(_ session: TerminalSession, colors: Colors) {
        guard pixelOffset > 0 else {
            belowRow = nil
            return
        }
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        _ = palette.withUnsafeMutableBufferPointer { ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE, $0.baseAddress) }
        let cols = Int(columnCount)
        belowRow = session.withRowBelowViewport { terminal, y in
            var cells = GridRowCells(terminal: terminal, y: y, cols: cols, palette: palette)
            return buildRow(y: rows.count, colors: colors, selection: nil, cells: &cells)
        }
    }

    /// Placements to draw, uploading images whose pixels changed. Returns
    /// whether anything about them differs from the last frame.
    private func updateImages(_ session: TerminalSession) -> Bool {
        let collected = session.kittyImages(cellWidth: fonts.cellWidth, cellHeight: fonts.cellHeight) { id, generation in
            imageTextures[id]?.generation != generation
        }
        let draws = collected.draws, pixels = collected.pixels
        let virtualsChanged = collected.virtuals.map(\.imageID) != virtualPlacements.map(\.imageID)
            || collected.virtuals.map(\.generation) != virtualPlacements.map(\.generation)
        virtualPlacements = collected.virtuals
        for (id, (generation, image)) in pixels {
            if let texture = KittyImages.texture(image, device: device) { imageTextures[id] = (generation, texture) }
        }
        // Images no longer placed anywhere visible give their memory back.
        if imageTextures.count > draws.count + virtualPlacements.count + 8 {
            let live = Set(draws.map(\.imageID) + virtualPlacements.map(\.imageID))
            imageTextures = imageTextures.filter { live.contains($0.key) }
        }
        guard draws != imageDraws || virtualsChanged else { return false }
        imageDraws = draws
        return true
    }

    private struct Colors {
        var background: RGB
        var foreground: RGB
        var cursor: RGB
    }

    private func defaultColors() -> Colors {
        var bg = GhosttyColorRgb(), fg = GhosttyColorRgb(), cursor = GhosttyColorRgb()
        var hasCursor = false
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, &bg)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, &fg)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR_HAS_VALUE, &hasCursor)
        if hasCursor { _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR, &cursor) }
        let foreground = RGB(fg.r, fg.g, fg.b)
        return Colors(background: RGB(bg.r, bg.g, bg.b), foreground: foreground,
                      cursor: hasCursor ? RGB(cursor.r, cursor.g, cursor.b) : foreground)
    }

    // MARK: Rows → instances

    private func rebuildRows(all: Bool, colors: Colors, also extra: Set<Int>) {
        guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator) == GHOSTTY_SUCCESS
        else { return }
        // For underline colors given as palette entries (SGR 58:5).
        _ = framePalette.withUnsafeMutableBufferPointer {
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE, $0.baseAddress)
        }
        var y = 0
        while ghostty_render_state_row_iterator_next(rowIterator), y < rows.count {
            defer { y += 1 }
            if !all, !extra.contains(y) {
                var rowDirty = false
                _ = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
                if !rowDirty { continue }
            }
            guard ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells) == GHOSTTY_SUCCESS
            else { continue }
            var selection = GhosttyRenderStateRowSelection()
            selection.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
            let selected = ghostty_render_state_row_get(
                rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
            var cells = StateRowCells(cells: rowCells)
            rows[y] = buildRow(y: y, colors: colors,
                               selection: selected ? Int(selection.start_x)...Int(selection.end_x) : nil, cells: &cells)
            // A prompt's row keeps the padding above or below it as it is.
            if paddingColor == .extend, y == 0 || y == rows.count - 1, !rows[y].keepsPadding {
                var raw: GhosttyRow = 0
                var prompt = GHOSTTY_ROW_SEMANTIC_NONE
                if ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &raw) == GHOSTTY_SUCCESS {
                    _ = ghostty_row_get(raw, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &prompt)
                }
                if prompt != GHOSTTY_ROW_SEMANTIC_NONE { rows[y].keepsPadding = true }
            }
        }
    }

    /// `font-feature = -calt` (or -liga) turns these off.
    var ligatures = true

    /// A printable ASCII cell whose glyph may become a ligature's alternate.
    private struct AsciiCell {
        var x: Int
        var code: UInt16
        var style: FontSet.Style
        var color: UInt32
        var left: Float
        var top: Float
    }
    private var asciiCells: [AsciiCell] = []
    /// The cursor's cell as of this frame's rows, and the row being built.
    private var shapingCursor: (row: Int, col: Int)?
    private var buildingRow = -1

    /// Powerline's shapes drawn to fit their cells (Ghostty's list): carried
    /// into the padding, they'd stretch.
    private static func isPowerline(_ cp: UInt32) -> Bool {
        switch cp {
        case 0xE0B0...0xE0C8, 0xE0CA, 0xE0CC...0xE0D2, 0xE0D4: true
        default: false
        }
    }

    /// Characters ligatures are made of; a word needs two in a row to be shaped.
    private static func ligaturePart(_ c: UInt16) -> Bool {
        switch c {
        case 0x21, 0x23...0x26, 0x2A, 0x2B, 0x2D...0x2F, 0x3A...0x3F, 0x40, 0x5C, 0x5E, 0x5F, 0x7C, 0x7E,
             0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D: true
        default: false
        }
    }

    /// Emit the row's ASCII glyphs, shaping words like `->`, `!==`, `|>`.
    private func flushAscii(into row: inout Row) {
        var start = 0
        let cursorX = buildingRow == shapingCursor?.row ? shapingCursor?.col : nil
        while start < asciiCells.count {
            // A word: consecutive cells of one style and color, never across
            // the cursor (its block redraws one cell's glyph), as Ghostty splits runs.
            var end = start + 1
            while end < asciiCells.count, asciiCells[end].x == asciiCells[end - 1].x + 1,
                  asciiCells[end].style == asciiCells[start].style, asciiCells[end].color == asciiCells[start].color,
                  asciiCells[end].x != cursorX, asciiCells[end - 1].x != cursorX { end += 1 }
            var alternates: [CGGlyph?]?
            if ligatures, end - start >= 2,
               (start + 1..<end).contains(where: { Self.ligaturePart(asciiCells[$0].code) && Self.ligaturePart(asciiCells[$0 - 1].code) }) {
                alternates = fonts.contextualGlyphs(asciiCells[start..<end].map(\.code), style: asciiCells[start].style)
            }
            for i in start..<end {
                let cell = asciiCells[i]
                let entry = alternates?[i - start].flatMap { atlas.entry(glyph: $0, style: cell.style) }
                    ?? atlas.entry(scalar: UInt32(cell.code), style: cell.style, span: 1)
                guard let e = entry, e.width > 0 else { continue }
                row.glyphs.append(GlyphInstance(
                    rect: SIMD4(cell.left + Float(e.offsetX), cell.top + Float(e.offsetY), Float(e.width), Float(e.height)),
                    uv: SIMD4(Float(e.x), Float(e.y), Float(e.width), Float(e.height)),
                    color: cell.color, flags: e.isColor ? 1 : 0))
                row.glyphColumns.append(UInt16(cell.x))
            }
            start = end
        }
        asciiCells.removeAll(keepingCapacity: true)
    }

    private func buildRow<Cells: RowCellSource>(y: Int, colors: Colors, selection: ClosedRange<Int>?,
                                                cells: inout Cells) -> Row {
        buildingRow = y
        var row = Row()
        let cw = Float(fonts.cellWidth), ch = Float(fonts.cellHeight)
        let top = origin.y + Float(y) * ch
        var x = 0
        asciiCells.removeAll(keepingCapacity: true)

        while cells.next() {
            defer { x += 1 }
            let left = origin.x + Float(x) * cw

            let graphemes = cells.graphemeCount
            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.size
            _ = cells.style(&style)
            // The cell's code points, read once (a single one without the array).
            var cp: UInt32 = 0
            if graphemes == 1 {
                cp = cells.firstCodepoint()
            } else if graphemes > 1 {
                let count = Int(graphemes)
                if codepoints.count < count { codepoints = [UInt32](repeating: 0, count: count) }
                codepoints.withUnsafeMutableBufferPointer { cells.codepoints($0) }
                cp = codepoints[0]
            }
            if cp == KittyPlaceholders.codepoint {
                // An image cell: nothing to draw as text.
                if graphemes == 1 { codepoints[0] = cp }
                row.placeholders.append(KittyPlaceholders.cell(x: x, style: style, codepoints: codepoints[0..<Int(graphemes)]))
                continue
            }

            var fg = colors.foreground
            if graphemes > 0 || style.inverse, let color = cells.foreground() { fg = color }
            var bg = cells.background()
            // Its own background, as Ghostty judges whether a row may be carried.
            let ownBackground = bg
            if style.inverse {
                (fg, bg) = (bg ?? colors.background, fg)
            }

            let span = graphemes > 0 && cells.isWide ? 2 : 1
            if span == 2 { row.wideColumns.insert(UInt16(x)) }

            if let bg {
                let color = bg.packed()
                row.rects.append(RectInstance(rect: SIMD4(left, top, cw * Float(span), ch), color: color))
                if paddingColor != .background {
                    // (A wide character's second cell is inside its run already.)
                    if let last = row.backgrounds.last, last.end >= x, last.color == color {
                        row.backgrounds[row.backgrounds.count - 1].end = max(last.end, x + span)
                    } else {
                        row.backgrounds.append((x, x + span, color))
                    }
                }
            }
            if paddingColor != .background, ownBackground == nil || ownBackground == colors.background {
                row.keepsPadding = true
            }
            if paddingColor != .background, graphemes > 0, Self.isPowerline(cp) { row.keepsPadding = true }

            guard graphemes > 0, !style.invisible else { continue }
            let fgColor = fg.packed(alpha: style.faint ? 128 : 255)

            var fontStyle: FontSet.Style = []
            if style.bold { fontStyle.insert(.bold) }
            if style.italic { fontStyle.insert(.italic) }

            let entry: GlyphAtlas.Entry?
            if graphemes == 1 {
                if cp > 0x20, cp < 0x7F, span == 1 {
                    // Drawn after the row, once ligatures are known.
                    asciiCells.append(AsciiCell(x: x, code: UInt16(cp), style: fontStyle, color: fgColor, left: left, top: top))
                    appendDecorations(style: style, color: fgColor, left: left, top: top, width: cw, into: &row)
                    continue
                }
                entry = atlas.entry(scalar: cp, style: fontStyle, span: span)
            } else {
                let count = Int(graphemes)  // read into `codepoints` above
                var cluster = String.UnicodeScalarView()
                for cp in codepoints[0..<count] { if let s = Unicode.Scalar(cp) { cluster.append(s) } }
                entry = atlas.entry(cluster: String(cluster), style: fontStyle, span: span)
            }

            if let e = entry, e.width > 0 {
                row.glyphs.append(GlyphInstance(
                    rect: SIMD4(left + Float(e.offsetX), top + Float(e.offsetY), Float(e.width), Float(e.height)),
                    uv: SIMD4(Float(e.x), Float(e.y), Float(e.width), Float(e.height)),
                    color: fgColor, flags: e.isColor ? 1 : 0))
                row.glyphColumns.append(UInt16(x))
            }

            appendDecorations(style: style, color: fgColor, left: left, top: top, width: cw * Float(span), into: &row)
        }

        flushAscii(into: &row)

        // The edge cells' colors out to the pane's sides.
        if paddingColor != .background {
            if let first = row.backgrounds.first, first.start == 0, origin.x > 0 {
                row.rects.append(RectInstance(rect: SIMD4(0, top, origin.x, ch), color: first.color))
            }
            if let last = row.backgrounds.last, last.end >= x {
                row.rects.append(RectInstance(rect: SIMD4(origin.x + Float(x) * cw, top, Self.beyond, ch), color: last.color))
            }
        }

        // Selection sits over cell backgrounds and under the text.
        if let selection {
            row.rects.append(RectInstance(
                rect: SIMD4(origin.x + Float(selection.lowerBound) * cw, top, Float(selection.count) * cw, ch),
                color: selectionColor.packed()))
        }
        return row
    }

    private func appendDecorations(style: GhosttyStyle, color: UInt32, left: Float, top: Float,
                                   width: Float, into row: inout Row) {
        let thickness = Float(fonts.underlineThickness)
        if style.underline != Int32(GHOSTTY_SGR_UNDERLINE_NONE.rawValue) {
            let y = top + Float(fonts.underlinePosition)
            let line = underlineColor(style) ?? color
            switch style.underline {
            case Int32(GHOSTTY_SGR_UNDERLINE_DOUBLE.rawValue):
                row.rects.append(RectInstance(rect: SIMD4(left, y, width, thickness), color: line))
                row.rects.append(RectInstance(rect: SIMD4(left, y - thickness * 2, width, thickness), color: line))
            case Int32(GHOSTTY_SGR_UNDERLINE_CURLY.rawValue):
                // A wave, one period per cell, in steps a pixel or two wide.
                let step = max(1, Float(fonts.scale)), amplitude = max(thickness, Float(fonts.cellHeight) / 16)
                let period = Float(fonts.cellWidth)
                var x: Float = 0
                while x < width {
                    let phase = (left + x - origin.x).truncatingRemainder(dividingBy: period) / period
                    let dy = amplitude * sin(phase * 2 * .pi)
                    row.rects.append(RectInstance(rect: SIMD4(left + x, y - dy, min(step, width - x), thickness), color: line))
                    x += step
                }
            case Int32(GHOSTTY_SGR_UNDERLINE_DOTTED.rawValue), Int32(GHOSTTY_SGR_UNDERLINE_DASHED.rawValue):
                let dotted = style.underline == Int32(GHOSTTY_SGR_UNDERLINE_DOTTED.rawValue)
                let on = dotted ? max(thickness, Float(fonts.scale)) : Float(fonts.cellWidth) / 2
                let gap = dotted ? on : Float(fonts.cellWidth) / 4
                var x: Float = 0
                while x < width {
                    row.rects.append(RectInstance(rect: SIMD4(left + x, y, min(on, width - x), thickness), color: line))
                    x += on + gap
                }
            default:
                row.rects.append(RectInstance(rect: SIMD4(left, y, width, thickness), color: line))
            }
        }
        if style.strikethrough {
            row.rects.append(RectInstance(
                rect: SIMD4(left, top + Float(fonts.strikethroughPosition), width, thickness), color: color))
        }
        if style.overline {
            row.rects.append(RectInstance(rect: SIMD4(left, top, width, thickness), color: color))
        }
    }

    // MARK: Cursor & assembly

    private func assembleInstances(colors: Colors, focused: Bool) {
        scratchRects.removeAll(keepingCapacity: true)
        scratchGlyphs.removeAll(keepingCapacity: true)
        // Above the first row and below the last (or the one smooth
        // scrolling shows under it), their cells' colors.
        bandRects.removeAll(keepingCapacity: true)
        if paddingColor != .background, let first = rows.first, let last = belowRow ?? rows.last {
            let always = paddingColor == .extendAlways || alternateScreen
            let cw = Float(fonts.cellWidth)
            func carry(_ row: Row, from y: Float, height: Float) {
                for run in row.backgrounds {
                    let left = run.start == 0 ? 0 : origin.x + Float(run.start) * cw
                    let right = run.end >= Int(columnCount) ? origin.x + Float(columnCount) * cw + Self.beyond
                        : origin.x + Float(run.end) * cw
                    bandRects.append(RectInstance(rect: SIMD4(left, y, right - left, height), color: run.color))
                }
            }
            if origin.y > 0, always || !first.keepsPadding { carry(first, from: 0, height: origin.y) }
            if always || !last.keepsPadding {
                carry(last, from: origin.y + Float(rows.count) * Float(fonts.cellHeight), height: Self.beyond)
            }
        }
        for row in rows {
            scratchRects.append(contentsOf: row.rects)
        }
        if let belowRow { scratchRects.append(contentsOf: belowRow.rects) }
        if !searchHighlights.isEmpty {
            let cw = Float(fonts.cellWidth), ch = Float(fonts.cellHeight)
            // System find colors: yellow for every match, orange for the current one.
            let match = RGB(0xff, 0xd6, 0x0a).packed(alpha: 0x70), current = RGB(0xff, 0x9f, 0x0a).packed(alpha: 0xc0)
            for h in searchHighlights where h.row < rows.count {
                scratchRects.append(RectInstance(
                    rect: SIMD4(origin.x + Float(h.columns.lowerBound) * cw, origin.y + Float(h.row) * ch,
                                Float(h.columns.count) * cw, ch),
                    color: h.selected ? current : match))
            }
        }
        if !linkSpans.isEmpty {
            let cw = Float(fonts.cellWidth), ch = Float(fonts.cellHeight)
            let thickness = max(Float(fonts.underlineThickness), Float(fonts.scale))
            for span in linkSpans where span.row < rows.count {
                scratchRects.append(RectInstance(
                    rect: SIMD4(origin.x + Float(span.columns.lowerBound) * cw,
                                origin.y + Float(span.row) * ch + Float(fonts.underlinePosition),
                                Float(span.columns.count) * cw, thickness),
                    color: colors.foreground.packed()))
            }
        }

        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor)

        var cursorGlyph: GlyphInstance?
        cursorBlinks = cursor.blinking && focused && preedit.isEmpty
        if !preedit.isEmpty, cursor.viewport_has_value {
            appendPreedit(at: cursor, colors: colors)
        } else if cursorBlinks, !blinkOn {
            // The off half of a blink: no cursor this frame.
        } else if cursor.visible, cursor.viewport_has_value, Int(cursor.viewport_y) < rows.count {
            let row = rows[Int(cursor.viewport_y)]
            // On a wide character's second cell: the character's first. On a
            // wide character: both its cells (Ghostty's way), so the block
            // doesn't cut it in half and hide the rest.
            let column = cursor.wide_tail && cursor.viewport_x > 0 ? cursor.viewport_x - 1 : cursor.viewport_x
            let cells: Float = row.wideColumns.contains(column) ? 2 : 1
            let cw = Float(fonts.cellWidth), ch = Float(fonts.cellHeight)
            let left = origin.x + Float(column) * cw
            let top = origin.y + Float(cursor.viewport_y) * ch
            let width = cw * cells
            let color = colors.cursor.packed()
            let thin = max(1, Float(fonts.scale * 1.5).rounded())

            var style = cursor.visual_style
            if !focused { style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW }
            switch style {
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
                scratchRects.append(RectInstance(rect: SIMD4(left, top, width, ch), color: color))
                // Redraw the glyph under the block in the background color so it stays legible.
                if let i = row.glyphColumns.firstIndex(of: column) {
                    var g = row.glyphs[i]
                    if g.flags & 1 == 0 { g.color = colors.background.packed() }
                    cursorGlyph = g
                }
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
                scratchRects.append(RectInstance(rect: SIMD4(left, top, thin, ch), color: color))
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
                scratchRects.append(RectInstance(rect: SIMD4(left, top + ch - thin, width, thin), color: color))
            default:  // hollow block
                scratchRects.append(RectInstance(rect: SIMD4(left, top, width, thin), color: color))
                scratchRects.append(RectInstance(rect: SIMD4(left, top + ch - thin, width, thin), color: color))
                scratchRects.append(RectInstance(rect: SIMD4(left, top, thin, ch), color: color))
                scratchRects.append(RectInstance(rect: SIMD4(left + width - thin, top, thin, ch), color: color))
            }
        }

        for row in rows {
            scratchGlyphs.append(contentsOf: row.glyphs)
        }
        if let belowRow { scratchGlyphs.append(contentsOf: belowRow.glyphs) }
        if let cursorGlyph { scratchGlyphs.append(cursorGlyph) }
        if !preedit.isEmpty { scratchGlyphs.append(contentsOf: preeditGlyphs) }
    }

    // MARK: GPU

    /// Lay the composition out cell by cell from the cursor: an opaque backing
    /// so the grid underneath doesn't show through, the text, and an underline.
    /// The atlas generation the rows' glyphs were placed in.
    private var rowsGeneration = -1

    /// The composition's glyphs, rasterized ahead (appendPreedit then finds them).
    private func warmPreedit() {
        for character in preedit {
            let span = character.unicodeScalars.first.map(Self.isWide) == true ? 2 : 1
            let scalars = character.unicodeScalars
            _ = scalars.count == 1
                ? atlas.entry(scalar: scalars.first!.value, style: [], span: span)
                : atlas.entry(cluster: String(character), style: [], span: span)
        }
    }

    private func appendPreedit(at cursor: GhosttyRenderStateCursor, colors: Colors) {
        let cw = Float(fonts.cellWidth), ch = Float(fonts.cellHeight)
        let top = origin.y + Float(cursor.viewport_y) * ch
        var left = origin.x + Float(cursor.viewport_x) * cw
        let start = left
        var glyphs: [GlyphInstance] = []
        for character in preedit {
            let span = character.unicodeScalars.first.map(Self.isWide) == true ? 2 : 1
            let scalars = character.unicodeScalars
            let entry = scalars.count == 1
                ? atlas.entry(scalar: scalars.first!.value, style: [], span: span)
                : atlas.entry(cluster: String(character), style: [], span: span)
            if let e = entry, e.width > 0 {
                glyphs.append(GlyphInstance(
                    rect: SIMD4(left + Float(e.offsetX), top + Float(e.offsetY), Float(e.width), Float(e.height)),
                    uv: SIMD4(Float(e.x), Float(e.y), Float(e.width), Float(e.height)),
                    color: colors.foreground.packed(), flags: e.isColor ? 1 : 0))
            }
            left += cw * Float(span)
        }
        let width = left - start
        scratchRects.append(RectInstance(rect: SIMD4(start, top, width, ch), color: colors.background.packed()))
        scratchRects.append(RectInstance(
            rect: SIMD4(start, top + Float(fonts.underlinePosition), width, Float(fonts.underlineThickness)),
            color: colors.cursor.packed()))
        // Composition sits above the grid's glyphs: append after them in assembleInstances.
        preeditGlyphs = glyphs
    }

    private var preeditGlyphs: [GlyphInstance] = []

    /// East Asian wide and emoji presentation ranges, for laying out
    /// composition text that hasn't reached the terminal (which would
    /// otherwise decide widths) yet.
    private static func isWide(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            true
        default:
            false
        }
    }

    // MARK: GPU

    private func present(into layer: CAMetalLayer, onPresented: ((CFTimeInterval) -> Void)? = nil) -> Bool {
        inFlight.wait()
        guard let drawable = layer.nextDrawable(),
              let commands = queue.makeCommandBuffer() else {
            inFlight.signal()
            return false
        }
        if let onPresented { drawable.addPresentedHandler { onPresented($0.presentedTime) } }
        encode(target: drawable.texture, commands: commands)

        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        if layer.presentsWithTransaction {
            // Live resize: present inside the current Core Animation transaction
            // so the window edge and the grid move together, without stretching.
            // The drawable must be presented this way whenever the flag is on:
            // a command-buffer present is never released, and the next
            // `nextDrawable()` then stalls for its full one-second timeout.
            commands.commit()
            commands.waitUntilScheduled()
            drawable.present()
        } else {
            commands.present(drawable)
            commands.commit()
        }
        return true
    }

    private func encode(target: MTLTexture, commands: MTLCommandBuffer) {
        let frame = frames[frameIndex]
        frameIndex = (frameIndex + 1) % frames.count

        let rectBuffer = upload(scratchRects, into: &frame.rects)
        let glyphBuffer = upload(scratchGlyphs, into: &frame.glyphs)
        let bandBuffer = upload(bandRects, into: &frame.bands)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // Premultiplied, as the layer composites it.
        let a = backgroundOpacity
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.r) / 255 * a, green: Double(background.g) / 255 * a,
            blue: Double(background.b) / 255 * a, alpha: a)

        var uniforms = Uniforms(
            viewport: SIMD2(Float(target.width), Float(target.height)),
            atlasSize: SIMD2(Float(atlas.size), Float(atlas.size)),
            offset: SIMD2(0, -drawnOffset))

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let bandBuffer, !bandRects.isEmpty {
            // In place, outside the scrolling rows' scissor.
            var still = uniforms
            still.offset = .zero
            encoder.setRenderPipelineState(rectPipeline)
            encoder.setVertexBuffer(bandBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&still, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: bandRects.count)
        }
        if drawnOffset > 0, !rows.isEmpty {
            // Moved rows stay inside the grid (not over the padding).
            let top = max(0, Int(origin.y)), height = Int(Float(rows.count) * Float(fonts.cellHeight))
            encoder.setScissorRect(MTLScissorRect(x: 0, y: top, width: target.width,
                                                  height: max(1, min(height, target.height - top))))
        }
        drawImages(.belowBackground, encoder, &uniforms)
        if let rectBuffer, !scratchRects.isEmpty {
            encoder.setRenderPipelineState(rectPipeline)
            encoder.setVertexBuffer(rectBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: scratchRects.count)
        }
        drawImages(.belowText, encoder, &uniforms)
        if let glyphBuffer, !scratchGlyphs.isEmpty {
            encoder.setRenderPipelineState(glyphPipeline)
            encoder.setVertexBuffer(glyphBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: scratchGlyphs.count)
        }
        drawImages(.aboveText, encoder, &uniforms)
        encoder.endEncoding()
    }

    private struct ImageInstance {
        var rect: SIMD4<Float>
        var uv: SIMD4<Float>
    }

    private func drawImages(_ layer: KittyImages.Layer, _ encoder: MTLRenderCommandEncoder, _ uniforms: inout Uniforms) {
        var pipelineSet = false
        for draw in imageDraws + placeholderDraws where draw.layer == layer {
            guard let texture = imageTextures[draw.imageID]?.texture else { continue }
            if !pipelineSet {
                encoder.setRenderPipelineState(imagePipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                pipelineSet = true
            }
            var instance = ImageInstance(rect: SIMD4(draw.rect.x + origin.x, draw.rect.y + origin.y, draw.rect.z, draw.rect.w),
                                         uv: draw.uv)
            encoder.setVertexBytes(&instance, length: MemoryLayout<ImageInstance>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private func upload<T>(_ items: [T], into slot: inout MTLBuffer?) -> MTLBuffer? {
        guard !items.isEmpty else { return slot }
        let bytes = items.count * MemoryLayout<T>.stride
        if slot == nil || slot!.length < bytes {
            // Grow geometrically so steady-state frames never allocate.
            slot = device.makeBuffer(length: max(bytes, (slot?.length ?? 0) * 2, 64 * 1024),
                                     options: .storageModeShared)
        }
        guard let buffer = slot else { return nil }
        items.withUnsafeBytes { raw in
            buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: bytes)
        }
        return buffer
    }
}

/// Where `buildRow` reads a row's cells: the render state, or (for the row
/// smooth scrolling shows below the viewport) the terminal's grid.
private protocol RowCellSource {
    mutating func next() -> Bool
    var graphemeCount: UInt32 { get }
    /// False (and `style` untouched) for an unstyled cell.
    func style(_ style: inout GhosttyStyle) -> Bool
    func background() -> RGB?
    func foreground() -> RGB?
    var isWide: Bool { get }
    func firstCodepoint() -> UInt32
    func codepoints(_ buffer: UnsafeMutableBufferPointer<UInt32>)
}

private struct StateRowCells: RowCellSource {
    let cells: GhosttyRenderStateRowCells?

    func next() -> Bool { ghostty_render_state_row_cells_next(cells) }

    var graphemeCount: UInt32 {
        var n: UInt32 = 0
        _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &n)
        return n
    }

    func style(_ style: inout GhosttyStyle) -> Bool {
        var has = false
        _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &has)
        if has { _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) }
        return has
    }

    func background() -> RGB? {
        var c = GhosttyColorRgb()
        return ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &c) == GHOSTTY_SUCCESS
            ? RGB(c.r, c.g, c.b) : nil
    }

    func foreground() -> RGB? {
        var c = GhosttyColorRgb()
        return ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &c) == GHOSTTY_SUCCESS
            ? RGB(c.r, c.g, c.b) : nil
    }

    var isWide: Bool {
        var raw: GhosttyCell = 0
        var wide = GHOSTTY_CELL_WIDE_NARROW
        return ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == GHOSTTY_SUCCESS
            && ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide) == GHOSTTY_SUCCESS && wide == GHOSTTY_CELL_WIDE_WIDE
    }

    func firstCodepoint() -> UInt32 {
        // The call writes the whole cluster: a buffer that holds it all.
        let count = Int(graphemeCount)
        guard count > 1 else {
            var cp: UInt32 = 0
            if count == 1 { _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &cp) }
            return cp
        }
        var all = [UInt32](repeating: 0, count: count)
        _ = all.withUnsafeMutableBufferPointer {
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, $0.baseAddress)
        }
        return all[0]
    }

    func codepoints(_ buffer: UnsafeMutableBufferPointer<UInt32>) {
        _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, buffer.baseAddress)
    }
}

/// One screen row read through grid references (under the session's lock).
private struct GridRowCells: RowCellSource {
    let terminal: GhosttyTerminal
    let y: UInt32
    let cols: Int
    let palette: [GhosttyColorRgb]
    private var x = -1
    private var ref = GhosttyGridRef()
    private var raw: GhosttyCell = 0
    private var scalars = [UInt32](repeating: 0, count: 16)
    private var count = 0
    private var cellStyle: GhosttyStyle?

    init(terminal: GhosttyTerminal, y: UInt32, cols: Int, palette: [GhosttyColorRgb]) {
        self.terminal = terminal
        self.y = y
        self.cols = cols
        self.palette = palette
    }

    mutating func next() -> Bool {
        x += 1
        guard x < cols else { return false }
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_SCREEN
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(x), y: y)
        ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        raw = 0
        count = 0
        cellStyle = nil
        guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return true }
        _ = ghostty_grid_ref_cell(&ref, &raw)
        var n = 0
        if ghostty_grid_ref_graphemes(&ref, &scalars, scalars.count, &n) == GHOSTTY_SUCCESS { count = n }
        var styled = false
        if ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_STYLING, &styled) == GHOSTTY_SUCCESS, styled {
            var s = GhosttyStyle()
            s.size = MemoryLayout<GhosttyStyle>.size
            if ghostty_grid_ref_style(&ref, &s) == GHOSTTY_SUCCESS { cellStyle = s }
        }
        return true
    }

    var graphemeCount: UInt32 { UInt32(count) }

    func style(_ style: inout GhosttyStyle) -> Bool {
        guard let cellStyle else { return false }
        style = cellStyle
        return true
    }

    private func resolve(_ color: GhosttyStyleColor) -> RGB? {
        switch color.tag {
        case GHOSTTY_STYLE_COLOR_PALETTE:
            let c = palette[Int(color.value.palette)]
            return RGB(c.r, c.g, c.b)
        case GHOSTTY_STYLE_COLOR_RGB:
            return RGB(color.value.rgb.r, color.value.rgb.g, color.value.rgb.b)
        default:
            return nil
        }
    }

    func background() -> RGB? {
        if let cellStyle, let c = resolve(cellStyle.bg_color) { return c }
        // A cell with only a background (erased in a color).
        var tag = GHOSTTY_CELL_CONTENT_CODEPOINT
        guard ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag) == GHOSTTY_SUCCESS else { return nil }
        if tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE {
            var index: GhosttyColorPaletteIndex = 0
            _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_PALETTE, &index)
            let c = palette[Int(index)]
            return RGB(c.r, c.g, c.b)
        }
        if tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB {
            var c = GhosttyColorRgb()
            _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_RGB, &c)
            return RGB(c.r, c.g, c.b)
        }
        return nil
    }

    func foreground() -> RGB? { cellStyle.flatMap { resolve($0.fg_color) } }

    var isWide: Bool {
        var wide = GHOSTTY_CELL_WIDE_NARROW
        return ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide) == GHOSTTY_SUCCESS && wide == GHOSTTY_CELL_WIDE_WIDE
    }

    func firstCodepoint() -> UInt32 { count > 0 ? scalars[0] : 0 }

    func codepoints(_ buffer: UnsafeMutableBufferPointer<UInt32>) {
        for i in 0..<min(count, buffer.count) { buffer[i] = scalars[i] }
    }
}
