import AppKit
import Carbon.HIToolbox

/// Key names shared by keybinds and global hotkeys, Ghostty-compatible
/// (`a`, `grave`/`backquote`, `equal`, `plus`, `arrow_left`/`left`, `f5`...).
/// Each key has a character, used to match presses on the current keyboard
/// layout and as the menu key equivalent, and a physical key code where one
/// exists, which Carbon's global hotkeys need.
struct KeyName {
    let names: [String]  // canonical first, then aliases
    let code: Int?
    let character: String
    /// Keys that don't type a character: matched by key code, not by layout.
    let isSpecial: Bool

    var name: String { names[0] }

    static let all: [KeyName] = {
        func ch(_ names: [String], _ code: Int?, _ c: String) -> KeyName {
            KeyName(names: names, code: code, character: c, isSpecial: false)
        }
        func sp(_ names: [String], _ code: Int, _ c: Int) -> KeyName {
            KeyName(names: names, code: code, character: String(Character(Unicode.Scalar(UInt32(c))!)), isSpecial: true)
        }
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
                       kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
                       kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
                       kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                      kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        var k: [KeyName] = []
        for (i, code) in letters.enumerated() {
            let c = String(Character(Unicode.Scalar(UInt8(ascii: "a") + UInt8(i))))
            k.append(ch([c], code, c))
        }
        for (i, code) in digits.enumerated() { k.append(ch(["\(i)", "digit_\(i)"], code, "\(i)")) }
        k += [
            ch(["grave", "backquote", "grave_accent", "`"], kVK_ANSI_Grave, "`"),
            ch(["minus", "-"], kVK_ANSI_Minus, "-"), ch(["equal", "="], kVK_ANSI_Equal, "="),
            ch(["plus", "+"], nil, "+"),
            ch(["comma", ","], kVK_ANSI_Comma, ","), ch(["period", "."], kVK_ANSI_Period, "."),
            ch(["slash", "/"], kVK_ANSI_Slash, "/"), ch(["semicolon", ";"], kVK_ANSI_Semicolon, ";"),
            ch(["quote", "apostrophe", "'"], kVK_ANSI_Quote, "'"),
            ch(["bracket_left", "left_bracket", "["], kVK_ANSI_LeftBracket, "["),
            ch(["bracket_right", "right_bracket", "]"], kVK_ANSI_RightBracket, "]"),
            ch(["backslash", "\\"], kVK_ANSI_Backslash, "\\"),
            sp(["space"], kVK_Space, 0x20), sp(["tab"], kVK_Tab, 0x09),
            sp(["enter", "return"], kVK_Return, 0x0D), sp(["escape", "esc"], kVK_Escape, 0x1B),
            sp(["backspace"], kVK_Delete, 0x08), sp(["delete"], kVK_ForwardDelete, NSDeleteFunctionKey),
            sp(["arrow_left", "left"], kVK_LeftArrow, NSLeftArrowFunctionKey),
            sp(["arrow_right", "right"], kVK_RightArrow, NSRightArrowFunctionKey),
            sp(["arrow_up", "up"], kVK_UpArrow, NSUpArrowFunctionKey),
            sp(["arrow_down", "down"], kVK_DownArrow, NSDownArrowFunctionKey),
            sp(["home"], kVK_Home, NSHomeFunctionKey), sp(["end"], kVK_End, NSEndFunctionKey),
            sp(["page_up"], kVK_PageUp, NSPageUpFunctionKey), sp(["page_down"], kVK_PageDown, NSPageDownFunctionKey),
        ]
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in fkeys.enumerated() { k.append(sp(["f\(i + 1)"], code, NSF1FunctionKey + i)) }
        return k
    }()

    private static let byName: [String: KeyName] = {
        var d: [String: KeyName] = [:]
        for key in all { for n in key.names { d[n] = key } }
        return d
    }()
    private static let byCode: [Int: KeyName] = {
        var d: [Int: KeyName] = [:]
        for key in all { if let c = key.code, d[c] == nil { d[c] = key } }
        return d
    }()
    private static let byCharacter: [String: KeyName] = {
        var d: [String: KeyName] = [:]
        for key in all where !key.isSpecial { d[key.character] = key }
        return d
    }()

    static func named(_ name: String) -> KeyName? { byName[name.lowercased()] ?? byName[name] }
    static func code(_ code: Int) -> KeyName? { byCode[code] }
    static func character(_ c: String) -> KeyName? { byCharacter[c.lowercased()] }

    var isFunctionKey: Bool { name.count > 1 && name.hasPrefix("f") && Int(name.dropFirst()) != nil }

    /// Shown in menus and Settings.
    var symbol: String {
        let symbols = ["grave": "`", "space": "Space", "tab": "⇥", "enter": "↩", "escape": "⎋",
                       "backspace": "⌫", "delete": "⌦", "arrow_left": "←", "arrow_right": "→", "arrow_up": "↑",
                       "arrow_down": "↓", "home": "↖", "end": "↘", "page_up": "⇞", "page_down": "⇟"]
        return symbols[name] ?? (isSpecial ? name.uppercased() : character.uppercased())
    }
}

let modifierNames: [String: NSEvent.ModifierFlags] = [
    "ctrl": .control, "control": .control,
    "alt": .option, "opt": .option, "option": .option,
    "shift": .shift,
    "cmd": .command, "command": .command, "super": .command,
]

private let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

func modifierSymbols(_ m: NSEvent.ModifierFlags) -> String {
    (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "")
        + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
}

func modifierConfigNames(_ m: NSEvent.ModifierFlags) -> [String] {
    var parts: [String] = []
    // The order people write them in: ctrl+alt+t, cmd+shift+d.
    if m.contains(.control) { parts.append("ctrl") }
    if m.contains(.option) { parts.append("alt") }
    if m.contains(.command) { parts.append("cmd") }
    if m.contains(.shift) { parts.append("shift") }
    return parts
}

/// A key press that triggers a keybind: `cmd+shift+d`, `ctrl+grave`, `f5`.
struct Trigger: Hashable {
    let key: String  // canonical KeyName.name
    let modifiers: UInt  // NSEvent.ModifierFlags raw value, relevant bits only

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var keyName: KeyName { KeyName.named(key)! }

    init(key: KeyName, modifiers: NSEvent.ModifierFlags) {
        self.key = key.name
        self.modifiers = modifiers.intersection(relevantModifiers).rawValue
    }

    init?(_ text: String) {
        // "cmd+plus" and "cmd++": a trailing "+" is the key itself.
        var spec = text.trimmingCharacters(in: .whitespaces)
        var parts: [String]
        if spec.hasSuffix("++") || spec == "+" {
            spec.removeLast()
            parts = spec.split(separator: "+").map(String.init) + ["+"]
        } else {
            parts = spec.split(separator: "+").map(String.init)
        }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, let key = KeyName.named(last) else { return nil }
        var mods: NSEvent.ModifierFlags = []
        for name in parts.dropLast() {
            guard let flag = modifierNames[name.lowercased()] else { return nil }
            mods.insert(flag)
        }
        self.init(key: key, modifiers: mods)
    }

    /// The trigger a key press spells, read on the current keyboard layout
    /// (so `cmd+d` is the key that types "d", on Dvorak too).
    init?(event: NSEvent) {
        guard let key = Self.keyName(of: event) else { return nil }
        self.init(key: key, modifiers: event.modifierFlags)
    }

    private static func keyName(of event: NSEvent) -> KeyName? {
        if let named = KeyName.code(Int(event.keyCode)), named.isSpecial { return named }
        guard let c = event.characters(byApplyingModifiers: []), c.count == 1 else { return nil }
        return KeyName.character(c)
    }

    /// Every trigger a press could match, most specific first: `cmd+shift+=`
    /// is also `cmd++` on layouts where Shift+= types "+".
    static func candidates(for event: NSEvent) -> [Trigger] {
        guard let key = keyName(of: event) else { return [] }
        var list = [Trigger(key: key, modifiers: event.modifierFlags)]
        if !key.isSpecial, event.modifierFlags.contains(.shift),
           let shifted = event.characters(byApplyingModifiers: [.shift]), shifted.count == 1,
           let shiftedKey = KeyName.character(shifted), shiftedKey.name != key.name {
            list.append(Trigger(key: shiftedKey, modifiers: event.modifierFlags.subtracting(.shift)))
        }
        return list
    }

    var configString: String { (modifierConfigNames(flags) + [key]).joined(separator: "+") }
    var displayString: String { modifierSymbols(flags) + keyName.symbol }

    /// For NSMenuItem: the key equivalent string and its modifier mask.
    var menuEquivalent: (String, NSEvent.ModifierFlags) { (keyName.character, flags) }

    /// The physical-key form Carbon's global hotkeys need, if the key has one.
    var shortcut: Shortcut? {
        guard let code = keyName.code else { return nil }
        return Shortcut(keyCode: UInt32(code), modifiers: flags)
    }
}

// MARK: - Actions

/// What a keybind does. Names and arguments are Ghostty's keybind actions,
/// so bindings copy between the two.
enum Action: Equatable {
    enum Direction: String, CaseIterable { case left, right, up, down }
    enum SplitTarget: Equatable { case direction(Direction), previous, next }

    case newWindow, newTab, newSplit(Direction)
    case closeSurface, closeTab, closeWindow, closeAllWindows
    case previousTab, nextTab, gotoTab(Int), lastTab
    case gotoSplit(SplitTarget), resizeSplit(Direction, Int), equalizeSplits, toggleSplitZoom
    case increaseFontSize(Double), decreaseFontSize(Double), resetFontSize
    case copyToClipboard, pasteFromClipboard, selectAll, clearScreen
    case scrollToTop, scrollToBottom, scrollPageUp, scrollPageDown, scrollPageLines(Int), jumpToPrompt(Int)
    case text(String), csi(String), esc(String)
    case promptSurfaceTitle, promptTabTitle, toggleReadonly
    case startSearch, endSearch, searchSelection, navigateSearch(next: Bool)
    case toggleSidebar, toggleInspector, toggleMarkdownSource, toggleEditor
    case toggleFullscreen, toggleVisibility, toggleWindowFloatOnTop, resetWindowSize, toggleSecureInput
    case toggleCommandPalette, toggleQuickTerminal, toggleTabOverview, connectToHost, togglePictureInPicture
    case gotoPane, gotoDirectory, restartSurface, parkSurface, unparkSurface, floatSurface
    case moveSurfaceToNewTab, moveSurfaceToNewWindow, moveSurfaceToTab(Int), moveTabToNewWindow
    case newWorkspace, renameWorkspace, closeWorkspace, nextWorkspace, previousWorkspace, gotoWorkspace(Int)
    case openGit, openBrowser, focusAddress, openTasks, newCanvas, openProfiler, openBoard, openPlugins, openScreen
    case toggleBroadcastInput, copyCommandOutput, writeScrollbackFile(String), writeSelectionFile(String)
    case undo, redo
    case openConfig, reloadConfig, quit
    case ignore, unbind

    /// Actions without an argument, by Ghostty name.
    private static let simple: [(String, Action)] = [
        ("new_window", .newWindow), ("new_tab", .newTab),
        ("close_surface", .closeSurface), ("close_tab", .closeTab), ("close_window", .closeWindow),
        ("close_all_windows", .closeAllWindows),
        ("previous_tab", .previousTab), ("next_tab", .nextTab), ("last_tab", .lastTab),
        ("equalize_splits", .equalizeSplits), ("toggle_split_zoom", .toggleSplitZoom),
        ("reset_font_size", .resetFontSize),
        ("copy_to_clipboard", .copyToClipboard), ("paste_from_clipboard", .pasteFromClipboard),
        ("select_all", .selectAll), ("clear_screen", .clearScreen),
        ("scroll_to_top", .scrollToTop), ("scroll_to_bottom", .scrollToBottom),
        ("scroll_page_up", .scrollPageUp), ("scroll_page_down", .scrollPageDown),
        ("prompt_surface_title", .promptSurfaceTitle), ("prompt_tab_title", .promptTabTitle),
        ("toggle_readonly", .toggleReadonly),
        ("start_search", .startSearch), ("end_search", .endSearch), ("search_selection", .searchSelection),
        ("toggle_sidebar", .toggleSidebar), ("toggle_inspector", .toggleInspector),
        ("toggle_markdown_source", .toggleMarkdownSource), ("toggle_editor", .toggleEditor),
        ("toggle_fullscreen", .toggleFullscreen), ("toggle_visibility", .toggleVisibility),
        ("toggle_window_float_on_top", .toggleWindowFloatOnTop), ("reset_window_size", .resetWindowSize),
        ("toggle_secure_input", .toggleSecureInput),
        ("toggle_command_palette", .toggleCommandPalette), ("toggle_quick_terminal", .toggleQuickTerminal),
        ("toggle_tab_overview", .toggleTabOverview), ("connect_to_host", .connectToHost),
        ("goto_pane", .gotoPane), ("go_to_directory", .gotoDirectory), ("restart_surface", .restartSurface),
        ("park_surface", .parkSurface), ("unpark_surface", .unparkSurface), ("float_surface", .floatSurface),
        ("move_surface_to_new_tab", .moveSurfaceToNewTab), ("move_surface_to_new_window", .moveSurfaceToNewWindow),
        ("move_tab_to_new_window", .moveTabToNewWindow),
        ("new_workspace", .newWorkspace), ("rename_workspace", .renameWorkspace), ("close_workspace", .closeWorkspace),
        ("next_workspace", .nextWorkspace), ("previous_workspace", .previousWorkspace),
        ("open_git", .openGit), ("open_browser", .openBrowser), ("focus_address", .focusAddress), ("open_tasks", .openTasks), ("new_canvas", .newCanvas), ("open_profiler", .openProfiler), ("open_board", .openBoard), ("open_plugins", .openPlugins), ("open_screen", .openScreen),
        ("toggle_picture_in_picture", .togglePictureInPicture),
        ("toggle_broadcast_input", .toggleBroadcastInput), ("copy_command_output", .copyCommandOutput),
        ("undo", .undo), ("redo", .redo),
        ("open_config", .openConfig), ("reload_config", .reloadConfig), ("quit", .quit),
        ("ignore", .ignore), ("unbind", .unbind),
    ]

    init?(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let arg = parts.count > 1 ? parts[1] : nil
        if let (_, action) = Self.simple.first(where: { $0.0 == name }) {
            guard arg == nil || action == .copyToClipboard else { return nil }  // copy_to_clipboard:mixed
            self = action
            return
        }
        func direction() -> Direction? {
            guard let a = arg?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
            return a == "auto" ? .right : a == "top" ? .up : a == "bottom" ? .down : Direction(rawValue: a)
        }
        func number(_ fallback: Double) -> Double? { arg.map { Double($0.trimmingCharacters(in: .whitespaces)) } ?? fallback }
        func integer() -> Int? { arg.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        switch name {
        case "new_split": guard let d = arg == nil ? .right : direction() else { return nil }; self = .newSplit(d)
        case "goto_tab": guard let n = integer(), n > 0 else { return nil }; self = .gotoTab(n)
        case "goto_workspace": guard let n = integer(), n > 0 else { return nil }; self = .gotoWorkspace(n)
        case "move_surface_to_tab": guard let n = integer(), n > 0 else { return nil }; self = .moveSurfaceToTab(n)
        case "write_scrollback_file", "write_selection_file":
            let then = arg?.trimmingCharacters(in: .whitespaces).lowercased() ?? "open"
            guard ["open", "copy", "paste", "save"].contains(then) else { return nil }
            self = name == "write_scrollback_file" ? .writeScrollbackFile(then) : .writeSelectionFile(then)
        case "navigate_search":
            switch arg?.lowercased() {
            case "next": self = .navigateSearch(next: true)
            case "previous": self = .navigateSearch(next: false)
            default: return nil
            }
        case "goto_split":
            switch arg?.lowercased() {
            case "previous": self = .gotoSplit(.previous)
            case "next": self = .gotoSplit(.next)
            default: guard let d = direction() else { return nil }; self = .gotoSplit(.direction(d))
            }
        case "resize_split":
            guard let a = arg else { return nil }
            let p = a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard let d = p.first.flatMap(Direction.init(rawValue:)) else { return nil }
            let amount = p.count > 1 ? Int(p[1]) : 10
            guard let amount, amount > 0 else { return nil }
            self = .resizeSplit(d, amount)
        case "increase_font_size": guard let n = number(1), n > 0 else { return nil }; self = .increaseFontSize(n)
        case "decrease_font_size": guard let n = number(1), n > 0 else { return nil }; self = .decreaseFontSize(n)
        case "scroll_page_lines": guard let n = integer(), n != 0 else { return nil }; self = .scrollPageLines(n)
        case "jump_to_prompt": guard let n = integer(), n != 0 else { return nil }; self = .jumpToPrompt(n)
        case "text": guard let a = arg, let s = Self.unescape(a) else { return nil }; self = .text(s)
        case "csi": guard let a = arg, !a.isEmpty else { return nil }; self = .csi(a)
        case "esc": guard let a = arg, !a.isEmpty else { return nil }; self = .esc(a)
        default: return nil
        }
    }

    var configString: String {
        if let (name, _) = Self.simple.first(where: { $0.1 == self }) { return name }
        switch self {
        case .newSplit(let d): return "new_split:\(d.rawValue)"
        case .gotoTab(let n): return "goto_tab:\(n)"
        case .gotoWorkspace(let n): return "goto_workspace:\(n)"
        case .moveSurfaceToTab(let n): return "move_surface_to_tab:\(n)"
        case .writeScrollbackFile(let then): return "write_scrollback_file:\(then)"
        case .writeSelectionFile(let then): return "write_selection_file:\(then)"
        case .navigateSearch(let next): return "navigate_search:" + (next ? "next" : "previous")
        case .gotoSplit(.previous): return "goto_split:previous"
        case .gotoSplit(.next): return "goto_split:next"
        case .gotoSplit(.direction(let d)): return "goto_split:\(d.rawValue)"
        case .resizeSplit(let d, let n): return "resize_split:\(d.rawValue),\(n)"
        case .increaseFontSize(let n): return "increase_font_size:\(Self.format(n))"
        case .decreaseFontSize(let n): return "decrease_font_size:\(Self.format(n))"
        case .scrollPageLines(let n): return "scroll_page_lines:\(n)"
        case .jumpToPrompt(let n): return "jump_to_prompt:\(n)"
        case .text(let s): return "text:\(Self.escape(s))"
        case .csi(let s): return "csi:\(s)"
        case .esc(let s): return "esc:\(s)"
        default: return "?"
        }
    }

    /// Bytes that go straight to the program, rather than an app action.
    var sendsInput: Bool {
        switch self { case .text, .csi, .esc: true; default: false }
    }

    /// For `libertty +list-actions`.
    static let catalog: [(String, String)] = [
        ("new_window", "Open a new window"), ("new_tab", "Open a new tab"),
        ("new_split:right|down|left|up", "Split the focused pane"),
        ("close_surface", "Close the focused pane (the tab, if it's the last)"), ("close_tab", "Close the tab"),
        ("close_window", "Close the window and all its tabs"), ("close_all_windows", "Close every window"),
        ("previous_tab", "Select the tab to the left"), ("next_tab", "Select the tab to the right"),
        ("goto_tab:N", "Select tab N"), ("last_tab", "Select the last tab"),
        ("goto_split:left|right|up|down|previous|next", "Focus another pane"),
        ("resize_split:DIRECTION,POINTS", "Move the divider of the focused pane, e.g. resize_split:right,20"),
        ("equalize_splits", "Make every split even"), ("toggle_split_zoom", "Let the focused pane fill the window, or undo"),
        ("increase_font_size:N", "Bigger text by N points"), ("decrease_font_size:N", "Smaller text by N points"),
        ("reset_font_size", "Back to the configured font size"),
        ("copy_to_clipboard", "Copy the selection"), ("paste_from_clipboard", "Paste"), ("select_all", "Select everything"),
        ("clear_screen", "Clear the screen and scrollback; the shell redraws its prompt"),
        ("scroll_to_top", "Scroll to the start of the scrollback"), ("scroll_to_bottom", "Scroll back to the prompt"),
        ("scroll_page_up", "Scroll up a page"), ("scroll_page_down", "Scroll down a page"),
        ("scroll_page_lines:N", "Scroll N lines (negative is up)"),
        ("jump_to_prompt:N", "Scroll to the Nth previous (negative) or next prompt; needs shell integration"),
        ("text:STRING", "Send text, with escapes like \\n \\t \\x1b \\u{2318}"), ("csi:STRING", "Send ESC [ STRING"),
        ("esc:STRING", "Send ESC STRING"),
        ("prompt_surface_title", "Ask for a title for the focused pane"), ("prompt_tab_title", "Ask for a title for the tab"),
        ("toggle_readonly", "Stop (or resume) sending input to the focused pane"),
        ("start_search", "Find in scrollback"), ("end_search", "Close the find bar"),
        ("navigate_search:next|previous", "Go to the next (older) or previous match"),
        ("search_selection", "Find the selected text"),
        ("toggle_sidebar", "Show or hide the sidebar (tabs and files)"),
        ("toggle_inspector", "Show or hide the inspector (directory, git, processes, ports)"),
        ("toggle_markdown_source", "Show the open Markdown document's source, or render it again"),
        ("toggle_editor", "Edit the document in front (⌘S saves), or show it as a page again (saving first)"),
        ("toggle_fullscreen", "Enter or leave full screen"), ("toggle_visibility", "Show or hide Libertty (good as a global: key)"),
        ("toggle_window_float_on_top", "Keep the window above other apps' windows, or stop"),
        ("reset_window_size", "Back to window-columns × window-rows"),
        ("toggle_secure_input", "Secure Keyboard Entry: keep other apps from reading keystrokes"),
        ("toggle_command_palette", "Search every command, tab, session and theme by name"),
        ("goto_pane", "Go to any pane of any window, by its program, folder or tab"),
        ("go_to_directory", "A new tab in a folder: where panes are, where shells have been, or a path typed (/ or ~)"),
        ("restart_surface", "End the focused pane's program and start a fresh shell in its place"),
        ("park_surface", "Take the focused pane out of the split, its program still running"),
        ("unpark_surface", "Put the latest parked pane back beside the pane it stood by"),
        ("float_surface", "Show the focused pane live in a corner of the split (picture in picture in the window), or bring it back"),
        ("move_surface_to_new_tab", "Take the focused pane out of its split into a tab of its own, its program running on"),
        ("move_surface_to_tab:N", "Move the focused pane into tab N's split, beside its focused pane"),
        ("move_surface_to_new_window", "Take the focused pane out of its split into a window of its own"),
        ("move_tab_to_new_window", "Take the tab in front out of this window into a window of its own"),
        ("new_workspace", "A new workspace in this window: a named set of tabs, with a shell of its own"),
        ("rename_workspace", "Rename the workspace in front"),
        ("close_workspace", "End the workspace in front with its tabs and programs"),
        ("next_workspace", "Show the next workspace of the window"), ("previous_workspace", "Show the previous workspace"),
        ("goto_workspace:N", "Show workspace N of the window"),
        ("open_git", "The Git client for the focused pane's repository: changes, history, branches, stashes"),
        ("open_browser", "A browser tab (its address bar to type in)"),
        ("open_tasks", "The task manager: every process, its CPU and memory, the ones in each terminal"),
        ("focus_address", "In a browser: the address bar"),
        ("open_screen", "Screen sharing: a display or a window of this Mac, shown in a block (needs Screen Recording permission)"),
        ("open_plugins", "Plugins: JavaScript in the config folder's plugins/, each turned on or off here, with its log"),
        ("open_board", "The board (kanban) of the focused pane's repository, kept as Markdown in its BOARD.md; *.board.md files open as boards too"),
        ("open_profiler", "The profiler: record a process in a terminal with sample, see it as a flame graph (speedscope)"),
        ("new_canvas", "A new drawing (Excalidraw), kept in Libertty's Canvases folder; .excalidraw files open in it too"),
        ("toggle_tab_overview", "Every tab of the window as a thumbnail; pick one"),
        ("connect_to_host", "A window whose sessions run on another machine over ssh, and survive the link dropping"),
        ("toggle_picture_in_picture", "Show the focused pane, live, in a small window that floats over every app, or close it"),
        ("toggle_broadcast_input", "Type into every pane of the tab at once, or stop"),
        ("undo", "Bring back the pane, tab or window closed last (within undo-timeout)"),
        ("redo", "Close it again"),
        ("copy_command_output", "Copy what the last command printed (needs shell integration)"),
        ("write_scrollback_file:open|copy|paste|save", "Put the scrollback in a text file and open it in a tab, copy or paste its path, or save it where you choose"),
        ("write_selection_file:open|copy|paste|save", "The same for the selection"),
        ("toggle_quick_terminal", "Drop a terminal down from the top of the screen, or put it away (good as a global: key)"),
        ("open_config", "Open the config file in your text editor"), ("reload_config", "Reload the config file"),
        ("quit", "Quit Libertty"),
        ("ignore", "Swallow the key so nothing happens"), ("unbind", "Remove a binding, so the key reaches the program"),
    ]

    private static func format(_ n: Double) -> String {
        n == n.rounded() ? String(Int(n)) : String(n)
    }

    /// Zig-style escapes, as Ghostty's `text:` uses: \n \r \t \\ \" \e \xHH \u{H...}.
    static func unescape(_ s: String) -> String? {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let e = it.next() else { return nil }
            switch e {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "e": out.append("\u{1b}")
            case "\\": out.append("\\")
            case "\"": out.append("\"")
            case "'": out.append("'")
            case "x":
                guard let a = it.next(), let b = it.next(), let v = UInt8(String([a, b]), radix: 16) else { return nil }
                out.unicodeScalars.append(Unicode.Scalar(v))
            case "u":
                guard it.next() == "{" else { return nil }
                var hex = ""
                while let h = it.next(), h != "}" { hex.append(h) }
                guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else { return nil }
                out.unicodeScalars.append(scalar)
            default: return nil
            }
        }
        return out
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\\": out += "\\\\"
            default:
                if u.value < 0x20 || u.value == 0x7F { out += String(format: "\\x%02x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out
    }
}

// MARK: - The table

/// The effective keybinds: Libertty's defaults, then the user's `keybind`
/// lines in order. `keybind = clear` drops everything before it,
/// `TRIGGER=unbind` removes one, and a `global:` prefix makes a binding
/// work system-wide.
struct Keybinds: Equatable {
    struct Binding: Equatable {
        var trigger: Trigger
        var action: Action
    }

    private(set) var local: [Binding] = []
    private(set) var global: [Binding] = []
    private var index: [Trigger: Action] = [:]

    /// Ghostty's macOS defaults (src/config/Config.zig), minus actions
    /// Libertty doesn't have yet (search, inspector, command palette, undo).
    static let defaults: [String] = {
        var d = [
            "cmd+comma=open_config", "cmd+shift+comma=reload_config", "cmd+q=quit",
            "cmd+shift+p=toggle_command_palette", "cmd+shift+backslash=toggle_tab_overview",
            "cmd+shift+k=connect_to_host",
            "cmd+f=start_search", "escape=end_search", "cmd+e=search_selection",
            "cmd+g=navigate_search:next", "cmd+shift+g=navigate_search:previous",
            "cmd+ctrl+s=toggle_sidebar", "cmd+alt+i=toggle_inspector",
            "cmd+c=copy_to_clipboard", "cmd+v=paste_from_clipboard", "cmd+a=select_all", "cmd+k=clear_screen",
            "cmd+equal=increase_font_size:1", "cmd+plus=increase_font_size:1",
            "cmd+minus=decrease_font_size:1", "cmd+0=reset_font_size",
            "cmd+n=new_window", "cmd+t=new_tab",
            "cmd+w=close_surface", "cmd+alt+w=close_tab", "cmd+shift+w=close_window",
            "cmd+alt+shift+w=close_all_windows",
            "cmd+shift+r=prompt_tab_title", "cmd+p=goto_pane",
            "cmd+shift+bracket_left=previous_tab", "cmd+shift+bracket_right=next_tab",
            "ctrl+shift+tab=previous_tab", "ctrl+tab=next_tab", "cmd+9=last_tab",
            "cmd+d=new_split:right", "cmd+shift+d=new_split:down",
            "cmd+bracket_left=goto_split:previous", "cmd+bracket_right=goto_split:next",
            "cmd+alt+arrow_up=goto_split:up", "cmd+alt+arrow_down=goto_split:down",
            "cmd+alt+arrow_left=goto_split:left", "cmd+alt+arrow_right=goto_split:right",
            "cmd+ctrl+arrow_up=resize_split:up,10", "cmd+ctrl+arrow_down=resize_split:down,10",
            "cmd+ctrl+arrow_left=resize_split:left,10", "cmd+ctrl+arrow_right=resize_split:right,10",
            "cmd+ctrl+equal=equalize_splits", "cmd+shift+enter=toggle_split_zoom",
            "cmd+enter=toggle_fullscreen", "cmd+ctrl+f=toggle_fullscreen",
            "cmd+home=scroll_to_top", "cmd+end=scroll_to_bottom",
            "cmd+page_up=scroll_page_up", "cmd+page_down=scroll_page_down",
            "cmd+arrow_up=jump_to_prompt:-1", "cmd+arrow_down=jump_to_prompt:1",
            "cmd+shift+arrow_up=jump_to_prompt:-1", "cmd+shift+arrow_down=jump_to_prompt:1",
            "cmd+arrow_right=text:\\x05", "cmd+arrow_left=text:\\x01", "cmd+backspace=text:\\x15",
            "alt+arrow_left=esc:b", "alt+arrow_right=esc:f",
        ]
        for i in 1...8 { d.append("cmd+\(i)=goto_tab:\(i)") }
        return d
    }()

    /// Parse one `keybind` value. Returns a problem, or nil if it's valid.
    static func validate(_ entry: String) -> String? {
        let e = entry.trimmingCharacters(in: .whitespaces)
        if e == "clear" { return nil }
        guard let (triggerText, actionText, _) = split(e) else { return "expected TRIGGER=ACTION (e.g. cmd+d=new_split:right)" }
        guard Trigger(triggerText) != nil else { return "unknown key or modifier in “\(triggerText)”" }
        guard Action(actionText) != nil else { return "unknown action “\(actionText)” (see libertty +list-actions)" }
        return nil
    }

    /// One `keybind` value as (trigger, action, global), or nil if malformed.
    static func parse(_ entry: String) -> (Trigger, Action, Bool)? {
        guard let (t, a, g) = split(entry.trimmingCharacters(in: .whitespaces)),
              let trigger = Trigger(t), let action = Action(a) else { return nil }
        return (trigger, action, g)
    }

    /// `[global:]TRIGGER=ACTION`, split at the first "=" after the trigger
    /// (a trigger may itself end in "=", as in `cmd+=`).
    private static func split(_ entry: String) -> (String, String, Bool)? {
        var e = entry
        var isGlobal = false
        if e.hasPrefix("global:") { isGlobal = true; e.removeFirst("global:".count) }
        var searchFrom = e.startIndex
        // Skip a "=" that is the trigger's own key: "cmd+=" or "=".
        if e.hasPrefix("=") { searchFrom = e.index(after: e.startIndex) }
        if let r = e.range(of: "+=", range: searchFrom..<e.endIndex), e[r.upperBound...].hasPrefix("=") {
            searchFrom = r.upperBound
        }
        guard let eq = e[searchFrom...].firstIndex(of: "=") else { return nil }
        let trigger = String(e[..<eq]).trimmingCharacters(in: .whitespaces)
        let action = String(e[e.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty, !action.isEmpty else { return nil }
        return (trigger, action, isGlobal)
    }

    init(entries: [String], includeDefaults: Bool = true) {
        for entry in (includeDefaults ? Self.defaults : []) + entries {
            let e = entry.trimmingCharacters(in: .whitespaces)
            if e == "clear" {
                local.removeAll()
                global.removeAll()
                continue
            }
            guard let (t, a, isGlobal) = Self.split(e), let trigger = Trigger(t), let action = Action(a) else { continue }
            if isGlobal {
                global.removeAll { $0.trigger == trigger }
                if action != .unbind { global.append(Binding(trigger: trigger, action: action)) }
            } else {
                local.removeAll { $0.trigger == trigger }
                if action != .unbind { local.append(Binding(trigger: trigger, action: action)) }
            }
        }
        for b in local { index[b.trigger] = b.action }
    }

    func action(for event: NSEvent) -> Action? {
        for t in Trigger.candidates(for: event) { if let a = index[t] { return a } }
        return nil
    }

    /// The first trigger bound to `action`, for the menu's key equivalent.
    func trigger(for action: Action) -> Trigger? {
        local.first { $0.action == action }?.trigger
    }
}
