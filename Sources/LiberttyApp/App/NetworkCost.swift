import Foundation
import Network

/// Whether the network costs the user something: Low Data Mode, or an
/// expensive link (a phone's hotspot, cellular). What a background update
/// download waits out; anything the user asks for goes ahead regardless.
final class NetworkCost: @unchecked Sendable {
    enum Kind: String, Equatable, Sendable {
        case free
        /// Low Data Mode is on for this network.
        case lowData = "low-data"
        /// A phone's hotspot, or another link macOS marks as expensive.
        case hotspot
    }

    static let shared = NetworkCost()
    /// Posted on the main thread when `current` changes.
    static let changed = Notification.Name("LiberttyNetworkCostChanged")

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var kind = Kind.free
    /// `$LIBERTTY_NETWORK_COST` (tests): low-data, hotspot or free, whatever the network says.
    private let forced = ProcessInfo.processInfo.environment["LIBERTTY_NETWORK_COST"].flatMap(Kind.init(rawValue:))

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let now = Self.kind(constrained: path.isConstrained, expensive: path.isExpensive)
            let changed = self.lock.withLock { () -> Bool in
                defer { self.kind = now }
                return self.kind != now
            }
            if changed, self.forced == nil {
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.libertty.network-cost"))
    }

    /// What the network costs now (any thread).
    var current: Kind { forced ?? lock.withLock { kind } }

    /// Low Data Mode first: it's the user's own say, a hotspot only macOS's guess.
    static func kind(constrained: Bool, expensive: Bool) -> Kind {
        constrained ? .lowData : expensive ? .hotspot : .free
    }
}
