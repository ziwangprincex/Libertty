import AppKit
import CoreText

/// The terminal font family at one pixel scale, and the cell grid it implies.
/// All metrics are in device pixels so glyphs land on whole pixels.
final class FontSet {
    struct Style: OptionSet, Hashable {
        let rawValue: UInt8
        static let bold = Style(rawValue: 1)
        static let italic = Style(rawValue: 2)
    }

    let pointSize: CGFloat
    let scale: CGFloat
    let cellWidth: Int
    let cellHeight: Int
    /// Baseline, measured down from the top of the cell.
    let baseline: Int
    let underlinePosition: Int
    let underlineThickness: Int
    let strikethroughPosition: Int

    private let fonts: [UInt8: CTFont]

    static let preferredFamilies = [FontRegistry.bundledFamily, "JetBrains Mono", "SF Mono", "Menlo"]

    /// `family` comes first when given; a family that isn't installed falls
    /// back to the bundled font. `cellHeightAdjust` is `adjust-cell-height`.
    init(family: String = "", pointSize: CGFloat, scale: CGFloat, cellHeightAdjust: MetricAdjust = .none) {
        FontRegistry.registerBundledFonts()
        self.pointSize = pointSize
        self.scale = scale
        let pixelSize = pointSize * scale

        let families = family.isEmpty ? Self.preferredFamilies : [family] + Self.preferredFamilies
        var regular = families.lazy
            .compactMap { name -> CTFont? in
                // By family, not PostScript name: "JetBrains Mono" has no font of that name.
                let descriptor = CTFontDescriptorCreateWithAttributes(
                    [kCTFontFamilyNameAttribute: name] as CFDictionary)
                let font = CTFontCreateWithFontDescriptor(descriptor, pixelSize, nil)
                return (CTFontCopyFamilyName(font) as String).caseInsensitiveCompare(name) == .orderedSame ? font : nil
            }
            .first ?? CTFontCreateUIFontForLanguage(.userFixedPitch, pixelSize, nil)!

        // Prompt themes draw Nerd Font icons and Powerline arrows from the
        // Private Use Area, which ordinary fonts lack; try the bundled Nerd
        // Font first before the system fallback.
        if (CTFontCopyFamilyName(regular) as String) != FontRegistry.bundledFamily {
            let nerd = CTFontDescriptorCreateWithAttributes(
                [kCTFontFamilyNameAttribute: FontRegistry.bundledFamily] as CFDictionary)
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(
                CTFontCopyFontDescriptor(regular), [kCTFontCascadeListAttribute: [nerd]] as CFDictionary)
            regular = CTFontCreateWithFontDescriptor(descriptor, pixelSize, nil)
        }

        func variant(_ traits: CTFontSymbolicTraits) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(regular, pixelSize, nil, traits, traits) ?? regular
        }
        fonts = [
            0: regular,
            Style.bold.rawValue: variant(.traitBold),
            Style.italic.rawValue: variant(.traitItalic),
            Style([.bold, .italic]).rawValue: variant([.traitBold, .traitItalic]),
        ]

        // Cell width: the advance of a typical glyph, which every glyph in a
        // monospace face shares.
        var glyph = CGGlyph(0)
        var m: UniChar = 0x4D  // "M"
        CTFontGetGlyphsForCharacters(regular, &m, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)

        let ascent = CTFontGetAscent(regular)
        let descent = CTFontGetDescent(regular)
        let leading = CTFontGetLeading(regular)
        cellWidth = max(1, Int(advance.width.rounded(.up)))
        let natural = max(1, Int((ascent + descent + leading).rounded(.up)))
        cellHeight = max(1, cellHeightAdjust.applied(to: natural))
        // Split leading evenly above and below so text sits centered in the
        // cell; so does the height adjust-cell-height adds (or takes away).
        baseline = Int((ascent + leading / 2).rounded(.up)) + (cellHeight - natural) / 2

        underlineThickness = max(1, Int(CTFontGetUnderlineThickness(regular).rounded()))
        underlinePosition = min(cellHeight - underlineThickness,
                                baseline + max(1, Int((-CTFontGetUnderlinePosition(regular)).rounded())))
        strikethroughPosition = baseline - Int((CTFontGetXHeight(regular) / 2).rounded())
    }

    func font(_ style: Style) -> CTFont { fonts[style.rawValue]! }

    /// Ligatures in monospace fonts (JetBrains Mono, Fira Code, Cascadia) are
    /// contextual alternates: each character keeps its cell but may get a
    /// different glyph, drawn into its neighbors. For a run of ASCII text,
    /// the glyph CoreText picks for each character where it differs from the
    /// plain one; nil when nothing changes. Cached: the same runs ("->",
    /// "!=", "===") come up again and again.
    func contextualGlyphs(_ text: [UInt16], style: Style) -> [CGGlyph?]? {
        let key = ShapeKey(text: text, style: style.rawValue)
        if let hit = shapeCache[key] { return hit }
        if shapeCache.count > 4096 { shapeCache.removeAll(keepingCapacity: true) }
        let result = shape(text, style: style)
        shapeCache[key] = result
        return result
    }

    private struct ShapeKey: Hashable { var text: [UInt16]; var style: UInt8 }
    private var shapeCache: [ShapeKey: [CGGlyph?]?] = [:]

    private func shape(_ text: [UInt16], style: Style) -> [CGGlyph?]? {
        let font = self.font(style)
        var nominal = [CGGlyph](repeating: 0, count: text.count)
        guard CTFontGetGlyphsForCharacters(font, text, &nominal, text.count) else { return nil }
        let string = String(utf16CodeUnits: text, count: text.count)
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var shaped = nominal
        var changed = false
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            // Only the font's own substitutions; a fallback font means no ligature here.
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            guard CFEqual(runFont, font) else { return nil }
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            // A true ligature (fewer glyphs than characters) would need cells merged; skip it.
            guard count == CTRunGetStringRange(run).length else { return nil }
            for (glyph, index) in zip(glyphs, indices) where index < shaped.count && shaped[index] != glyph {
                shaped[index] = glyph
                changed = true
            }
        }
        guard changed else { return nil }
        return zip(shaped, nominal).map { $0 == $1 ? nil : $0 }
    }

    var familyName: String { CTFontCopyFamilyName(fonts[0]!) as String }

    /// Installed monospaced families, for the Settings picker.
    static func monospacedFamilies() -> [String] {
        FontRegistry.registerBundledFonts()
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        var families = Set<String>()
        for d in descriptors {
            let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any]
            let symbolic = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            guard symbolic & CTFontSymbolicTraits.traitMonoSpace.rawValue != 0,
                  let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String,
                  !family.hasPrefix(".") else { continue }
            families.insert(family)
        }
        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// Ghostty's font metric modifiers (`adjust-cell-height`): a number adds that
/// many pixels to the font's own value, a percentage that share of it (`2`,
/// `-1`, `20%`, `-10%`); it never sets the value outright.
enum MetricAdjust: Equatable {
    case pixels(Int)
    case percent(Double)

    static let none = MetricAdjust.pixels(0)

    init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%") {
            guard let p = Double(t.dropLast().trimmingCharacters(in: .whitespaces)), p > -100, p <= 1000 else { return nil }
            self = .percent(p)
        } else {
            guard let n = Int(t), abs(n) <= 1000 else { return nil }
            self = .pixels(n)
        }
    }

    var configString: String {
        switch self {
        case .pixels(let n): return n == 0 ? "" : String(n)
        case .percent(let p): return (p == p.rounded() ? String(Int(p)) : String(p)) + "%"
        }
    }

    func applied(to value: Int) -> Int {
        switch self {
        case .pixels(let n): return value + n
        case .percent(let p): return Int((Double(value) * (1 + p / 100)).rounded())
        }
    }
}
