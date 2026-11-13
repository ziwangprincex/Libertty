import AppKit

/// AppleScript (Rex's sdef; Resources/Libertty.sdef): windows, tabs and
/// sessions to read, and commands to make windows, tabs and splits, type
/// into a session, run Libertty's actions and focus a pane — through what
/// the CLI and the menus use. Cocoa scripting calls in on the main thread.
enum Scripting {
    /// The app's windows and how to open one: the app delegate's, or a
    /// probe's own (which has no app delegate).
    struct Host {
        var controllers: () -> [TerminalWindowController]
        var openWindow: (_ command: String?, _ directory: String?) -> TerminalWindowController?
    }

    static var host: Host?

    /// Whether a script may do this (reading never needs asking): what
    /// `remote-control` says, as for the command line's commands that drive Libertty.
    static func allowed(_ command: NSScriptCommand) -> Bool { ConfigStore.shared.config.remoteControl }

    static var controllers: [TerminalWindowController] { host?.controllers() ?? [] }

    /// The pane showing session `id`, and its window.
    static func find(_ id: String) -> (TerminalWindowController, TerminalView)? {
        for c in controllers { if let pane = c.pane(showing: id) { return (c, pane) } }
        return nil
    }

    /// The session a command names, else the focused one of the window in front.
    static func pane(_ session: Any?) -> (TerminalWindowController, TerminalView)? {
        if let session = session as? ScriptSession { return find(session.uniqueID) }
        guard let front = controllers.first else { return nil }
        let pane = front.focusedTerminal
        return (front, pane)
    }
}

// MARK: - Objects

@objc(LiberttyScriptWindow)
final class ScriptWindow: NSObject {
    let controller: TerminalWindowController
    init(_ controller: TerminalWindowController) { self.controller = controller }

    @objc var uniqueID: String { "\(controller.window?.windowNumber ?? 0)" }
    @objc var name: String { controller.window?.title ?? "" }
    @objc var host: String { controller.host?.destination ?? "" }
    @objc var tabs: [ScriptTab] { controller.tabs.map { ScriptTab($0, in: controller) } }
    @objc var sessions: [ScriptSession] { controller.tabs.flatMap(\.everyPane).map { ScriptSession($0, in: controller) } }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let app = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: app,
                                   containerSpecifier: nil, key: "scriptWindows", uniqueID: uniqueID)
    }
}

@objc(LiberttyScriptTab)
final class ScriptTab: NSObject {
    let tab: TerminalTab
    let controller: TerminalWindowController
    init(_ tab: TerminalTab, in controller: TerminalWindowController) {
        self.tab = tab
        self.controller = controller
    }

    @objc var uniqueID: String { "\(UInt(bitPattern: ObjectIdentifier(tab).hashValue))" }
    @objc var name: String { MainActor.assumeIsolated { controller.rowLabel(of: tab).name } }
    @objc var selected: Bool { controller.selectedTab === tab }
    @objc var sessions: [ScriptSession] { tab.everyPane.map { ScriptSession($0, in: controller) } }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let window = ScriptWindow(controller).objectSpecifier,
              let description = window.keyClassDescription else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: window,
                                   key: "tabs", uniqueID: uniqueID)
    }
}

@objc(LiberttyScriptSession)
final class ScriptSession: NSObject {
    let pane: TerminalView
    let controller: TerminalWindowController
    init(_ pane: TerminalView, in controller: TerminalWindowController) {
        self.pane = pane
        self.controller = controller
    }

    @objc var uniqueID: String { pane.paneID }
    @objc var name: String { MainActor.assumeIsolated { controller.headerInfo(for: pane).name } }
    @objc var program: String { name }
    @objc var workingDirectory: String { pane.session.workingDirectory ?? "" }
    @objc var status: String {
        pane.session.programStatus.headline(among: nil)?.state.name ?? ProgramStatusStore.State.idle.name
    }
    @objc var host: String { controller.host?.destination ?? "" }
    @objc var focused: Bool { controller.focusedTerminal === pane }
    @objc var contents: String { pane.session.screenRows() }

    // A command whose direct parameter is a session comes here (the sdef's responds-to).
    @objc func scriptSplit(_ command: NSScriptCommand) -> Any? { command.performDefaultImplementation() }
    @objc func scriptFocus(_ command: NSScriptCommand) -> Any? { command.performDefaultImplementation() }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let app = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: app,
                                   containerSpecifier: nil, key: "scriptSessions", uniqueID: uniqueID)
    }
}

extension NSApplication {
    @objc var scriptWindows: [ScriptWindow] { Scripting.controllers.map(ScriptWindow.init) }
    @objc var scriptSessions: [ScriptSession] {
        Scripting.controllers.flatMap { c in c.allPanes.map { ScriptSession($0, in: c) } }
    }

    @objc func valueInScriptWindowsWithUniqueID(_ id: String) -> ScriptWindow? { scriptWindows.first { $0.uniqueID == id } }
    @objc func valueInScriptSessionsWithUniqueID(_ id: String) -> ScriptSession? {
        Scripting.find(id).map { ScriptSession($0.1, in: $0.0) }
    }
}

// MARK: - Commands

/// A command's shared parts: its permission, and how it fails.
class ScriptCommand: NSScriptCommand {
    final override func performDefaultImplementation() -> Any? {
        guard Scripting.allowed(self) else { return fail(L10n.t("Libertty doesn't take this from scripts."), -10_004) }
        return MainActor.assumeIsolated { perform(evaluatedArguments ?? [:]) }
    }

    func perform(_ arguments: [String: Any]) -> Any? { nil }

    func fail(_ message: String, _ number: Int = -2700) -> Any? {
        scriptErrorNumber = number
        scriptErrorString = message
        return nil
    }

    func string(_ arguments: [String: Any], _ key: String) -> String? {
        (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A session given as the direct parameter (Cocoa makes it the command's receiver).
    var receiver: Any? {
        let given = evaluatedReceivers ?? directParameter
        return (given as? [Any])?.first ?? given
    }
}

@objc(LiberttyNewWindowCommand)
final class ScriptNewWindowCommand: ScriptCommand {
    override func perform(_ arguments: [String: Any]) -> Any? {
        guard let controller = Scripting.host?.openWindow(string(arguments, "command"), string(arguments, "directory"))
        else { return fail(L10n.t("Couldn't open a window.")) }
        return ScriptSession(controller.focusedTerminal, in: controller)
    }
}

@objc(LiberttyNewTabCommand)
final class ScriptNewTabCommand: ScriptCommand {
    override func perform(_ arguments: [String: Any]) -> Any? {
        guard let controller = (arguments["window"] as? ScriptWindow)?.controller ?? Scripting.controllers.first else {
            return fail(L10n.t("No window to open a tab in."), -1728)
        }
        guard let pane = controller.newTab(command: string(arguments, "command"), workingDirectory: string(arguments, "directory"))?
            .focusedPane else { return fail(L10n.t("Couldn't open a tab.")) }
        return ScriptSession(pane, in: controller)
    }
}

@objc(LiberttySplitCommand)
final class ScriptSplitCommand: ScriptCommand {
    override func perform(_ arguments: [String: Any]) -> Any? {
        guard let (controller, pane) = Scripting.pane(receiver) else {
            return fail(L10n.t("No such session."), -1728)
        }
        let direction: SplitContainerView.Direction
        switch (arguments["direction"] as? NSNumber)?.uint32Value {
        case FourCharCode("LSlf"): direction = .left
        case FourCharCode("LSdn"): direction = .down
        case FourCharCode("LSup"): direction = .up
        default: direction = .right
        }
        if controller.isOutOfSplit(pane) { return fail(L10n.t("It's parked (unpark it first).")) }
        do {
            guard let new = try controller.makeSplit(beside: pane, toward: direction, command: string(arguments, "command"),
                                                     workingDirectory: string(arguments, "directory"))
            else { return fail(L10n.t("No such session."), -1728) }
            return ScriptSession(new, in: controller)
        } catch {
            return fail(error.localizedDescription)
        }
    }
}

@objc(LiberttyInputCommand)
class ScriptInputCommand: ScriptCommand {
    var addsReturn: Bool { false }

    override func perform(_ arguments: [String: Any]) -> Any? {
        guard let text = directParameter as? String else { return fail(L10n.t("Say what to type.")) }
        guard let (_, pane) = Scripting.pane(arguments["session"]) else { return fail(L10n.t("No such session."), -1728) }
        if pane.isReadOnly { return fail(L10n.t("That pane is read-only.")) }
        pane.sendInput(addsReturn ? text + "\r" : text)
        return nil
    }
}

@objc(LiberttyRunCommand)
final class ScriptRunCommand: ScriptInputCommand {
    override var addsReturn: Bool { true }
}

@objc(LiberttyPerformActionCommand)
final class ScriptPerformActionCommand: ScriptCommand {
    override func perform(_ arguments: [String: Any]) -> Any? {
        guard let name = directParameter as? String, let action = Action(name) else {
            return fail(L10n.t("No such action (libertty +list-actions lists them)."))
        }
        let target = Scripting.pane(arguments["session"])
        if arguments["session"] != nil, target == nil { return fail(L10n.t("No such session."), -1728) }
        return ActionDispatcher.perform(action, in: target?.1, controller: target?.0)
    }
}

@objc(LiberttyFocusCommand)
final class ScriptFocusCommand: ScriptCommand {
    override func perform(_ arguments: [String: Any]) -> Any? {
        guard let session = receiver as? ScriptSession, let (controller, _) = Scripting.find(session.uniqueID),
              controller.reveal(paneID: session.uniqueID) else { return fail(L10n.t("No such session."), -1728) }
        if controller.isQuick { QuickTerminal.shared.show() } else { controller.window?.makeKeyAndOrderFront(nil) }
        Probe.activateApp()
        return nil
    }
}

private extension FourCharCode {
    init(_ code: String) {
        self = code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
