import Foundation

/// `libertty +events`: what happens in liberttyd's sessions as it happens,
/// one JSON object per event, to every connection that asked (Tern's
/// `tern events`): sessions starting and ending, commands starting and
/// finishing, the shell back at its prompt, titles, directories, bells.
///
/// Nothing waits on a listener: each has its own queue, and one that falls
/// too far behind (it stopped reading) is let go — it can ask again.
final class DaemonEvents {
    static let shared = DaemonEvents()

    private let lock = NSLock()
    private var listeners: [Listener] = []

    final class Listener {
        let connection: Connection
        /// The kinds it asked for; nil: every kind.
        let kinds: Set<String>?
        private let queue = DispatchQueue(label: "liberttyd.events", qos: .utility)
        private let lock = NSLock()
        private var pending = 0
        private var gone = false
        /// Events queued and not yet written, past which it's let go.
        static let maxPending = 4096

        init(connection: Connection, kinds: Set<String>?) {
            self.connection = connection
            self.kinds = kinds
        }

        func wants(_ kind: String) -> Bool { kinds?.contains(kind) ?? true }

        /// Queue `frame`; false when it's gone or too far behind.
        func send(_ frame: Data) -> Bool {
            lock.lock()
            guard !gone, pending < Self.maxPending else {
                gone = true
                lock.unlock()
                return false
            }
            pending += 1
            lock.unlock()
            queue.async { [self] in
                let sent = connection.send(.event, frame)
                lock.withLock {
                    pending -= 1
                    if !sent { gone = true }
                }
            }
            return true
        }
    }

    func listen(_ connection: Connection, kinds: Set<String>?) -> Listener {
        let listener = Listener(connection: connection, kinds: kinds)
        lock.withLock { listeners.append(listener) }
        return listener
    }

    func stop(_ listener: Listener) {
        lock.withLock { listeners.removeAll { $0 === listener } }
    }

    /// Tell everyone listening for `kind`. Cheap when nobody is.
    func publish(_ kind: String, session id: String, _ fields: [String: Any] = [:]) {
        let interested = lock.withLock { listeners.filter { $0.wants(kind) } }
        guard !interested.isEmpty else { return }
        var event = fields
        event["event"] = kind
        event["id"] = id
        event["time"] = Date().timeIntervalSince1970
        guard let frame = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        let behind = interested.filter { !$0.send(frame) }
        guard !behind.isEmpty else { return }
        lock.withLock { listeners.removeAll { l in behind.contains { $0 === l } } }
        // Its connection's thread sees the hang-up and ends.
        behind.forEach { $0.connection.close() }
    }
}
