import AppKit
import UserNotifications

/// Banners for what happens in panes you're not looking at: notifications
/// programs ask for (OSC 9/777), long commands finishing, agents (OSC 7501)
/// that need you. Clicking one brings its pane forward.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Bring the pane with this id forward (set by the app delegate).
    var onActivate: ((String) -> Void)?

    /// UserNotifications needs a real app bundle; `swift run` builds have none.
    private let available = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    private var authorization: Bool?
    private var pending: [UNNotificationRequest] = []
    /// The same text from the same pane within a moment is one notification
    /// (a session shown in two windows reports it twice).
    private var recent: [String: Date] = [:]

    private override init() {
        super.init()
        if available { UNUserNotificationCenter.current().delegate = self }
    }

    /// What was notified, newest first (the toolbar's inbox).
    struct Entry {
        var title: String
        var body: String
        var pane: String
        var date: Date
    }
    private(set) var inbox: [Entry] = []
    /// Entries the inbox hasn't shown yet.
    private(set) var unread = 0
    static let inboxChanged = Notification.Name("LiberttyInboxChanged")

    func markInboxRead() {
        guard unread > 0 else { return }
        unread = 0
        NotificationCenter.default.post(name: Self.inboxChanged, object: nil)
    }

    func clearInbox() {
        inbox = []
        unread = 0
        NotificationCenter.default.post(name: Self.inboxChanged, object: nil)
    }

    /// `sound`: false when the caller plays a sound of its own for it.
    func post(title: String, body: String, pane: String, sound: Bool = true) {
        let key = pane + "\u{1}" + title + "\u{1}" + body
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 2 }
        guard recent[key] == nil else { return }
        recent[key] = now
        inbox.insert(Entry(title: title.isEmpty ? "Libertty" : title, body: body, pane: pane, date: now), at: 0)
        if inbox.count > 100 { inbox.removeLast(inbox.count - 100) }
        unread += 1
        NotificationCenter.default.post(name: Self.inboxChanged, object: nil)
        guard available else { return }

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Libertty" : title
        content.body = body
        content.sound = sound ? .default : nil
        content.userInfo = ["pane": pane]
        content.threadIdentifier = pane
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        switch authorization {
        case true?: UNUserNotificationCenter.current().add(request)
        case false?: break
        case nil:
            // Ask once, the first time something wants to notify.
            pending.append(request)
            guard pending.count == 1 else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                DispatchQueue.main.async {
                    self.authorization = granted
                    if granted { self.pending.forEach { UNUserNotificationCenter.current().add($0) } }
                    self.pending = []
                }
            }
        }
    }

    /// Notifications about a pane go once it's been looked at.
    func clear(pane: String) {
        // (Not only once this run has asked to notify: a banner from before
        // a relaunch names the same pane, and taking one away needs no permission.)
        guard available, authorization != false else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { $0.request.content.userInfo["pane"] as? String == pane }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Libertty in front but the pane elsewhere (another tab or window): still show it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let pane = response.notification.request.content.userInfo["pane"] as? String {
            DispatchQueue.main.async { self.onActivate?(pane) }
        }
        completionHandler()
    }

    /// "2m 13s", "45s", "1h 2m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

/// A program state's sound (`program-status-sound`): one of macOS's, by
/// name, or "" for the alert sound. Under a probe it's only noted: tests
/// make no noise.
enum StatusSound {
    private(set) static var played: [String] = []
    /// A session shown in two windows reports to each: one sound.
    private static var recent: [String: Date] = [:]

    static func play(_ name: String, for pane: String) {
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 2 }
        let key = pane + "\u{1}" + name
        guard recent[key] == nil else { return }
        recent[key] = now
        if Probe.running { return played.append(name.isEmpty ? "alert" : name) }
        if name.isEmpty { NSSound.beep() } else { NSSound(named: NSSound.Name(name))?.play() }
    }
}
