import AppKit
import Carbon.HIToolbox
import Testing
@testable import LiberttyApp

/// Key sequences (`keybind = ctrl+b>v=new_split:right`): how they're read,
/// what they take from the bindings of one key, and a sequence under way.
struct KeySequenceTests {
    private func keys(_ text: String) -> [Trigger] { Trigger.sequence(text) ?? [] }

    @Test func sequencesParse() throws {
        let sequence = try #require(Trigger.sequence("ctrl+b>shift+5"))
        #expect(sequence.count == 2)
        #expect(sequence.configString == "ctrl+b>shift+5")
        #expect(sequence.displayString == "⌃B ⇧5")
        // One trigger is a sequence of one.
        #expect(Trigger.sequence("cmd+d") == [Trigger("cmd+d")!])
        for bad in ["ctrl+b>", ">v", "ctrl+b>>v", "ctrl+b>nosuchkey", ""] {
            #expect(Trigger.sequence(bad) == nil, "\(bad)")
        }
    }

    @Test func validation() {
        #expect(Keybinds.validate("ctrl+b>v=new_split:right") == nil)
        #expect(Keybinds.validate("ctrl+b>ctrl+b=text:\\x02") == nil)
        #expect(Keybinds.validate("ctrl+b>v=unbind") == nil)
        #expect(Keybinds.validate("ctrl+b>=new_tab") != nil)
        #expect(Keybinds.validate("ctrl+b>v=no_such_action") != nil)
        // The system takes a global key at once.
        #expect(Keybinds.validate("global:ctrl+b>v=new_window") != nil)
        #expect(Keybinds.parse("global:ctrl+b>v=new_window") == nil)
        #expect(Keybinds(entries: ["global:ctrl+b>v=new_window"]).global.isEmpty)
    }

    @Test func aSequenceIsFollowedKeyByKey() {
        let table = Keybinds(entries: ["ctrl+b>v=new_split:right", "ctrl+b>g>g=scroll_to_top"])
        #expect(table.step(after: [], keys("ctrl+b")) == .more(Trigger("ctrl+b")!))
        #expect(table.step(after: keys("ctrl+b"), keys("v")) == .action(.newSplit(.right)))
        #expect(table.step(after: keys("ctrl+b"), keys("g")) == .more(Trigger("g")!))
        #expect(table.step(after: keys("ctrl+b>g"), keys("g")) == .action(.scrollToTop))
        #expect(table.step(after: keys("ctrl+b"), keys("x")) == .none)
        // A sequence's second key isn't bound by itself.
        #expect(table.step(after: [], keys("v")) == .none)
        // One press still does what it did.
        #expect(table.step(after: [], keys("cmd+t")) == .action(.newTab))
        // The second trigger a press could be (cmd+shift+= is cmd++) counts in a sequence too.
        let plus = Keybinds(entries: ["ctrl+b>plus=equalize_splits"])
        #expect(plus.step(after: keys("ctrl+b"), keys("shift+equal") + keys("plus")) == .action(.equalizeSplits))
    }

    /// Ghostty's rules for a key that is both.
    @Test func sequencesAndSingleKeysTakeFromEachOther() {
        // A sequence takes its first key from what the key did alone (here a default).
        let taken = Keybinds(entries: ["cmd+k>cmd+s=open_settings"])
        #expect(taken.trigger(for: .clearScreen) == nil)
        #expect(taken.step(after: [], keys("cmd+k")) == .more(Trigger("cmd+k")!))
        // The key bound alone again: every sequence that starts with it goes.
        let back = Keybinds(entries: ["ctrl+b>v=new_split:right", "ctrl+b>c=new_tab", "ctrl+b=new_window"])
        #expect(back.sequences.isEmpty)
        #expect(back.step(after: [], keys("ctrl+b")) == .action(.newWindow))
        // unbind removes the one sequence…
        let one = Keybinds(entries: ["ctrl+b>v=new_split:right", "ctrl+b>c=new_tab", "ctrl+b>v=unbind"])
        #expect(one.sequences.map(\.triggers.configString) == ["ctrl+b>c"])
        #expect(one.step(after: keys("ctrl+b"), keys("v")) == .none)
        // …and of the first key, all of them.
        #expect(Keybinds(entries: ["ctrl+b>v=new_split:right", "ctrl+b>c=new_tab", "ctrl+b=unbind"]).sequences.isEmpty)
        // A longer sequence through a shorter one replaces it, and the other way round.
        let longer = Keybinds(entries: ["ctrl+b>v=new_tab", "ctrl+b>v>v=new_window"])
        #expect(longer.sequences.map(\.triggers.configString) == ["ctrl+b>v>v"])
        let shorter = Keybinds(entries: ["ctrl+b>v>v=new_window", "ctrl+b>v=new_tab"])
        #expect(shorter.sequences.map(\.triggers.configString) == ["ctrl+b>v"])
        // The same sequence twice: the later line.
        let again = Keybinds(entries: ["ctrl+b>v=new_tab", "ctrl+b>v=new_window"])
        #expect(again.sequences == [Keybinds.KeySequence(triggers: keys("ctrl+b>v"), action: .newWindow)])
        #expect(Keybinds(entries: ["ctrl+b>v=new_tab", "clear"]).sequences.isEmpty)
    }

    @Test func theKeysShownForAnAction() {
        let table = Keybinds(entries: ["ctrl+b>z=toggle_split_zoom", "cmd+shift+enter=unbind", "ctrl+b>c=new_tab"])
        #expect(table.keys(for: .toggleSplitZoom) == "⌃B Z")
        // One press, where there is one.
        #expect(table.keys(for: .newTab) == "⌘T")
        #expect(table.keys(for: .openBoard) == nil)
        // A menu shows one press only.
        #expect(table.trigger(for: .toggleSplitZoom) == nil)
    }

    private func press(_ code: Int, _ base: String, _ flags: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent {
        var characters = base
        if flags.contains(.control), let ascii = base.unicodeScalars.first?.value {
            characters = String(UnicodeScalar(UInt8(ascii & 0x1f)))
        }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                context: nil, characters: characters, charactersIgnoringModifiers: base,
                                isARepeat: repeated, keyCode: UInt16(code))!
    }

    /// The keys of a sequence under way are held back, and sent on if it leads nowhere.
    @Test @MainActor func aSequenceUnderWay() {
        let table = Keybinds(entries: ["ctrl+b>v=new_split:right", "ctrl+b>ctrl+b=text:\\x02"])
        let pane = NSObject(), other = NSObject()
        let pending = PendingKeys()
        var sent: [NSEvent] = []
        func key(_ event: NSEvent, in owner: AnyObject? = nil) -> PendingKeys.Outcome {
            pending.press(event, in: owner ?? pane, keybinds: table) { sent.append($0) }
        }
        let prefix = press(kVK_ANSI_B, "b", .control)

        // The prefix, then its key.
        #expect(key(prefix) == .held)
        #expect(pending.pressed.configString == "ctrl+b")
        #expect(key(press(kVK_ANSI_V, "v")) == .completed(.newSplit(.right)))
        #expect(pending.pressed.isEmpty && sent.isEmpty)
        // The last key held down doesn't type into the program.
        #expect(key(press(kVK_ANSI_V, "v", repeated: true)) == .held)
        #expect(key(press(kVK_ANSI_V, "v")) == .unbound)

        // The prefix twice: itself, for the program.
        #expect(key(prefix) == .held)
        #expect(key(press(kVK_ANSI_B, "b", .control, repeated: true)) == .held)
        #expect(key(press(kVK_ANSI_B, "b", .control)) == .completed(.text("\u{2}")))
        #expect(sent.isEmpty)

        // A key that isn't part of it: the program gets the prefix after all, and the key is a key again.
        #expect(key(prefix) == .held)
        #expect(key(press(kVK_ANSI_X, "x")) == .unbound)
        #expect(sent.count == 1 && sent.first === prefix)
        #expect(pending.pressed.isEmpty)
        // …also one that's bound by itself.
        sent = []
        #expect(key(prefix) == .held)
        #expect(key(press(kVK_ANSI_T, "t", .command)) == .action(.newTab))
        #expect(sent.count == 1)
        // …and the prefix can start over right after.
        sent = []
        #expect(key(prefix) == .held)
        #expect(key(press(kVK_ANSI_X, "x")) == .unbound)
        #expect(key(prefix) == .held)
        #expect(key(press(kVK_ANSI_V, "v")) == .completed(.newSplit(.right)))
        #expect(sent.count == 1)

        // Another pane has the keyboard before the second key: nothing is sent, the key is its own.
        sent = []
        #expect(key(prefix) == .held)
        #expect(key(press(kVK_ANSI_V, "v"), in: other) == .unbound)
        #expect(sent.isEmpty && pending.pressed.isEmpty)
    }

    /// The pane a sequence is pressed in is told its keys as they're pressed,
    /// and none once it's over, however it ends.
    @Test @MainActor func thePaneShowsTheKeysUnderWay() {
        final class Pane: PendingKeysDisplay {
            var shown: [String] = []
            func showPendingKeys(_ keys: [Trigger]) { shown.append(keys.displayString) }
        }
        let table = Keybinds(entries: ["ctrl+b>v=new_split:right", "ctrl+b>w>x=new_tab"])
        let pane = Pane(), other = Pane()
        let pending = PendingKeys()
        func key(_ event: NSEvent, in owner: Pane? = nil) -> PendingKeys.Outcome {
            pending.press(event, in: owner ?? pane, keybinds: table) { _ in }
        }
        let prefix = press(kVK_ANSI_B, "b", .control)

        // Completed.
        _ = key(prefix)
        #expect(pane.shown == ["⌃B"])
        _ = key(press(kVK_ANSI_V, "v"))
        #expect(pane.shown == ["⌃B", ""])
        // Two keys in, then one that leads nowhere.
        pane.shown = []
        _ = key(prefix)
        _ = key(press(kVK_ANSI_W, "w"))
        #expect(pane.shown == ["⌃B", "⌃B W"])
        _ = key(press(kVK_ANSI_Q, "q"))
        #expect(pane.shown == ["⌃B", "⌃B W", ""])
        // The pane lost the keyboard; another pane's cancel leaves it be.
        pane.shown = []
        _ = key(prefix)
        pending.cancel(in: other)
        #expect(pane.shown == ["⌃B"] && pending.pressed.count == 1)
        pending.cancel(in: pane)
        #expect(pane.shown == ["⌃B", ""] && pending.pressed.isEmpty)
        // Another pane's key first: the first pane's tag goes, the other's never shows.
        pane.shown = []
        _ = key(prefix)
        _ = key(press(kVK_ANSI_X, "x"), in: other)
        #expect(pane.shown == ["⌃B", ""] && other.shown.isEmpty)
        // A key bound by itself, with nothing under way: no tag at all.
        pane.shown = []
        _ = key(press(kVK_ANSI_T, "t", .command))
        pending.reset()
        #expect(pane.shown.isEmpty)
    }
}
