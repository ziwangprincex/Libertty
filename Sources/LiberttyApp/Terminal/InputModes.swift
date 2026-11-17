import CGhosttyVt

/// The modes a program turns on to read the mouse and the keyboard its own
/// way: mouse reporting, focus reporting, bracketed paste and the kitty
/// keyboard flags.
///
/// A program that ends properly turns off what it turned on. One that is
/// killed (`kill -9 vim`, `kill -9 htop`) or crashes never gets the chance,
/// and the shell is left with them on: moving the mouse types escape bytes
/// at its prompt, and keys arrive in kitty's encoding, which the shell
/// doesn't read.
///
/// So the modes are noted as each command starts (OSC 133;C, by when the
/// shell has finished its prompt) and put back as it ends (OSC 133;D). A
/// program that put them back itself changes nothing; one that was killed
/// has its leftovers undone. What the shell sets for itself is never
/// fought: fish turns on the kitty keyboard protocol and bracketed paste at
/// its prompt, zsh and bash bracketed paste, and that comes after its own
/// marks in the stream — later than this, so it stands. What's put back is
/// the shell's own state from before the command, whatever that was.
struct InputModes: Equatable {
    /// The watched modes, on or off, by DEC mode number.
    var modes: [UInt16: Bool]
    var kittyFlags: UInt8

    /// Modes no shell wants left on by a program that has gone: the four
    /// mouse reporting modes, focus reporting and bracketed paste. The
    /// mouse formats (1005, 1006, 1015, 1016) are left alone: they say how
    /// a report reads, and with no reporting on there is none to read.
    static let watched: [UInt16] = [9, 1000, 1002, 1003, 1004, 2004]

    /// What the terminal has now. The caller holds the session's lock.
    static func read(_ terminal: GhosttyTerminal) -> InputModes {
        var flags: UInt8 = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags)
        var modes: [UInt16: Bool] = [:]
        for number in watched { modes[number] = isOn(terminal, number) }
        return InputModes(modes: modes, kittyFlags: flags)
    }

    private static func isOn(_ terminal: GhosttyTerminal, _ number: UInt16) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(number, false), value: false)
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &config)
        return config.value
    }

    /// Put the modes back. Returns the kitty keyboard flags if those differ
    /// too: they are only set by the sequence that sets them, which a parse
    /// callback can't write. The caller holds the session's lock.
    func restore(_ terminal: GhosttyTerminal) -> UInt8? {
        // The ones to turn off first: the mouse reporting modes rule each
        // other out, so one going off mustn't follow another coming on.
        for wanted in [false, true] {
            for number in Self.watched where modes[number] == wanted {
                var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(number, false), value: wanted)
                _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &config)
            }
        }
        var flags: UInt8 = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags)
        return flags == kittyFlags ? nil : kittyFlags
    }

    /// The sequence that sets the kitty keyboard flags to `flags`: all of
    /// them, to these (CSI = flags ; 1 u).
    static func kittySequence(_ flags: UInt8) -> [UInt8] { Array("\u{1b}[=\(flags);1u".utf8) }

    /// What the UI probe checks: whether the mouse is reported at all,
    /// focus reporting, bracketed paste, and the kitty keyboard flags.
    var summary: [String: String] {
        [
            "mouse": [9, 1000, 1002, 1003].contains { modes[UInt16($0)] == true } ? "on" : "off",
            "focus": modes[1004] == true ? "on" : "off",
            "paste": modes[2004] == true ? "on" : "off",
            "kitty": String(kittyFlags),
        ]
    }
}
