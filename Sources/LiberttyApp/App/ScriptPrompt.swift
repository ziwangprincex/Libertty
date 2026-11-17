import Foundation

/// A question a script asks the person at the Mac (`libertty +pick`,
/// `+input`; Rex's script prompts): a choice from a list, or a line of
/// text. The command sends it to the running Libertty as `RemoteControl`
/// strings; the app asks it over the window of the pane the command runs
/// in, as a page of the command palette, and sends back the answer.
struct ScriptPrompt: Equatable {
    enum Kind: String { case pick, input }

    /// One choice: what's printed when it's picked, and what's shown beside it.
    struct Item: Equatable {
        var label: String
        var detail = ""
    }

    var kind: Kind
    var title = ""
    /// The field's words before anything's typed (`+input`).
    var placeholder = ""
    /// What the field starts with (`+input`).
    var value = ""
    /// The field shows dots (a password, a token).
    var secure = false
    /// Any number of the items may be chosen.
    var multiple = false
    /// Typed text may be the answer instead of an item.
    var allowOther = false
    /// Seconds before it gives up (124); nil: it waits.
    var timeout: Double?
    var items: [Item] = []

    /// How it ended, as the app tells the command.
    enum Answer: Equatable {
        /// The items picked, by their place in the list, in its order.
        case chosen([Int])
        /// Typed: `+input`'s answer, or `--allow-other`'s.
        case text(String)
        case cancelled
    }

    /// More than this many choices, or this many bytes of them, is a list
    /// for a file picker, not a prompt (the request travels as one message).
    static let maxItems = 5000, maxBytes = 512 * 1024

    // MARK: The command's arguments

    /// What's wrong with a command line, for its usage line.
    struct Problem: Error, Equatable {
        var message: String
    }

    static let pickUsage = "usage: libertty +pick [--title T] [--multiple | --allow-other] [--timeout S] ITEM... (or items on stdin, one a line, LABEL<TAB>DETAIL)"
    static let inputUsage = "usage: libertty +input [--title T] [--placeholder P] [--value V] [--secure] [--timeout S]"

    /// `args` as `kind`'s command reads them; with `+pick` and no ITEM,
    /// the items are `stdin`'s lines (nil: none to read; it's handed the
    /// prompt's timeout, as long as it may wait).
    static func parse(_ args: [String], kind: Kind, stdin: (Double?) -> String?) -> Result<ScriptPrompt, Problem> {
        let usage = kind == .pick ? pickUsage : inputUsage
        var prompt = ScriptPrompt(kind: kind)
        var words: [String] = []
        var i = 0
        var literal = false
        while i < args.count {
            let a = args[i], next = i + 1 < args.count ? args[i + 1] : nil
            if literal || !a.hasPrefix("-") || a == "-" {
                words.append(a)
                i += 1
                continue
            }
            switch (a, kind) {
            case ("--", _): literal = true
            case ("--title", _):
                guard let next else { return .failure(Problem(message: usage)) }
                prompt.title = next
                i += 1
            case ("--timeout", _):
                guard let next, let seconds = Double(next), seconds > 0, seconds.isFinite else {
                    return .failure(Problem(message: "--timeout is how many seconds to wait for an answer (more than 0)"))
                }
                prompt.timeout = seconds
                i += 1
            case ("--placeholder", .input):
                guard let next else { return .failure(Problem(message: usage)) }
                prompt.placeholder = next
                i += 1
            case ("--value", .input):
                guard let next else { return .failure(Problem(message: usage)) }
                prompt.value = next
                i += 1
            case ("--secure", .input): prompt.secure = true
            case ("--multiple", .pick): prompt.multiple = true
            case ("--allow-other", .pick): prompt.allowOther = true
            default: return .failure(Problem(message: usage))
            }
            i += 1
        }
        switch kind {
        case .input:
            guard words.isEmpty else { return .failure(Problem(message: usage)) }
            // A starting value travels in the request, which any process of
            // yours can hear: not for a secret.
            guard !(prompt.secure && !prompt.value.isEmpty) else {
                return .failure(Problem(message: "--value doesn't go with --secure: it would be sent in the open"))
            }
        case .pick:
            guard !(prompt.multiple && prompt.allowOther) else {
                return .failure(Problem(message: "--multiple and --allow-other don't go together: several items, or one answer of your own"))
            }
            prompt.items = words.isEmpty ? items(fromLines: stdin(prompt.timeout) ?? "") : words.map { Item(label: $0) }
            guard !prompt.items.isEmpty else {
                return .failure(Problem(message: "nothing to pick from: give the items as arguments, or one a line on stdin"))
            }
            guard prompt.items.count <= maxItems, prompt.encodedItems.utf8.count <= maxBytes else {
                return .failure(Problem(message: "too many items for a prompt (\(maxItems) at most)"))
            }
        }
        return .success(prompt)
    }

    /// One item a line, `LABEL<TAB>DETAIL` (the detail shown beside it,
    /// never printed). Blank lines and lines without a label don't count.
    static func items(fromLines text: String) -> [Item] {
        text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).compactMap { line in
            var line = String(line)
            if line.hasSuffix("\r") { line.removeLast() }
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let label = parts[0]
            guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return Item(label: label, detail: parts.count > 1 ? parts[1] : "")
        }
    }

    /// What's printed for an answer: the labels picked, a line each, or the
    /// text typed.
    func output(for answer: Answer) -> String? {
        switch answer {
        case .chosen(let picked): picked.filter(items.indices.contains).map { items[$0].label }.joined(separator: "\n")
        case .text(let text): text
        case .cancelled: nil
        }
    }

    // MARK: On the way (RemoteControl strings)

    private var encodedItems: String {
        let list = items.map { [$0.label, $0.detail] }
        guard let data = try? JSONSerialization.data(withJSONObject: list) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The request's fields (with `kind: prompt`; the command adds who's asking).
    var fields: [String: String] {
        var out = ["kind": "prompt", "prompt": kind.rawValue, "title": title, "placeholder": placeholder, "value": value,
                   "secure": secure ? "1" : "0", "multiple": multiple ? "1" : "0", "allowOther": allowOther ? "1" : "0",
                   "items": encodedItems]
        if let timeout { out["timeout"] = String(timeout) }
        return out
    }

    /// A request's prompt, if it's one this Libertty can ask.
    init?(fields: [String: String]) {
        guard fields["kind"] == "prompt", let kind = fields["prompt"].flatMap(Kind.init(rawValue:)) else { return nil }
        self.kind = kind
        title = fields["title"] ?? ""
        placeholder = fields["placeholder"] ?? ""
        value = fields["value"] ?? ""
        secure = fields["secure"] == "1"
        multiple = fields["multiple"] == "1"
        allowOther = fields["allowOther"] == "1"
        timeout = fields["timeout"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
        let list = (fields["items"]?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String]] } ?? []
        items = list.compactMap { pair in pair.first.map { Item(label: $0, detail: pair.count > 1 ? pair[1] : "") } }
        if kind == .pick, items.isEmpty { return nil }
    }

    init(kind: Kind) { self.kind = kind }

    /// A `--secure` answer into the command's own file: one that's there
    /// already, a plain file of this user's (never a link), emptied first.
    static func writeAnswer(_ text: String, to path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, ftruncate(fd, 0) == 0 else { return false }
        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            written += n
        }
        return true
    }

    /// An answer as the app sends it.
    static func reply(_ answer: Answer) -> [String: String] {
        switch answer {
        case .chosen(let picked): ["result": "answered", "chosen": picked.map(String.init).joined(separator: ",")]
        case .text(let text): ["result": "answered", "text": text]
        case .cancelled: ["result": "cancelled"]
        }
    }

    /// The answer in a reply that has one.
    static func answer(in reply: [String: String]) -> Answer? {
        switch reply["result"] {
        case "answered":
            if let text = reply["text"] { return .text(text) }
            let chosen = reply["chosen"] ?? ""
            return .chosen(chosen.isEmpty ? [] : chosen.split(separator: ",").compactMap { Int($0) })
        case "cancelled": return .cancelled
        default: return nil
        }
    }
}
