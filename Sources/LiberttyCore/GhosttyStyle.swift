import CGhosttyVt

// libghostty-vt 1.0's GhosttyStyle is a frozen 16-byte struct: its
// attributes are bits of `flags` (style.h's GHOSTTY_STYLE_FLAG_* macros,
// which are casts Swift doesn't import), and a color's kind is a byte.

extension GhosttyStyle {
    private func has(_ bit: Int) -> Bool { flags & GhosttyStyleFlags(1 << bit) != 0 }

    public var bold: Bool { has(0) }
    public var italic: Bool { has(1) }
    public var faint: Bool { has(2) }
    public var blink: Bool { has(3) }
    public var inverse: Bool { has(4) }
    public var invisible: Bool { has(5) }
    public var strikethrough: Bool { has(6) }
    public var overline: Bool { has(7) }

    /// Bits 8 to 10 (GHOSTTY_STYLE_UNDERLINE).
    public var underline: GhosttySgrUnderline {
        GhosttySgrUnderline(rawValue: numericCast((flags >> 8) & 0x7))
    }
}

extension GhosttyStyleColor {
    /// Which of `value`'s fields holds the color.
    public var kind: GhosttyStyleColorTag { GhosttyStyleColorTag(rawValue: numericCast(tag)) }
}
