import AppKit
import SQLite3

/// The SQLite block (Tern's database browser): a database file's tables
/// and views, their rows a page at a time, their structure, and a query box.
/// It opens read-only; "Allow Changes" reopens it for writing (cells can
/// then be edited, and statements that change things run). Through the
/// system's libsqlite3, on one queue of its own.
final class SQLiteBlock: BlockService {
    static let symbol = "cylinder.split.1x2"
    weak var host: BlockHost?
    let file: URL
    private var db: OpaquePointer?
    private var writable = false
    private let queue = DispatchQueue(label: "dev.libertty.sqlite")
    /// The handle a running statement uses, for Stop (read from the main thread).
    private let dbLock = NSLock()
    private var running: OpaquePointer?

    static let pageSize = 200
    static let resultLimit = 1000

    init?(url: URL) {
        guard let path = Blocks.parameter("file", of: url), path.hasPrefix("/") else { return nil }
        file = URL(fileURLWithPath: path).standardizedFileURL
    }

    var title: String { file.lastPathComponent }

    /// A file that is a database: its first 16 bytes say so.
    static func isDatabase(_ url: URL) -> Bool {
        guard ["sqlite", "sqlite3", "db", "db3", "sqlitedb"].contains(url.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16)) == Data("SQLite format 3\0".utf8)
    }

    func handle(_ method: String, _ params: [String: Any], reply: @escaping (Result<Any, BlockError>) -> Void) {
        if method == "stop" {
            dbLock.lock()
            if let running { sqlite3_interrupt(running) }
            dbLock.unlock()
            return reply(.success(true))
        }
        if method == "reveal" {
            NSWorkspace.shared.activateFileViewerSelecting([file])
            return reply(.success(true))
        }
        queue.async {
            do { reply(.success(try self.run(method, params))) } catch let error as BlockError { reply(.failure(error)) } catch {
                reply(.failure(BlockError(error.localizedDescription)))
            }
        }
    }

    // MARK: On the queue

    private func run(_ method: String, _ params: [String: Any]) throws -> Any {
        switch method {
        case "open":
            let write = params["write"] as? Bool ?? false
            try open(write: write)
            return ["name": file.lastPathComponent, "path": file.path, "writable": writable,
                    "canWrite": FileManager.default.isWritableFile(atPath: file.path), "objects": try objects()]
        case "objects": return try objects()
        case "rows":
            guard let name = params["name"] as? String else { throw BlockError("which table?") }
            let page = max(0, params["page"] as? Int ?? 0)
            let sort = params["sort"] as? String
            let descending = params["desc"] as? Bool ?? false
            return try rows(of: name, page: page, sort: sort, descending: descending)
        case "structure":
            guard let name = params["name"] as? String else { throw BlockError("which table?") }
            return try structure(of: name)
        case "query":
            guard let sql = params["sql"] as? String, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BlockError("Nothing to run.")
            }
            return try query(sql)
        case "update":
            guard writable else { throw BlockError("The database is open read-only: Allow Changes first.") }
            guard let name = params["name"] as? String, let column = params["column"] as? String,
                  let rowid = (params["rowid"] as? Int64) ?? (params["rowid"] as? Int).map(Int64.init) else {
                throw BlockError("which cell?")
            }
            // A number typed stays a number (an untyped column would keep "42" as text).
            var value: Any? = params["value"]
            if params["null"] as? Bool != true, let text = value as? String, !text.isEmpty {
                if let n = Int64(text) { value = n } else if let d = Double(text), text.range(of: #"^-?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$"#, options: .regularExpression) != nil { value = d }
            }
            try update(name, column: column, rowid: rowid, value: value, null: params["null"] as? Bool ?? false)
            return true
        default:
            throw BlockError("unknown call \(method)")
        }
    }

    private func open(write: Bool) throws {
        if db != nil, write == writable { return }
        closeDatabase()
        var handle: OpaquePointer?
        // A URI, so the read-only open is truly that (no journal made).
        var parts = URLComponents()
        parts.scheme = "file"
        parts.path = file.path
        parts.queryItems = [URLQueryItem(name: "mode", value: write ? "rw" : "ro")]
        let flags = (write ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(parts.string ?? file.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let why = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open it"
            sqlite3_close(handle)
            throw BlockError("Couldn't open \(file.lastPathComponent): \(why)")
        }
        sqlite3_busy_timeout(handle, 3000)
        db = handle
        writable = write
    }

    private func closeDatabase() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    private func connection() throws -> OpaquePointer {
        if db == nil { try open(write: false) }
        guard let db else { throw BlockError("not open") }
        return db
    }

    /// An identifier, quoted as SQLite reads it.
    static func quoted(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    /// Every statement of `sql`, each stepped to its end; the last one that
    /// returns rows gives the result (cut at `limit`).
    private func execute(_ sql: String, bind: [Any?] = [], limit: Int = resultLimit) throws -> (columns: [String], types: [String], rows: [[Any]], changes: Int, truncated: Bool) {
        let db = try connection()
        dbLock.lock(); running = db; dbLock.unlock()
        defer { dbLock.lock(); running = nil; dbLock.unlock() }
        var result: (columns: [String], types: [String], rows: [[Any]], changes: Int, truncated: Bool) = ([], [], [], 0, false)
        let before = sqlite3_total_changes(db)
        var rest = sql
        while !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var statement: OpaquePointer?
            var tail: UnsafePointer<CChar>?
            let code = rest.withCString { sqlite3_prepare_v2(db, $0, -1, &statement, &tail) == SQLITE_OK ? (tail.map { String(cString: $0) } ?? "") : nil }
            guard let remaining = code else { throw BlockError(String(cString: sqlite3_errmsg(db))) }
            rest = remaining
            guard let statement else { continue }  // a comment, or only whitespace
            defer { sqlite3_finalize(statement) }
            if !writable, sqlite3_stmt_readonly(statement) == 0 {
                throw BlockError("That statement changes the database, which is open read-only: Allow Changes first.")
            }
            for (i, value) in bind.enumerated() { Self.bind(value, to: statement, at: Int32(i + 1)) }
            let count = sqlite3_column_count(statement)
            var columns: [String] = [], types: [String] = [], rows: [[Any]] = []
            for c in 0..<count {
                columns.append(String(cString: sqlite3_column_name(statement, c)))
                types.append(sqlite3_column_decltype(statement, c).map { String(cString: $0) } ?? "")
            }
            var truncated = false
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    throw BlockError(step == SQLITE_INTERRUPT ? "Stopped." : String(cString: sqlite3_errmsg(db)))
                }
                if rows.count >= limit { truncated = true; break }
                rows.append((0..<count).map { Self.value(statement, $0) })
            }
            if count > 0 { result = (columns, types, rows, 0, truncated) }
        }
        result.changes = Int(sqlite3_total_changes(db) - before)
        // A batch that began a transaction and didn't end it: a read-only
        // one holds a lock on the file (its owner's writes wait), and a
        // writable one would be rolled back when the connection closed.
        if sqlite3_get_autocommit(db) == 0 {
            if writable { _ = sqlite3_exec(db, "COMMIT", nil, nil, nil) }
            else { _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        }
        return result
    }

    private static func bind(_ value: Any?, to statement: OpaquePointer, at i: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        switch value {
        case nil, is NSNull: sqlite3_bind_null(statement, i)
        case let n as Int: sqlite3_bind_int64(statement, i, Int64(n))
        case let n as Int64: sqlite3_bind_int64(statement, i, n)
        case let d as Double: sqlite3_bind_double(statement, i, d)
        case let s as String: sqlite3_bind_text(statement, i, s, -1, transient)
        default: sqlite3_bind_text(statement, i, String(describing: value!), -1, transient)
        }
    }

    /// A cell for the page: a number, text, null, or a blob's size and first bytes.
    private static func value(_ statement: OpaquePointer, _ c: Int32) -> Any {
        switch sqlite3_column_type(statement, c) {
        case SQLITE_INTEGER:
            let n = sqlite3_column_int64(statement, c)
            // Past what a JavaScript number holds exactly: as text (magnitude: abs(Int64.min) traps).
            return n.magnitude < (1 << 53) ? NSNumber(value: n) : String(n)
        case SQLITE_FLOAT: return sqlite3_column_double(statement, c)
        case SQLITE_NULL: return NSNull()
        case SQLITE_BLOB:
            let size = Int(sqlite3_column_bytes(statement, c))
            let bytes = sqlite3_column_blob(statement, c).map { Data(bytes: $0, count: min(size, 16)) } ?? Data()
            return ["blob": size, "head": bytes.map { String(format: "%02x", $0) }.joined(separator: " ")]
        default:
            // By its length, not up to a NUL: text may hold one, or bytes that aren't UTF-8.
            let size = Int(sqlite3_column_bytes(statement, c))
            guard size > 0, let text = sqlite3_column_text(statement, c) else { return "" }
            let bytes = Data(bytes: text, count: size)
            guard size <= 10_000 else {
                // A huge text cell (a JSON dump) is cut for the grid, and can't be edited here.
                return ["text": String(decoding: bytes.prefix(10_000), as: UTF8.self) + "…", "cut": size] as [String: Any]
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private func objects() throws -> [[String: Any]] {
        let list = try execute("SELECT name, type, sql FROM sqlite_schema WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name COLLATE NOCASE")
        return list.rows.map { row in
            let name = row[0] as? String ?? "", type = row[1] as? String ?? ""
            // Counting a huge table is slow: tables only, and only up to a point.
            var count: Any = NSNull()
            if type == "table", let n = try? execute("SELECT count(*) FROM (SELECT 1 FROM \(Self.quoted(name)) LIMIT 100001)").rows.first?.first {
                count = n
            }
            return ["name": name, "type": type, "count": count, "withoutRowid": (row[2] as? String ?? "").uppercased().contains("WITHOUT ROWID")]
        }
    }

    private func rows(of name: String, page: Int, sort: String?, descending: Bool) throws -> [String: Any] {
        let info = try execute("SELECT type, sql FROM sqlite_schema WHERE name = ?", bind: [name])
        guard let type = info.rows.first?.first as? String else { throw BlockError("There's no table \(name).") }
        var hasRowid = type == "table" && !((info.rows.first?[1] as? String ?? "").uppercased().contains("WITHOUT ROWID"))
        // A real column named rowid (oid, _rowid_) is what `rowid` means then.
        if hasRowid {
            let names = try execute("SELECT name FROM pragma_table_info(?)", bind: [name]).rows.compactMap { $0.first as? String }
            if names.contains(where: { ["rowid", "oid", "_rowid_"].contains($0.lowercased()) }) { hasRowid = false }
        }
        var sql = "SELECT " + (hasRowid ? "rowid AS \"__rowid\", " : "") + "* FROM \(Self.quoted(name))"
        if let sort, !sort.isEmpty { sql += " ORDER BY \(Self.quoted(sort))" + (descending ? " DESC" : "") }
        sql += " LIMIT \(Self.pageSize + 1) OFFSET \(page * Self.pageSize)"
        let result = try execute(sql, limit: Self.pageSize + 1)
        var rows = result.rows, columns = result.columns, types = result.types
        let more = rows.count > Self.pageSize
        if more { rows.removeLast() }
        var rowids: [Any] = []
        if hasRowid {
            rowids = rows.map { $0[0] }
            rows = rows.map { Array($0.dropFirst()) }
            columns.removeFirst()
            types.removeFirst()
        }
        return ["columns": columns, "types": types, "rows": rows, "rowids": rowids, "page": page, "more": more,
                "editable": hasRowid && writable, "kind": type]
    }

    private func structure(of name: String) throws -> [String: Any] {
        let sql = try execute("SELECT sql FROM sqlite_schema WHERE name = ?", bind: [name]).rows.first?.first as? String ?? ""
        let columns = try execute("SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info(?)", bind: [name]).rows.map { r in
            ["name": r[0], "type": r[1], "notNull": (r[2] as? NSNumber)?.boolValue ?? false, "default": r[3], "primaryKey": (r[4] as? NSNumber)?.intValue ?? 0]
        }
        let indexes = try execute("SELECT name, sql FROM sqlite_schema WHERE type = 'index' AND tbl_name = ? ORDER BY name", bind: [name]).rows.map { r in
            ["name": r[0], "sql": r[1]]
        }
        return ["sql": sql, "columns": columns, "indexes": indexes]
    }

    private func query(_ sql: String) throws -> [String: Any] {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try execute(sql)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        return ["columns": result.columns, "types": result.types, "rows": result.rows, "changes": result.changes,
                "truncated": result.truncated, "ms": (ms * 10).rounded() / 10, "limit": Self.resultLimit]
    }

    private func update(_ name: String, column: String, rowid: Int64, value: Any?, null: Bool) throws {
        let columns = try execute("SELECT name FROM pragma_table_info(?)", bind: [name]).rows.compactMap { $0.first as? String }
        guard columns.contains(column) else { throw BlockError("There's no column \(column).") }
        // Text the page typed: a number stays a number where the column's affinity says so (SQLite converts).
        _ = try execute("UPDATE \(Self.quoted(name)) SET \(Self.quoted(column)) = ? WHERE rowid = ?", bind: [null ? nil : value, rowid])
    }

    /// A query that runs long is stopped, and no transaction is left to
    /// lean on anyone (a closed connection rolls back; a hanging one doesn't).
    func close() {
        dbLock.lock()
        if let running { sqlite3_interrupt(running) }
        dbLock.unlock()
        queue.async { self.closeDatabase() }
    }

    func suspend() { }
}
