import CGhosttyVt

/// A key as `libertty +send-key` names it, Ghostty's keybind way: `ctrl+c`,
/// `shift+left`, `enter`, `alt+f`, `f5`, `a`, `?` — modifiers joined to a
/// key by `+`. The characters are a US keyboard's.
public struct KeySpec: Equatable {
    public var key: GhosttyKey
    public var mods: GhosttyMods
    /// What it types (nil for keys that type nothing printable: enter, ctrl+c…).
    public var text: String?
    public var unshiftedCodepoint: UInt32

    /// Named keys.
    private static let named: [String: GhosttyKey] = [
        "enter": GHOSTTY_KEY_ENTER, "return": GHOSTTY_KEY_ENTER, "tab": GHOSTTY_KEY_TAB,
        "escape": GHOSTTY_KEY_ESCAPE, "esc": GHOSTTY_KEY_ESCAPE, "backspace": GHOSTTY_KEY_BACKSPACE,
        "delete": GHOSTTY_KEY_DELETE, "space": GHOSTTY_KEY_SPACE, "insert": GHOSTTY_KEY_INSERT,
        "up": GHOSTTY_KEY_ARROW_UP, "down": GHOSTTY_KEY_ARROW_DOWN, "left": GHOSTTY_KEY_ARROW_LEFT,
        "right": GHOSTTY_KEY_ARROW_RIGHT, "arrow_up": GHOSTTY_KEY_ARROW_UP, "arrow_down": GHOSTTY_KEY_ARROW_DOWN,
        "arrow_left": GHOSTTY_KEY_ARROW_LEFT, "arrow_right": GHOSTTY_KEY_ARROW_RIGHT,
        "home": GHOSTTY_KEY_HOME, "end": GHOSTTY_KEY_END, "page_up": GHOSTTY_KEY_PAGE_UP,
        "page_down": GHOSTTY_KEY_PAGE_DOWN,
        "f1": GHOSTTY_KEY_F1, "f2": GHOSTTY_KEY_F2, "f3": GHOSTTY_KEY_F3, "f4": GHOSTTY_KEY_F4,
        "f5": GHOSTTY_KEY_F5, "f6": GHOSTTY_KEY_F6, "f7": GHOSTTY_KEY_F7, "f8": GHOSTTY_KEY_F8,
        "f9": GHOSTTY_KEY_F9, "f10": GHOSTTY_KEY_F10, "f11": GHOSTTY_KEY_F11, "f12": GHOSTTY_KEY_F12,
    ]

    /// The keys that type a character, unshifted and shifted, on a US keyboard.
    private static let typing: [(GhosttyKey, Character, Character)] = {
        let letters: [GhosttyKey] = [GHOSTTY_KEY_A, GHOSTTY_KEY_B, GHOSTTY_KEY_C, GHOSTTY_KEY_D, GHOSTTY_KEY_E,
                                     GHOSTTY_KEY_F, GHOSTTY_KEY_G, GHOSTTY_KEY_H, GHOSTTY_KEY_I, GHOSTTY_KEY_J,
                                     GHOSTTY_KEY_K, GHOSTTY_KEY_L, GHOSTTY_KEY_M, GHOSTTY_KEY_N, GHOSTTY_KEY_O,
                                     GHOSTTY_KEY_P, GHOSTTY_KEY_Q, GHOSTTY_KEY_R, GHOSTTY_KEY_S, GHOSTTY_KEY_T,
                                     GHOSTTY_KEY_U, GHOSTTY_KEY_V, GHOSTTY_KEY_W, GHOSTTY_KEY_X, GHOSTTY_KEY_Y,
                                     GHOSTTY_KEY_Z]
        var out = zip(letters, "abcdefghijklmnopqrstuvwxyz").map { ($0, $1, Character($1.uppercased())) }
        let digits: [GhosttyKey] = [GHOSTTY_KEY_DIGIT_0, GHOSTTY_KEY_DIGIT_1, GHOSTTY_KEY_DIGIT_2, GHOSTTY_KEY_DIGIT_3,
                                    GHOSTTY_KEY_DIGIT_4, GHOSTTY_KEY_DIGIT_5, GHOSTTY_KEY_DIGIT_6, GHOSTTY_KEY_DIGIT_7,
                                    GHOSTTY_KEY_DIGIT_8, GHOSTTY_KEY_DIGIT_9]
        out += zip(digits, zip("0123456789", ")!@#$%^&*(")).map { ($0, $1.0, $1.1) }
        out += [(GHOSTTY_KEY_MINUS, "-", "_"), (GHOSTTY_KEY_EQUAL, "=", "+"), (GHOSTTY_KEY_BRACKET_LEFT, "[", "{"),
                (GHOSTTY_KEY_BRACKET_RIGHT, "]", "}"), (GHOSTTY_KEY_BACKSLASH, "\\", "|"), (GHOSTTY_KEY_SEMICOLON, ";", ":"),
                (GHOSTTY_KEY_QUOTE, "'", "\""), (GHOSTTY_KEY_COMMA, ",", "<"), (GHOSTTY_KEY_PERIOD, ".", ">"),
                (GHOSTTY_KEY_SLASH, "/", "?"), (GHOSTTY_KEY_BACKQUOTE, "`", "~")]
        return out
    }()

    /// Nil for a name it doesn't know.
    public init?(_ spec: String) {
        // The last part is the key ("ctrl++" is ctrl and +), the rest modifiers.
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if spec.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var mods = GhosttyMods(0)
        for part in parts {
            switch part.lowercased() {
            case "ctrl", "control": mods |= GhosttyMods(GHOSTTY_MODS_CTRL)
            case "alt", "opt", "option": mods |= GhosttyMods(GHOSTTY_MODS_ALT)
            case "shift": mods |= GhosttyMods(GHOSTTY_MODS_SHIFT)
            case "super", "cmd", "command": mods |= GhosttyMods(GHOSTTY_MODS_SUPER)
            default: return nil
            }
        }
        let shift = mods & GhosttyMods(GHOSTTY_MODS_SHIFT) != 0
        if last.count > 1 || Self.named[last.lowercased()] != nil {
            guard let key = Self.named[last.lowercased()] else { return nil }
            let space = key == GHOSTTY_KEY_SPACE
            self.init(key: key, mods: mods, text: space ? " " : nil, unshiftedCodepoint: space ? 0x20 : 0)
            return
        }
        let ch = Character(last)
        if let (key, plain, shifted) = Self.typing.first(where: { $0.1 == ch || $0.2 == ch }) {
            // A shifted character ("A", "?") is shift and its key.
            let needsShift = ch == shifted && plain != shifted
            if needsShift { mods |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
            let typed = needsShift || shift ? shifted : plain
            self.init(key: key, mods: mods, text: String(typed), unshiftedCodepoint: plain.unicodeScalars.first!.value)
            return
        }
        return nil
    }

    public init(key: GhosttyKey, mods: GhosttyMods, text: String?, unshiftedCodepoint: UInt32) {
        self.key = key
        self.mods = mods
        self.text = text
        self.unshiftedCodepoint = unshiftedCodepoint
    }

    /// Encoded for `terminal` as it is now (cursor keys, the kitty keyboard
    /// protocol…): what the key sends to the program. Call with the
    /// terminal's lock held.
    public func encode(for terminal: GhosttyTerminal, with encoder: GhosttyKeyEncoder, event: GhosttyKeyEvent) -> [UInt8] {
        // A text key whose only modifier is Shift goes out as its text, as the
        // app sends it (see TerminalSession.send), unless the program asked
        // the kitty keyboard protocol for every key.
        var flags: UInt8 = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags)
        if mods == GhosttyMods(GHOSTTY_MODS_SHIFT), flags & 0b1000 == 0, let text, !text.isEmpty {
            return Array(text.utf8)
        }
        ghostty_key_encoder_setopt_from_terminal(encoder, terminal)
        // Alt is Alt here: option-as-alt (there's no keyboard layout to compose with).
        var alt = GHOSTTY_OPTION_AS_ALT_TRUE
        ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &alt)
        ghostty_key_event_set_action(event, GHOSTTY_KEY_ACTION_PRESS)
        ghostty_key_event_set_key(event, key)
        ghostty_key_event_set_mods(event, mods)
        ghostty_key_event_set_consumed_mods(event, 0)
        ghostty_key_event_set_composing(event, false)
        ghostty_key_event_set_unshifted_codepoint(event, unshiftedCodepoint)
        var out = [CChar](repeating: 0, count: 128)
        var len = 0
        let ok: Bool
        if let text, !text.isEmpty {
            ok = text.withCString { ptr in
                ghostty_key_event_set_utf8(event, ptr, text.utf8.count)
                return ghostty_key_encoder_encode(encoder, event, &out, out.count, &len) == GHOSTTY_SUCCESS
            }
        } else {
            ghostty_key_event_set_utf8(event, nil, 0)
            ok = ghostty_key_encoder_encode(encoder, event, &out, out.count, &len) == GHOSTTY_SUCCESS
        }
        guard ok, len > 0 else { return [] }
        return out[..<len].map { UInt8(bitPattern: $0) }
    }
}
