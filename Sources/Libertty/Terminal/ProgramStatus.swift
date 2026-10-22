import Foundation

/// Program status records (OSC 7501), kept exactly as the specification asks.
/// See `GhosttyTerminalProgramStatusFn` in vendor/ghostty/include/ghostty/vt/terminal.h
/// and https://www.superlogical.com/rex/docs/build/program-status.
///
/// libghostty-vt validates and decodes reports; this store owns the records.
/// Main thread only.
final class ProgramStatusStore {
    enum State: Int, Comparable, CaseIterable {
        case idle, done, working, error, blocked

        /// What a tab shows when several records disagree: the one that most
        /// needs the user wins.
        static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }

        /// The specification's names, in the order settings list them.
        static let named: [(name: String, state: State)] = [
            ("idle", .idle), ("working", .working), ("blocked", .blocked), ("done", .done), ("error", .error),
        ]
        var name: String { Self.named.first { $0.state == self }!.name }
        /// A state by its name; "waiting" and "failed" are what the interface calls two of them.
        init?(name: String) {
            switch name.lowercased() {
            case "waiting": self = .blocked
            case "failed": self = .error
            case let other:
                guard let state = Self.named.first(where: { $0.name == other })?.state else { return nil }
                self = state
            }
        }
    }

    enum Kind { case none, permission, question, auth }

    struct Report {
        var clear: Bool
        var state: State
        var kind: Kind
        /// 0...100, or nil when indeterminate.
        var progress: Int?
        var id: String
        var app: String
        var title: String
        var message: String
    }

    struct Record {
        var id: String
        var state: State
        var kind: Kind
        var progress: Int?
        /// As reported; empty means "inherit from the nearest ancestor".
        var app: String
        var title: String
        var message: String
        fileprivate var stamp: UInt64
    }

    /// The spec asks for at most 256 records and at least 64.
    static let limit = 256

    private(set) var records: [String: Record] = [:]
    private var clock: UInt64 = 0

    var onChange: (() -> Void)?

    func apply(_ report: Report) {
        if report.clear {
            clear(id: report.id)
            return
        }
        clock += 1
        // A report replaces its record completely: no field survives from before.
        records[report.id] = Record(
            id: report.id, state: report.state, kind: report.kind, progress: report.progress,
            app: Self.sanitize(report.app), title: Self.sanitize(report.title),
            message: Self.sanitize(report.message), stamp: clock)
        evictOverLimit()
        onChange?()
    }

    /// Removes `id` and every record beneath it ("build" also removes "build/test").
    /// An empty id removes every record.
    func clear(id: String) {
        let before = records.count
        if id.isEmpty {
            records.removeAll()
        } else {
            records = records.filter { key, _ in key != id && !key.hasPrefix(id + "/") }
        }
        if records.count != before { onChange?() }
    }

    /// A new shell prompt started or the program exited: `working` and
    /// `blocked` records are no longer true. `idle` goes too; `done` and
    /// `error` stay until the user has seen them.
    func programFinished() {
        let before = records.count
        records = records.filter { _, r in r.state == .done || r.state == .error }
        if records.count != before { onChange?() }
    }

    /// The user looked at the terminal (focused it): finished outcomes are seen.
    func markSeen() {
        let before = records.count
        records = records.filter { _, r in r.state != .done && r.state != .error }
        if records.count != before { onChange?() }
    }

    /// Not a report: Libertty sees the program read a password (its terminal
    /// takes a line without echoing it). Beside the records, not one of them:
    /// what programs report, clear or evict leaves it alone, and it lasts as
    /// long as the terminal reads that way. It shows like a blocked record
    /// (`headline`), under an id no program can send (`~` isn't allowed in one).
    private(set) var readingSecret = false
    private var secretStamp: UInt64 = 0
    static let secretInputID = "~password"

    /// Whether anything changed.
    @discardableResult
    func setReadingSecret(_ reading: Bool) -> Bool {
        guard reading != readingSecret else { return false }
        readingSecret = reading
        if reading {
            clock += 1
            secretStamp = clock
        }
        onChange?()
        return true
    }

    /// The records, with the password one when it stands.
    private var shown: [Record] {
        let all = Array(records.values)
        guard readingSecret else { return all }
        return all + [Record(id: Self.secretInputID, state: .blocked, kind: .auth, progress: nil,
                             app: "", title: "", message: "Waiting for a password", stamp: secretStamp)]
    }

    func reset() {
        guard !records.isEmpty else { return }
        records.removeAll()
        onChange?()
    }

    /// A record without an app takes it from its nearest ancestor that has one.
    func effectiveApp(of record: Record) -> String {
        if !record.app.isEmpty || record.id == Self.secretInputID { return record.app }
        var id = record.id
        while !id.isEmpty {
            id = id.contains("/") ? String(id[..<id.lastIndex(of: "/")!]) : ""
            if let parent = records[id], !parent.app.isEmpty { return parent.app }
        }
        return ""
    }

    /// The record a tab or pane icon should reflect, if any.
    var headline: Record? { headline(among: nil) }

    /// The most urgent record whose state is one of `states` (nil: any) — what
    /// a tab shows, a notification says or the Dock counts, each following
    /// the states its setting names.
    func headline(among states: Set<State>?) -> Record? {
        shown.filter { states?.contains($0.state) ?? true }.max { a, b in
            a.state != b.state ? a.state < b.state : a.stamp < b.stamp
        }
    }

    private func evictOverLimit() {
        while records.count > Self.limit,
              let oldest = records.values.min(by: { $0.stamp < $1.stamp }) {
            records[oldest.id] = nil
        }
    }

    /// Program text is untrusted: drop control and invisible formatting
    /// characters (direction overrides, zero-width joiners used to spoof, ...)
    /// before it is shown in chrome outside the terminal grid.
    static func sanitize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: false
            default: true
            }
        }))
    }
}
