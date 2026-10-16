import Foundation
import SQLite3

// Shared access paths: read-only SQLite for app stores, and osascript for scripted writes.

/// A read-only SQLite connection. Opens the live file with `mode=ro`.
/// If the file is locked or cannot be opened, copies the database plus its
/// `-wal` and `-shm` files to a temp folder and reads the copy instead.
public final class SQLiteReader {
    private var db: OpaquePointer?
    private var tempDir: URL?
    public let path: String
    public private(set) var readFromCopy = false

    /// `allowCopy: false` for huge stores (Photos is 2.2 GB): a lock fails clearly instead of copying.
    public init(path: String, allowCopy: Bool = true) throws {
        self.path = path
        guard FileManager.default.fileExists(atPath: path) else {
            throw AppleError.notFound("database \(path)")
        }
        if !FileManager.default.isReadableFile(atPath: path) {
            throw Self.noAccess(path)
        }
        do {
            try open(path)
            // Touch the schema so a lock surfaces now, not mid-query.
            _ = try query("SELECT count(*) FROM sqlite_master")
        } catch {
            close()
            guard allowCopy else {
                throw AppleError.database("\((path as NSString).lastPathComponent) is locked and too large to copy. Try again in a moment.")
            }
            do { try openCopy() } catch let e as NSError where e.code == NSFileReadNoPermissionError || e.code == 513 {
                throw Self.noAccess(path)
            }
        }
    }

    static func noAccess(_ path: String) -> AppleError {
        .permission("cannot read \(path). Give AppleCLI Full Disk Access: System Settings > Privacy & Security > Full Disk Access, "
                    + "add ~/Applications/AppleCLI.app, and turn it on. `apple-cli permissions --request` opens the pane")
    }

    deinit { close() }

    private func open(_ p: String) throws {
        let uri = "file:" + (p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p) + "?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(uri, &db, flags, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw AppleError.database(msg)
        }
        sqlite3_busy_timeout(db, 250)
        // fold(text): lowercased with accents removed, so SQL can match the way Swift's
        // caseInsensitive + diacriticInsensitive search does. NULL stays NULL.
        let fold: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = { ctx, argc, argv in
            guard argc == 1, let v = argv?[0], sqlite3_value_type(v) != SQLITE_NULL, let c = sqlite3_value_text(v) else {
                sqlite3_result_null(ctx); return
            }
            let s = String(cString: c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            sqlite3_result_text(ctx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_create_function_v2(db, "fold", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, fold, nil, nil, nil) == SQLITE_OK else {
            throw AppleError.database("could not register fold(): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func openCopy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apple-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        let name = (path as NSString).lastPathComponent
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            try FileManager.default.copyItem(atPath: path + suffix, toPath: dir.appendingPathComponent(name + suffix).path)
        }
        try open(dir.appendingPathComponent(name).path)
        readFromCopy = true
    }

    private func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    /// Schema guard. Throws `schema_changed` naming every missing table or column,
    /// so an OS update produces a clear error instead of wrong answers.
    public func require(_ expected: [String: [String]]) throws {
        var missing: [String] = []
        for (table, cols) in expected {
            let have = Set(try query("SELECT name FROM pragma_table_info(?)", [table]).compactMap { $0.str("name") })
            if have.isEmpty { missing.append(table); continue }
            missing += cols.filter { !have.contains($0) }.map { "\(table).\($0)" }
        }
        if !missing.isEmpty {
            throw AppleError.schemaChanged("\((path as NSString).lastPathComponent) is missing \(missing.sorted().joined(separator: ", "))")
        }
    }

    /// Runs one statement and returns every row as column-name -> value.
    /// Values are Int64, Double, String, Data, or NSNull.
    public func query(_ sql: String, _ params: [Any] = []) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw AppleError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, transient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        var rows: [[String: Any]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw AppleError.database(String(cString: sqlite3_errmsg(db))) }
            var row: [String: Any] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, c)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, c))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if let p = sqlite3_column_blob(stmt, c), n > 0 { row[name] = Data(bytes: p, count: n) } else { row[name] = Data() }
                default: row[name] = NSNull()
                }
            }
            rows.append(row)
        }
        return rows
    }
}

// Row helpers. Core Data stores dates as seconds since 2001-01-01.
extension Dictionary where Key == String, Value == Any {
    func int(_ k: String) -> Int? { (self[k] as? Int64).map(Int.init) ?? (self[k] as? Double).map { Int($0) } }
    func str(_ k: String) -> String? { self[k] as? String }
    func data(_ k: String) -> Data? { (self[k] as? Data).flatMap { $0.isEmpty ? nil : $0 } }
    func bool(_ k: String) -> Bool { (int(k) ?? 0) != 0 }
    func date(_ k: String) -> Date? {
        if let d = self[k] as? Double { return Date(timeIntervalSinceReferenceDate: d) }
        if let i = self[k] as? Int64 { return Date(timeIntervalSinceReferenceDate: Double(i)) }
        return nil
    }
}

/// Runs a program with a deadline. Output goes to temp files, not pipes, so a child
/// that writes more than a pipe buffer never blocks waiting to be read.
func runProcess(_ exe: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval, what: String) throws -> (status: Int32, out: String, err: String) {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("apple-cli-proc-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let outURL = dir.appendingPathComponent("out"), errURL = dir.appendingPathComponent("err")
    fm.createFile(atPath: outURL.path, contents: nil); fm.createFile(atPath: errURL.path, contents: nil)
    let outH = try FileHandle(forWritingTo: outURL), errH = try FileHandle(forWritingTo: errURL)
    defer { try? outH.close(); try? errH.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = outH; p.standardError = errH
    let inPipe = Pipe()
    p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
    try p.run()
    if let stdin {
        try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
        try? inPipe.fileHandleForWriting.close()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(5_000) }
    if p.isRunning { p.terminate(); throw AppleError.timeout("\(what) did not finish within \(Int(timeout))s") }
    let read = { (u: URL) in String(decoding: (try? Data(contentsOf: u)) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    return (p.terminationStatus, read(outURL), read(errURL))
}

/// Runs AppleScript from stdin with arguments passed as argv, so user text
/// is never spliced into script source. Every call has a deadline.
enum Osascript {
    static func run(_ script: String, _ args: [String], app: String, timeout: TimeInterval = 15) throws -> String {
        let r = try runProcess("/usr/bin/osascript", ["-"] + args, stdin: Data(script.utf8), timeout: timeout, what: app)
        guard r.status == 0 else {
            if r.err.contains("-1743") { throw AppleError.permission("allow control of \(app) in System Settings > Privacy & Security > Automation") }
            throw AppleError.app("\(app): \(r.err)")
        }
        return r.out
    }
}
