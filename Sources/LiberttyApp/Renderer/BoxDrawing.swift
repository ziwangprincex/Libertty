import CoreGraphics

/// Box drawing (U+2500–257F), block elements (U+2580–259F), braille
/// (U+2800–28FF), Powerline's shapes (U+E0B0–E0BF) and the branch drawing
/// set git graphs use (U+F5D0–F60D) drawn from cell geometry instead of the
/// font, so lines meet across cells with no gaps, blocks fill exactly their
/// fraction of the cell and prompt segments butt against their neighbors —
/// fonts rarely match a terminal's cell height, which leaves seams.
/// (Powerline and branch shapes after Ghostty's sprite font, MIT.)
///
/// Draws white coverage into a context whose origin is the cell's top-left,
/// y down, sized `width` × `height` pixels. Returns false for codepoints it
/// doesn't handle (the caller falls back to the font).
enum BoxDrawing {
    static func handles(_ cp: UInt32) -> Bool {
        (0x2500...0x259F).contains(cp) || (0x2800...0x28FF).contains(cp)
            || (0xE0B0...0xE0BF).contains(cp) || (0xF5D0...0xF60D).contains(cp)
    }

    /// Line weights, in pixels, for a cell of the given width.
    private struct Weights {
        let light: CGFloat
        let heavy: CGFloat
        init(cellWidth: Int) {
            light = max(1, (CGFloat(cellWidth) / 8).rounded())
            heavy = max(light + 1, (light * 2).rounded())
        }
    }

    private enum Line { case none, light, heavy, double }

    static func draw(_ cp: UInt32, in ctx: CGContext, width: Int, height: Int) -> Bool {
        let w = CGFloat(width), h = CGFloat(height)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.setShouldAntialias(false)
        defer { ctx.setShouldAntialias(true) }

        if (0x2580...0x259F).contains(cp) {
            return drawBlock(cp, ctx, w, h)
        }
        let weights = Weights(cellWidth: width)
        if (0x2800...0x28FF).contains(cp) {
            drawBraille(cp, ctx, w, h)
            return true
        }
        if (0xE0B0...0xE0BF).contains(cp) {
            drawPowerline(cp, ctx, w, h, weights)
            return true
        }
        if (0xF5D0...0xF60D).contains(cp) {
            drawBranch(cp, ctx, w, h, weights)
            return true
        }

        if let arms = arms[cp] {
            drawArms(arms, ctx, w, h, weights)
            return true
        }
        switch cp {
        case 0x256D...0x2570:  // ╭╮╯╰ rounded corners
            drawRounded(cp, ctx, w, h, weights.light)
            return true
        case 0x2571...0x2573:  // ╱╲╳ diagonals
            ctx.setShouldAntialias(true)
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.setLineWidth(weights.light)
            if cp != 0x2572 { ctx.move(to: CGPoint(x: 0, y: h)); ctx.addLine(to: CGPoint(x: w, y: 0)) }
            if cp != 0x2571 { ctx.move(to: .zero); ctx.addLine(to: CGPoint(x: w, y: h)) }
            ctx.strokePath()
            return true
        case 0x2574...0x257F:  // half lines ╴╵╶╷ and their heavy/mixed forms
            let l: Line = [0x2574, 0x257E].contains(cp) ? .light : (cp == 0x2578 || cp == 0x257C ? .heavy : .none)
            let u: Line = [0x2575, 0x257F].contains(cp) ? .light : (cp == 0x2579 || cp == 0x257D ? .heavy : .none)
            let r: Line = [0x2576, 0x257C].contains(cp) ? .light : (cp == 0x257A || cp == 0x257E ? .heavy : .none)
            let d: Line = [0x2577, 0x257D].contains(cp) ? .light : (cp == 0x257B || cp == 0x257F ? .heavy : .none)
            drawArms((u, r, d, l), ctx, w, h, weights)
            return true
        default:
            return false  // dashed lines (┄┅┆┇┈┉┊┋╌╍╎╏): the font's are fine
        }
    }

    // MARK: Lines

    /// (up, right, down, left) for every solid box-drawing character.
    private static let arms: [UInt32: (Line, Line, Line, Line)] = {
        var t: [UInt32: (Line, Line, Line, Line)] = [:]
        let n = Line.none, l = Line.light, H = Line.heavy, d = Line.double
        // ─ ━ │ ┃
        t[0x2500] = (n, l, n, l); t[0x2501] = (n, H, n, H)
        t[0x2502] = (l, n, l, n); t[0x2503] = (H, n, H, n)
        // ┌ ┍ ┎ ┏  ┐ ┑ ┒ ┓  └ ┕ ┖ ┗  ┘ ┙ ┚ ┛
        t[0x250C] = (n, l, l, n); t[0x250D] = (n, H, l, n); t[0x250E] = (n, l, H, n); t[0x250F] = (n, H, H, n)
        t[0x2510] = (n, n, l, l); t[0x2511] = (n, n, l, H); t[0x2512] = (n, n, H, l); t[0x2513] = (n, n, H, H)
        t[0x2514] = (l, l, n, n); t[0x2515] = (l, H, n, n); t[0x2516] = (H, l, n, n); t[0x2517] = (H, H, n, n)
        t[0x2518] = (l, n, n, l); t[0x2519] = (l, n, n, H); t[0x251A] = (H, n, n, l); t[0x251B] = (H, n, n, H)
        // ├ … ┫
        t[0x251C] = (l, l, l, n); t[0x251D] = (l, H, l, n); t[0x251E] = (H, l, l, n); t[0x251F] = (l, l, H, n)
        t[0x2520] = (H, l, H, n); t[0x2521] = (H, H, l, n); t[0x2522] = (l, H, H, n); t[0x2523] = (H, H, H, n)
        t[0x2524] = (l, n, l, l); t[0x2525] = (l, n, l, H); t[0x2526] = (H, n, l, l); t[0x2527] = (l, n, H, l)
        t[0x2528] = (H, n, H, l); t[0x2529] = (H, n, l, H); t[0x252A] = (l, n, H, H); t[0x252B] = (H, n, H, H)
        // ┬ … ┳
        t[0x252C] = (n, l, l, l); t[0x252D] = (n, l, l, H); t[0x252E] = (n, H, l, l); t[0x252F] = (n, H, l, H)
        t[0x2530] = (n, l, H, l); t[0x2531] = (n, l, H, H); t[0x2532] = (n, H, H, l); t[0x2533] = (n, H, H, H)
        // ┴ … ┻
        t[0x2534] = (l, l, n, l); t[0x2535] = (l, l, n, H); t[0x2536] = (l, H, n, l); t[0x2537] = (l, H, n, H)
        t[0x2538] = (H, l, n, l); t[0x2539] = (H, l, n, H); t[0x253A] = (H, H, n, l); t[0x253B] = (H, H, n, H)
        // ┼ … ╋
        t[0x253C] = (l, l, l, l); t[0x253D] = (l, l, l, H); t[0x253E] = (l, H, l, l); t[0x253F] = (l, H, l, H)
        t[0x2540] = (H, l, l, l); t[0x2541] = (l, l, H, l); t[0x2542] = (H, l, H, l); t[0x2543] = (H, l, l, H)
        t[0x2544] = (H, H, l, l); t[0x2545] = (l, l, H, H); t[0x2546] = (l, H, H, l); t[0x2547] = (H, H, l, H)
        t[0x2548] = (l, H, H, H); t[0x2549] = (H, l, H, H); t[0x254A] = (H, H, H, l); t[0x254B] = (H, H, H, H)
        // ═ ║ and the double / mixed single-double family ╒ … ╬
        t[0x2550] = (n, d, n, d); t[0x2551] = (d, n, d, n)
        t[0x2552] = (n, d, l, n); t[0x2553] = (n, l, d, n); t[0x2554] = (n, d, d, n)
        t[0x2555] = (n, n, l, d); t[0x2556] = (n, n, d, l); t[0x2557] = (n, n, d, d)
        t[0x2558] = (l, d, n, n); t[0x2559] = (d, l, n, n); t[0x255A] = (d, d, n, n)
        t[0x255B] = (l, n, n, d); t[0x255C] = (d, n, n, l); t[0x255D] = (d, n, n, d)
        t[0x255E] = (l, d, l, n); t[0x255F] = (d, l, d, n); t[0x2560] = (d, d, d, n)
        t[0x2561] = (l, n, l, d); t[0x2562] = (d, n, d, l); t[0x2563] = (d, n, d, d)
        t[0x2564] = (n, d, l, d); t[0x2565] = (n, l, d, l); t[0x2566] = (n, d, d, d)
        t[0x2567] = (l, d, n, d); t[0x2568] = (d, l, n, l); t[0x2569] = (d, d, n, d)
        t[0x256A] = (l, d, l, d); t[0x256B] = (d, l, d, l); t[0x256C] = (d, d, d, d)
        return t
    }()

    private static func drawArms(_ arms: (Line, Line, Line, Line), _ ctx: CGContext,
                                 _ w: CGFloat, _ h: CGFloat, _ weights: Weights) {
        let (up, right, down, left) = arms
        let light = weights.light, heavy = weights.heavy
        // Every stroke is positioned from one shared pixel-aligned center, so
        // light, heavy and double strokes crossing a cell share one axis.
        let cx = (w / 2).rounded(.down), cy = (h / 2).rounded(.down)

        func isSingle(_ line: Line) -> Bool { line == .light || line == .heavy }
        func thickness(_ line: Line) -> CGFloat { line == .heavy ? heavy : light }
        /// Left/top edge of a stroke of thickness `t` centered on `center`.
        func start(_ center: CGFloat, _ t: CGFloat) -> CGFloat { center - (t / 2).rounded(.down) }

        // A double line is two light strokes with `gap` px between them:
        // "near" is the left (vertical) or top (horizontal) one.
        let gap = max(light, 2)
        let nearX = start(cx, light) - (gap + light) / 2, farX = nearX + light + gap
        let nearY = start(cy, light) - (gap + light) / 2, farY = nearY + light + gap

        let anyV = up != .none || down != .none
        let anyH = left != .none || right != .none
        let doubleV = up == .double || down == .double
        let doubleH = left == .double || right == .double
        // Extent of the widest single stroke crossing the center.
        let hT = max(thickness(left), thickness(right)), vT = max(thickness(up), thickness(down))
        let hTop = start(cy, hT), hBottom = hTop + hT
        let vLeft = start(cx, vT), vRight = vLeft + vT

        func fillV(x: CGFloat, width: CGFloat, _ y0: CGFloat, _ y1: CGFloat) {
            if y1 > y0 { ctx.fill(CGRect(x: x, y: y0, width: width, height: y1 - y0)) }
        }
        func fillH(y: CGFloat, height: CGFloat, _ x0: CGFloat, _ x1: CGFloat) {
            if x1 > x0 { ctx.fill(CGRect(x: x0, y: y, width: x1 - x0, height: height)) }
        }

        // MARK: Single (light/heavy) arms
        // Meeting a double line: pass through if the single line continues on
        // the other side; attach to the near stroke if the double line runs
        // straight through; reach the far stroke if the double turns here.
        if isSingle(up) {
            let end = !doubleH ? (anyH ? hBottom : cy + 1)
                : isSingle(down) || !(left == .double && right == .double) ? farY + light : nearY + light
            fillV(x: start(cx, thickness(up)), width: thickness(up), 0, end)
        }
        if isSingle(down) {
            let begin = !doubleH ? (anyH ? hTop : cy)
                : isSingle(up) || !(left == .double && right == .double) ? nearY : farY
            fillV(x: start(cx, thickness(down)), width: thickness(down), begin, h)
        }
        if isSingle(left) {
            let end = !doubleV ? (anyV ? vRight : cx + 1)
                : isSingle(right) || !(up == .double && down == .double) ? farX + light : nearX + light
            fillH(y: start(cy, thickness(left)), height: thickness(left), 0, end)
        }
        if isSingle(right) {
            let begin = !doubleV ? (anyV ? vLeft : cx)
                : isSingle(left) || !(up == .double && down == .double) ? nearX : farX
            fillH(y: start(cy, thickness(right)), height: thickness(right), begin, w)
        }

        // MARK: Double arms
        // Each stroke turns into the perpendicular arm on its own side: the
        // inner stroke of that arm if it is double, the single line if single.
        // With nothing on its side it is the outer stroke of a corner (or
        // continues straight on).
        func vEnd(side: Line, other: Line) -> CGFloat {      // up arm, stroke end
            switch side {
            case .double: nearY + light
            case .light, .heavy: hBottom
            case .none: other == .double ? farY + light : (isSingle(other) ? hBottom : cy + 1)
            }
        }
        func vBegin(side: Line, other: Line) -> CGFloat {    // down arm, stroke start
            switch side {
            case .double: farY
            case .light, .heavy: hTop
            case .none: other == .double ? nearY : (isSingle(other) ? hTop : cy)
            }
        }
        func hEnd(side: Line, other: Line) -> CGFloat {      // left arm, stroke end
            switch side {
            case .double: nearX + light
            case .light, .heavy: vRight
            case .none: other == .double ? farX + light : (isSingle(other) ? vRight : cx + 1)
            }
        }
        func hBegin(side: Line, other: Line) -> CGFloat {    // right arm, stroke start
            switch side {
            case .double: farX
            case .light, .heavy: vLeft
            case .none: other == .double ? nearX : (isSingle(other) ? vLeft : cx)
            }
        }
        if up == .double {
            fillV(x: nearX, width: light, 0, vEnd(side: left, other: right))
            fillV(x: farX, width: light, 0, vEnd(side: right, other: left))
        }
        if down == .double {
            fillV(x: nearX, width: light, vBegin(side: left, other: right), h)
            fillV(x: farX, width: light, vBegin(side: right, other: left), h)
        }
        if left == .double {
            fillH(y: nearY, height: light, 0, hEnd(side: up, other: down))
            fillH(y: farY, height: light, 0, hEnd(side: down, other: up))
        }
        if right == .double {
            fillH(y: nearY, height: light, hBegin(side: up, other: down), w)
            fillH(y: farY, height: light, hBegin(side: down, other: up), w)
        }
    }

    private static func drawRounded(_ cp: UInt32, _ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, _ t: CGFloat) {
        ctx.setShouldAntialias(true)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(t)
        // Same axis as the straight strokes: center of a `t`-wide stroke
        // starting at floor(w/2) - floor(t/2).
        let cx = (w / 2).rounded(.down) - (t / 2).rounded(.down) + t / 2
        let cy = (h / 2).rounded(.down) - (t / 2).rounded(.down) + t / 2
        let r = min(cx, cy, w - cx, h - cy)
        let path = CGMutablePath()
        switch cp {
        case 0x256D:  // ╭ right and down
            path.move(to: CGPoint(x: w, y: cy))
            path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: cx, y: h), radius: r)
            path.addLine(to: CGPoint(x: cx, y: h))
        case 0x256E:  // ╮ left and down
            path.move(to: CGPoint(x: 0, y: cy))
            path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: cx, y: h), radius: r)
            path.addLine(to: CGPoint(x: cx, y: h))
        case 0x256F:  // ╯ left and up
            path.move(to: CGPoint(x: 0, y: cy))
            path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: cx, y: 0), radius: r)
            path.addLine(to: CGPoint(x: cx, y: 0))
        default:      // ╰ right and up
            path.move(to: CGPoint(x: w, y: cy))
            path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: cx, y: 0), radius: r)
            path.addLine(to: CGPoint(x: cx, y: 0))
        }
        ctx.addPath(path)
        ctx.strokePath()
    }

    // MARK: Blocks

    private static func drawBlock(_ cp: UInt32, _ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) -> Bool {
        func eighthsFromBottom(_ n: CGFloat) -> CGRect {
            let top = (h - h * n / 8).rounded()
            return CGRect(x: 0, y: top, width: w, height: h - top)
        }
        func eighthsFromLeft(_ n: CGFloat) -> CGRect {
            CGRect(x: 0, y: 0, width: (w * n / 8).rounded(), height: h)
        }
        let halfW = (w / 2).rounded(), halfH = (h / 2).rounded()
        let quadrants: [UInt32: [Int]] = [  // 0 ↖ 1 ↗ 2 ↙ 3 ↘
            0x2596: [2], 0x2597: [3], 0x2598: [0], 0x2599: [0, 2, 3], 0x259A: [0, 3],
            0x259B: [0, 1, 2], 0x259C: [0, 1, 3], 0x259D: [1], 0x259E: [1, 2], 0x259F: [1, 2, 3],
        ]
        switch cp {
        case 0x2580: ctx.fill(CGRect(x: 0, y: 0, width: w, height: halfH))           // ▀
        case 0x2581...0x2588: ctx.fill(eighthsFromBottom(CGFloat(cp - 0x2580)))      // ▁ … █
        case 0x2589...0x258F: ctx.fill(eighthsFromLeft(CGFloat(0x2590 - cp)))        // ▉ … ▏
        case 0x2590: ctx.fill(CGRect(x: halfW, y: 0, width: w - halfW, height: h))   // ▐
        case 0x2591, 0x2592, 0x2593:                                                 // ░ ▒ ▓
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: [0.25, 0.5, 0.75][Int(cp - 0x2591)]))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        case 0x2594: ctx.fill(CGRect(x: 0, y: 0, width: w, height: (h / 8).rounded()))         // ▔
        case 0x2595: ctx.fill(CGRect(x: w - (w / 8).rounded(), y: 0, width: (w / 8).rounded(), height: h))  // ▕
        default:
            guard let quads = quadrants[cp] else { return false }
            for q in quads {
                ctx.fill(CGRect(x: q % 2 == 0 ? 0 : halfW, y: q < 2 ? 0 : halfH,
                                width: q % 2 == 0 ? halfW : w - halfW, height: q < 2 ? halfH : h - halfH))
            }
        }
        return true
    }

    // MARK: Braille

    /// Eight dots in a 2×4 grid, square and evenly spaced in the cell.
    private static func drawBraille(_ cp: UInt32, _ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
        let bits = cp - 0x2800
        let dot = max(1, (min(w / 4, h / 8)).rounded())
        let xs = [((w / 2 - dot) / 2).rounded(), (w / 2 + (w / 2 - dot) / 2).rounded()]
        let inset: CGFloat = (h / 4 - dot) / 2
        let ys: [CGFloat] = (0..<4).map { (CGFloat($0) * h / 4 + inset).rounded() }
        // Dots 1–3 and 7 are the left column, 4–6 and 8 the right.
        let place: [(Int, Int)] = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)]
        for (i, (col, row)) in place.enumerated() where bits & (1 << UInt32(i)) != 0 {
            ctx.fill(CGRect(x: xs[col], y: ys[row], width: dot, height: dot))
        }
    }

    // MARK: Powerline

    private static func drawPowerline(_ cp: UInt32, _ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, _ weights: Weights) {
        ctx.setShouldAntialias(true)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(weights.light)
        func fill(_ points: [CGPoint]) {
            ctx.move(to: points[0])
            points.dropFirst().forEach { ctx.addLine(to: $0) }
            ctx.closePath()
            ctx.fillPath()
        }
        func diagonal(_ from: CGPoint, _ to: CGPoint) {
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()
        }
        // Half a circle bulging toward `right` (or left), filling the cell's height.
        func halfCircle(right: Bool, filled: Bool) {
            let r = min(w, h / 2)
            let c = (2.squareRoot() - 1) * 4 / 3
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            path.addCurve(to: CGPoint(x: r, y: r), control1: CGPoint(x: r * c, y: 0), control2: CGPoint(x: r, y: r - r * c))
            path.addLine(to: CGPoint(x: r, y: h - r))
            path.addCurve(to: CGPoint(x: 0, y: h), control1: CGPoint(x: r, y: h - r + r * c), control2: CGPoint(x: r * c, y: h))
            var flip = right ? CGAffineTransform.identity : CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
            guard let placed = path.copy(using: &flip) else { return }
            ctx.addPath(placed)
            if filled {
                ctx.closePath()
                ctx.fillPath()
            } else {
                // Stroked inside the shape, so it doesn't spill out of the cell.
                ctx.saveGState()
                ctx.addPath(placed)
                ctx.closePath()
                ctx.clip()
                ctx.addPath(placed)
                ctx.setLineWidth(weights.light * 2)
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        switch cp {
        case 0xE0B0: fill([CGPoint(x: 0, y: 0), CGPoint(x: w, y: h / 2), CGPoint(x: 0, y: h)])   // 
        case 0xE0B2: fill([CGPoint(x: w, y: 0), CGPoint(x: 0, y: h / 2), CGPoint(x: w, y: h)])   // 
        case 0xE0B1, 0xE0B3:                                                                       //  
            let near: CGFloat = cp == 0xE0B1 ? 0 : w, far: CGFloat = cp == 0xE0B1 ? w : 0
            ctx.move(to: CGPoint(x: near, y: 0))
            ctx.addLine(to: CGPoint(x: far, y: h / 2))
            ctx.addLine(to: CGPoint(x: near, y: h))
            ctx.strokePath()
        case 0xE0B4: halfCircle(right: true, filled: true)                                         // 
        case 0xE0B5: halfCircle(right: true, filled: false)
        case 0xE0B6: halfCircle(right: false, filled: true)                                        // 
        case 0xE0B7: halfCircle(right: false, filled: false)
        case 0xE0B8: fill([CGPoint(x: 0, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)])       // 
        case 0xE0BA: fill([CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)])       // 
        case 0xE0BC: fill([CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: 0, y: h)])       // 
        case 0xE0BE: fill([CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h)])       // 
        case 0xE0B9, 0xE0BF: diagonal(CGPoint(x: 0, y: 0), CGPoint(x: w, y: h))                    //  
        default: diagonal(CGPoint(x: w, y: 0), CGPoint(x: 0, y: h))                                //  
        }
    }

    // MARK: Branch drawing (git graphs)

    private enum Corner { case br, bl, tl, tr }

    private static func drawBranch(_ cp: UInt32, _ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, _ weights: Weights) {
        let t = weights.light
        // On the same axis as box drawing's light strokes.
        let vLeft = (w / 2).rounded(.down) - (t / 2).rounded(.down), hTop = (h / 2).rounded(.down) - (t / 2).rounded(.down)
        func hline() { ctx.fill(CGRect(x: 0, y: hTop, width: w, height: t)) }
        func vline() { ctx.fill(CGRect(x: vLeft, y: 0, width: t, height: h)) }
        func arc(_ corner: Corner) {
            let rounded: UInt32 = switch corner { case .br: 0x256D; case .bl: 0x256E; case .tl: 0x256F; case .tr: 0x2570 }
            drawRounded(rounded, ctx, w, h, t)
            ctx.setShouldAntialias(false)
        }
        func fade(_ toward: String) {
            // Full at the center line's start, nothing at the edge it fades to.
            let steps = Int(toward == "right" || toward == "left" ? w : h)
            for i in 0..<steps {
                let f = CGFloat(i) / CGFloat(max(1, steps))
                let alpha = toward == "right" || toward == "bottom" ? 1 - f : f
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
                if toward == "right" || toward == "left" {
                    ctx.fill(CGRect(x: CGFloat(i), y: hTop, width: 1, height: t))
                } else {
                    ctx.fill(CGRect(x: vLeft, y: CGFloat(i), width: t, height: 1))
                }
            }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        }
        /// A commit: a circle (filled or not) with lines out to some edges.
        func node(up: Bool = false, right: Bool = false, down: Bool = false, left: Bool = false, filled: Bool) {
            let cx = vLeft + t / 2, cy = hTop + t / 2
            let r = min(cx, cy, w - cx, h - cy)
            if up { ctx.fill(CGRect(x: vLeft, y: 0, width: t, height: (cy - r + t / 2).rounded(.up))) }
            if down { let y = (cy + r - t / 2).rounded(.down); ctx.fill(CGRect(x: vLeft, y: y, width: t, height: h - y)) }
            if left { ctx.fill(CGRect(x: 0, y: hTop, width: (cx - r + t / 2).rounded(.up), height: t)) }
            if right { let x = (cx + r - t / 2).rounded(.down); ctx.fill(CGRect(x: x, y: hTop, width: w - x, height: t)) }
            ctx.setShouldAntialias(true)
            if filled {
                ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            } else {
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.setLineWidth(t)
                let inner = r - t / 2
                ctx.strokeEllipse(in: CGRect(x: cx - inner, y: cy - inner, width: inner * 2, height: inner * 2))
            }
            ctx.setShouldAntialias(false)
        }
        switch cp {
        case 0xF5D0: hline()
        case 0xF5D1: vline()
        case 0xF5D2: fade("right")
        case 0xF5D3: fade("left")
        case 0xF5D4: fade("bottom")
        case 0xF5D5: fade("top")
        case 0xF5D6: arc(.br)
        case 0xF5D7: arc(.bl)
        case 0xF5D8: arc(.tr)
        case 0xF5D9: arc(.tl)
        case 0xF5DA: vline(); arc(.tr)
        case 0xF5DB: vline(); arc(.br)
        case 0xF5DC: arc(.tr); arc(.br)
        case 0xF5DD: vline(); arc(.tl)
        case 0xF5DE: vline(); arc(.bl)
        case 0xF5DF: arc(.tl); arc(.bl)
        case 0xF5E0: arc(.bl); hline()
        case 0xF5E1: arc(.br); hline()
        case 0xF5E2: arc(.br); arc(.bl)
        case 0xF5E3: arc(.tl); hline()
        case 0xF5E4: arc(.tr); hline()
        case 0xF5E5: arc(.tr); arc(.tl)
        case 0xF5E6: vline(); arc(.tl); arc(.tr)
        case 0xF5E7: vline(); arc(.bl); arc(.br)
        case 0xF5E8: hline(); arc(.bl); arc(.tl)
        case 0xF5E9: hline(); arc(.tr); arc(.br)
        case 0xF5EA: vline(); arc(.tl); arc(.br)
        case 0xF5EB: vline(); arc(.tr); arc(.bl)
        case 0xF5EC: hline(); arc(.tl); arc(.br)
        case 0xF5ED: hline(); arc(.tr); arc(.bl)
        default:
            // U+F5EE…F60D: commits, filled and hollow in turn, each set of edges.
            let i = Int(cp - 0xF5EE), filled = i % 2 == 0
            let sets: [(u: Bool, r: Bool, d: Bool, l: Bool)] = [
                (false, false, false, false), (false, true, false, false), (false, false, false, true),
                (false, true, false, true), (false, false, true, false), (true, false, false, false),
                (true, false, true, false), (false, true, true, false), (false, false, true, true),
                (true, true, false, false), (true, false, false, true), (true, true, true, false),
                (true, false, true, true), (false, true, true, true), (true, true, false, true), (true, true, true, true),
            ]
            let e = sets[i / 2]
            node(up: e.u, right: e.r, down: e.d, left: e.l, filled: filled)
        }
    }
}
