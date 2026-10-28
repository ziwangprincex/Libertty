import CGhosttyVt
import LiberttyCore
import Metal

/// Kitty graphics protocol images (`kitten icat`, yazi, image.nvim): the
/// terminal (libghostty-vt) parses and stores them; this turns its visible
/// placements into textured quads, in the protocol's three layers.
enum KittyImages {
    /// libghostty-vt asks the embedder to decode PNGs (shared with liberttyd).
    static func installDecoder() { KittyGraphics.installDecoder() }

    /// Turn the protocol on for a terminal (it's off until there's storage).
    static func enable(on terminal: GhosttyTerminal) {
        var limit = KittyGraphics.storageLimit
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &limit)
        var yes = true
        // Local programs may hand images over as files or shared memory (fast);
        // remote ones send them inline. A program could read those files itself.
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &yes)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &yes)
        let tmp = Array(NSTemporaryDirectory().utf8)
        tmp.withUnsafeBufferPointer { buf in
            var dir = GhosttyString(ptr: buf.baseAddress, len: buf.count)
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, &dir)
        }
    }

    enum Layer { case belowBackground, belowText, aboveText }

    /// One placement to draw this frame.
    struct Draw: Equatable {
        var imageID: UInt32
        var generation: UInt64
        /// Destination in drawable pixels, relative to the grid's top-left.
        var rect: SIMD4<Float>
        /// Source region in normalized texture coordinates.
        var uv: SIMD4<Float>
        var layer: Layer
    }

    /// An image's pixels as RGBA8, for upload (copied: the terminal's are borrowed).
    struct Pixels {
        var width: Int
        var height: Int
        var rgba: [UInt8]
    }

    /// With the terminal locked: every visible placement, and the pixels of
    /// images `needs` says aren't cached at their generation.
    struct Collected {
        var draws: [Draw] = []
        var pixels: [UInt32: (UInt64, Pixels)] = [:]
        /// Placements shown by Unicode placeholder cells (see KittyPlaceholders).
        var virtuals: [KittyPlaceholders.Virtual] = []
    }

    static func collect(_ terminal: GhosttyTerminal, cellWidth: Int, cellHeight: Int,
                        needs: (UInt32, UInt64) -> Bool) -> Collected {
        var graphics: GhosttyKittyGraphics?
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics) == GHOSTTY_SUCCESS,
              let graphics else { return Collected() }
        var iterator: GhosttyKittyGraphicsPlacementIterator?
        guard ghostty_kitty_graphics_placement_iterator_new(nil, &iterator) == GHOSTTY_SUCCESS, let iterator else { return Collected() }
        defer { ghostty_kitty_graphics_placement_iterator_free(iterator) }
        var it: GhosttyKittyGraphicsPlacementIterator? = iterator
        guard ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &it) == GHOSTTY_SUCCESS else {
            return Collected()
        }
        let cellW = Float(cellWidth), cellH = Float(cellHeight)

        var draws: [Draw] = []
        var pixels: [UInt32: (UInt64, Pixels)] = [:]
        var virtuals: [KittyPlaceholders.Virtual] = []
        while ghostty_kitty_graphics_placement_next(iterator) {
            var imageID: UInt32 = 0, z: Int32 = 0, xOffset: UInt32 = 0, yOffset: UInt32 = 0
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &imageID)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z, &z)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET, &xOffset)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET, &yOffset)
            guard let image = ghostty_kitty_graphics_image(graphics, imageID) else { continue }
            var isVirtual = false
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL, &isVirtual)
            if isVirtual {
                // Where it shows is up to the placeholder cells; the renderer finds them.
                var placementID: UInt32 = 0, columns: UInt32 = 0, rows: UInt32 = 0
                var width: UInt32 = 0, height: UInt32 = 0, generation: UInt64 = 0
                _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID, &placementID)
                _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS, &columns)
                _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS, &rows)
                _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width)
                _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height)
                _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &generation)
                virtuals.append(.init(imageID: imageID, placementID: placementID, columns: columns, rows: rows, z: z,
                                      width: width, height: height, generation: generation))
                if pixels[imageID] == nil, width > 0, height > 0, needs(imageID, generation),
                   let p = rgba(image, width: Int(width), height: Int(height)) {
                    pixels[imageID] = (generation, p)
                }
                continue
            }
            var info = GhosttyKittyGraphicsPlacementRenderInfo()
            info.size = MemoryLayout<GhosttyKittyGraphicsPlacementRenderInfo>.size
            guard ghostty_kitty_graphics_placement_render_info(iterator, image, terminal, &info) == GHOSTTY_SUCCESS,
                  info.viewport_visible, info.pixel_width > 0, info.pixel_height > 0 else { continue }
            var width: UInt32 = 0, height: UInt32 = 0, generation: UInt64 = 0
            _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width)
            _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height)
            _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &generation)
            guard width > 0, height > 0 else { continue }

            let x = Float(info.viewport_col) * cellW + Float(xOffset)
            let y = Float(info.viewport_row) * cellH + Float(yOffset)
            let layer: Layer = z < -1_073_741_824 ? .belowBackground : (z < 0 ? .belowText : .aboveText)
            draws.append(Draw(
                imageID: imageID, generation: generation,
                rect: SIMD4(x, y, Float(info.pixel_width), Float(info.pixel_height)),
                uv: SIMD4(Float(info.source_x) / Float(width), Float(info.source_y) / Float(height),
                          Float(info.source_width) / Float(width), Float(info.source_height) / Float(height)),
                layer: layer))
            if pixels[imageID] == nil, needs(imageID, generation), let p = rgba(image, width: Int(width), height: Int(height)) {
                pixels[imageID] = (generation, p)
            }
        }
        return Collected(draws: draws, pixels: pixels, virtuals: virtuals)
    }

    private static func rgba(_ image: GhosttyKittyGraphicsImage, width: Int, height: Int) -> Pixels? {
        KittyGraphics.rgba(image, width: width, height: height).map { Pixels(width: width, height: height, rgba: $0) }
    }

    static func texture(_ pixels: Pixels, device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: pixels.width,
                                                            height: pixels.height, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        pixels.rgba.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, pixels.width, pixels.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: pixels.width * 4)
        }
        return texture
    }
}
