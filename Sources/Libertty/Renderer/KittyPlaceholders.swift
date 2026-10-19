import CGhosttyVt

/// Kitty graphics Unicode placeholders (virtual placements, `U=1`): a
/// program (or tmux passing images through) prints U+10EEEE cells whose
/// foreground color is the image ID and whose combining marks say which row
/// and column of the image each cell shows. The terminal stores the virtual
/// placement; the renderer finds the cells and draws the image over them,
/// fitted into the placement's cell grid with its aspect ratio kept.
/// (After Ghostty's graphics_unicode.zig, MIT.)
enum KittyPlaceholders {
    static let codepoint: UInt32 = 0x10EEEE

    /// One placeholder cell, as its row's builder found it.
    struct Cell {
        var x: Int
        var imageLow: UInt32
        var imageHigh: UInt32?
        var placementID: UInt32
        var row: UInt32?
        var col: UInt32?
    }

    /// A virtual placement the terminal holds.
    struct Virtual {
        var imageID: UInt32
        var placementID: UInt32
        var columns: UInt32
        var rows: UInt32
        var z: Int32
        var width: UInt32
        var height: UInt32
        var generation: UInt64
    }

    /// The cell's placeholder facts, from its style and code points.
    static func cell(x: Int, style: GhosttyStyle, codepoints: ArraySlice<UInt32>) -> Cell {
        let marks = Array(codepoints.dropFirst())
        var cell = Cell(x: x, imageLow: id(style.fg_color), imageHigh: nil, placementID: id(style.underline_color),
                        row: nil, col: nil)
        if marks.count > 0 { cell.row = index(marks[0]) }
        if marks.count > 1 { cell.col = index(marks[1]) }
        if marks.count > 2, let high = index(marks[2]), high < 256 { cell.imageHigh = high }
        return cell
    }

    /// A color as a protocol ID: a palette index, or the RGB as 24 bits.
    private static func id(_ color: GhosttyStyleColor) -> UInt32 {
        switch color.tag {
        case GHOSTTY_STYLE_COLOR_PALETTE: UInt32(color.value.palette)
        case GHOSTTY_STYLE_COLOR_RGB: UInt32(color.value.rgb.r) << 16 | UInt32(color.value.rgb.g) << 8 | UInt32(color.value.rgb.b)
        default: 0
        }
    }

    private static func index(_ mark: UInt32) -> UInt32? {
        var lo = 0, hi = diacritics.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if diacritics[mid] == mark { return UInt32(mid) }
            if diacritics[mid] < mark { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// A run: consecutive cells of one row showing consecutive columns of
    /// one image row (cells without marks continue the one before).
    private struct Run {
        var x: Int
        var imageLow: UInt32
        var imageHigh: UInt32?
        var placementID: UInt32
        var row: UInt32
        var col: UInt32
        var width: UInt32

        func accepts(_ c: Cell) -> Bool {
            c.imageLow == imageLow && c.placementID == placementID && (c.row == nil || c.row == row)
                && (c.col == nil || c.col == col + width) && (c.imageHigh == nil || c.imageHigh == imageHigh)
                && c.x == x + Int(width)
        }
    }

    /// What to draw for one viewport row's placeholder cells (`y` is the
    /// row; rects are relative to the grid's top-left, in pixels).
    static func draws(_ cells: [Cell], y: Int, virtuals: [Virtual], cellWidth: Int, cellHeight: Int) -> [KittyImages.Draw] {
        var runs: [Run] = []
        for c in cells {
            if var last = runs.last, last.accepts(c) {
                last.width += 1
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(x: c.x, imageLow: c.imageLow, imageHigh: c.imageHigh, placementID: c.placementID,
                                row: c.row ?? 0, col: c.col ?? 0, width: 1))
            }
        }
        return runs.compactMap { draw($0, y: y, virtuals: virtuals, cellWidth: cellWidth, cellHeight: cellHeight) }
    }

    private static func draw(_ run: Run, y: Int, virtuals: [Virtual], cellWidth: Int, cellHeight: Int) -> KittyImages.Draw? {
        let imageID = run.imageLow | ((run.imageHigh ?? 0) << 24)
        // The placement named, else the image's first virtual one.
        guard let v = virtuals.first(where: { $0.imageID == imageID && (run.placementID == 0 || $0.placementID == run.placementID) }),
              v.width > 0, v.height > 0 else { return nil }
        let cw = Double(cellWidth), ch = Double(cellHeight)
        let imgW = Double(v.width), imgH = Double(v.height)
        let gridRows = Double(v.rows != 0 ? v.rows : (v.height + UInt32(cellHeight) - 1) / UInt32(cellHeight))
        let gridCols = Double(v.columns != 0 ? v.columns : (v.width + UInt32(cellWidth) - 1) / UInt32(cellWidth))

        // Fit the image into the grid, centered, keeping its aspect ratio.
        let rowsPx = gridRows * ch, colsPx = gridCols * cw
        var xScale: Double, yScale: Double, xOffset = 0.0, yOffset = 0.0
        if imgW * rowsPx > imgH * colsPx {
            xScale = colsPx / max(imgW, 1); yScale = xScale
            yOffset = (rowsPx - imgH * yScale) / 2
        } else {
            yScale = rowsPx / max(imgH, 1); xScale = yScale
            xOffset = (colsPx - imgW * xScale) / 2
        }
        // The image with its centering margins, in image pixels.
        let padX = xOffset / xScale, padY = yOffset / yScale
        let scaledW = imgW + padX * 2, scaledH = imgH + padY * 2
        // This run's share of it.
        var srcX = scaledW * Double(run.col) / gridCols, srcY = scaledH * Double(run.row) / gridRows
        var srcW = scaledW * Double(run.width) / gridCols, srcH = scaledH / gridRows
        var destX = 0.0, destY = 0.0
        var destW = Double(run.width) * cw, destH = ch

        if srcY < padY {
            let cut = padY - srcY
            srcH -= cut; destY = cut; destH -= cut * yScale; srcY = 0
            if srcH > imgH { srcH = imgH; destH = imgH * yScale }
        } else if srcY + srcH > scaledH - padY {
            srcY -= padY
            srcH = scaledH - padY - srcY - padY
            destH = srcH * yScale
        } else {
            srcY -= padY
        }
        if srcX < padX {
            let cut = padX - srcX
            srcW -= cut; destX = cut; destW -= cut * xScale; srcX = 0
            if srcW > imgW { srcW = imgW; destW = imgW * xScale }
        } else if srcX + srcW > scaledW - padX {
            srcX -= padX
            srcW = scaledW - padX - srcX - padX
            destW = srcW * xScale
        } else {
            srcX -= padX
        }
        guard srcW > 0, srcH > 0, destW > 0, destH > 0 else { return nil }

        let layer: KittyImages.Layer = v.z < -1_073_741_824 ? .belowBackground : (v.z < 0 ? .belowText : .aboveText)
        return KittyImages.Draw(
            imageID: imageID, generation: v.generation,
            rect: SIMD4(Float(Double(run.x) * cw + destX * xScale), Float(Double(y) * ch + destY * yScale),
                        Float(destW), Float(destH)),
            uv: SIMD4(Float(srcX / imgW), Float(srcY / imgH), Float(srcW / imgW), Float(srcH / imgH)),
            layer: layer)
    }

    /// kitty's rowcolumn-diacritics.txt: the index of a mark is its value.
    private static let diacritics: [UInt32] = [
        0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A, 0x034B, 0x034C,
        0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
        0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592,
        0x0593, 0x0594, 0x0595, 0x0597, 0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
        0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615,
        0x0616, 0x0617, 0x0657, 0x0658, 0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
        0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2, 0x06E4, 0x06E7, 0x06E8, 0x06EB,
        0x06EC, 0x0730, 0x0732, 0x0733, 0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743,
        0x0745, 0x0747, 0x0749, 0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE, 0x07EF, 0x07F0, 0x07F1, 0x07F3,
        0x0816, 0x0817, 0x0818, 0x0819, 0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
        0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C, 0x082D, 0x0951, 0x0953, 0x0954,
        0x0F82, 0x0F83, 0x0F86, 0x0F87, 0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
        0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D, 0x1B6E, 0x1B6F, 0x1B70, 0x1B71,
        0x1B72, 0x1B73, 0x1CD0, 0x1CD1, 0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4,
        0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1, 0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5,
        0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9, 0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1,
        0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1, 0x20D4, 0x20D5, 0x20D6, 0x20D7,
        0x20DB, 0x20DC, 0x20E1, 0x20E7, 0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2,
        0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA, 0x2DEB, 0x2DEC, 0x2DED, 0x2DEE,
        0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2, 0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
        0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D, 0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1,
        0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5, 0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9, 0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED,
        0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2, 0xAAB3, 0xAAB7, 0xAAB8, 0xAABE, 0xAABF, 0xAAC1,
        0xFE20, 0xFE21, 0xFE22, 0xFE23, 0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187,
        0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243, 0x1D244,
    ]
}
