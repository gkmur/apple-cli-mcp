import Foundation

// Shortcuts: list and inspect from Shortcuts.sqlite (Core Data, synced by CloudKit); run through
// Apple's /usr/bin/shortcuts. Running is CLI only, since a shortcut can do anything.

// MARK: - Domain

struct ShortcutsSettings: DomainSettings {
    static let key = "shortcuts"
    /// Regexes matched against shortcut names. Matches never print and cannot be run.
    var excludeNamePatterns: [String]

    static let defaults = ShortcutsSettings(excludeNamePatterns: [])
}

let shortcutsDomain = Domain(name: "shortcuts", defaults: ShortcutsSettings.defaults, commands: shortcutsCommands, checks: { ctx in
    let t = Date()
    do {
        let all = try ShortcutsStore(ctx).list()
        return [Check(domain: "shortcuts", name: "store", ok: true,
                      detail: "\(all.count) shortcuts readable, schema matches, \(Int(Date().timeIntervalSince(t) * 1000)) ms", fix: nil)]
    } catch {
        let e = AppleError.wrap(error)
        return [Check(domain: "shortcuts", name: "store", ok: false, detail: e.description,
                      fix: e.code == "permission" ? "System Settings > Privacy & Security > Full Disk Access: turn on AppleCLI" : nil)]
    }
})

// MARK: - Outputs

struct ShortcutInfo: Encodable {
    let id: String
    let name: String
    let actions: Int
    let created: Date?
    let modified: Date?
    let lastRun: Date?
    let runs: Int
    var line: String { "\(name)  (\(actions) actions\(lastRun.map { ", last run " + localISO.string(from: $0) } ?? ""))" }
}
struct ShortcutList: Output {
    let shortcuts: [ShortcutInfo]
    let hidden: Int
    var text: String { (shortcuts.isEmpty ? "no shortcuts" : shortcuts.map(\.line).joined(separator: "\n")) + (hidden > 0 ? "\n(\(hidden) hidden)" : "") }
}

struct ShortcutDetail: Output {
    let shortcut: ShortcutInfo
    /// Action identifiers in order. Parameters are left out: they can hold URLs, tokens, and message text.
    let steps: [String]
    var text: String {
        ([shortcut.line, ""] + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }).joined(separator: "\n")
    }
}

struct ShortcutRun: Output {
    let shortcut: String
    let output: String?
    var text: String { output ?? "(ran \(shortcut); no text output)" }
}

// MARK: - Commands

private func shortcutsCommands(_ ctx: Context) -> [Command] {
    [
        Command(["shortcuts", "list"], .read, "Shortcuts by name, with action count and last run.") { _ in
            let s = try ShortcutsStore(ctx)
            return ShortcutList(shortcuts: try s.list(), hidden: s.hiddenCount)
        },
        Command(["shortcuts", "read"], .read, "One shortcut's actions in order (identifiers only, no parameters).",
                [Param("shortcut", required: true, positional: true, "Name or ID")]) { a in
            try ShortcutsStore(ctx).read(try a.require("shortcut"))
        },
        Command(["shortcuts", "run"], .destructive, "Run a shortcut through Apple's shortcuts tool and print its text output.",
                [Param("shortcut", required: true, positional: true, "Name or ID"), Param("input", "Text passed as the shortcut's input"),
                 Param("timeout", .integer, "Seconds to wait (default 120)")]) { a in
            try ShortcutsStore(ctx).run(try a.require("shortcut"), input: a.string("input"), timeout: Double(a.int("timeout", 120)))
        },
    ]
}

// MARK: - Store

final class ShortcutsStore {
    static let path = NSHomeDirectory() + "/Library/Shortcuts/Shortcuts.sqlite"
    static let schema: [String: [String]] = [
        "ZSHORTCUT": ["Z_PK", "ZWORKFLOWID", "ZNAME", "ZACTIONCOUNT", "ZTOMBSTONED", "ZHIDDENFROMLIBRARYANDSYNC",
                      "ZCREATIONDATE", "ZMODIFICATIONDATE", "ZLASTRUNEVENTDATE", "ZRUNEVENTSCOUNT"],
        "ZSHORTCUTACTIONS": ["ZSHORTCUT", "ZDATA"],
    ]

    let db: SQLiteReader
    let privacy: PrivacyFilter
    private(set) var hiddenCount = 0

    init(_ ctx: Context) throws {
        privacy = try PrivacyFilter(titlePatterns: try ctx.settings(ShortcutsSettings.self).excludeNamePatterns, containers: [], ids: [])
        db = try SQLiteReader(path: Self.path)
        try db.require(Self.schema)
    }

    private func rows() throws -> [(pk: Int, info: ShortcutInfo)] {
        hiddenCount = 0
        var out: [(Int, ShortcutInfo)] = []
        for r in try db.query("""
            SELECT Z_PK, ZWORKFLOWID, ZNAME, ZACTIONCOUNT, ZCREATIONDATE, ZMODIFICATIONDATE, ZLASTRUNEVENTDATE, ZRUNEVENTSCOUNT
            FROM ZSHORTCUT WHERE ZTOMBSTONED = 0 AND ZHIDDENFROMLIBRARYANDSYNC = 0 ORDER BY ZNAME COLLATE NOCASE
            """) {
            guard let pk = r.int("Z_PK"), let id = r.str("ZWORKFLOWID"), let name = r.str("ZNAME") else { continue }
            if privacy.hidesTitle(name) { hiddenCount += 1; continue }
            out.append((pk, ShortcutInfo(id: id, name: name, actions: r.int("ZACTIONCOUNT") ?? 0, created: r.date("ZCREATIONDATE"),
                                         modified: r.date("ZMODIFICATIONDATE"), lastRun: r.date("ZLASTRUNEVENTDATE"),
                                         runs: r.int("ZRUNEVENTSCOUNT") ?? 0)))
        }
        return out
    }

    func list() throws -> [ShortcutInfo] { try rows().map(\.info) }

    /// Matches by ID, then exact name, then case-insensitive name. A hidden match is refused.
    private func resolve(_ ref: String) throws -> (pk: Int, info: ShortcutInfo) {
        let all = try rows()
        if let m = all.first(where: { $0.info.id.caseInsensitiveCompare(ref) == .orderedSame })
            ?? all.first(where: { $0.info.name == ref })
            ?? all.first(where: { $0.info.name.caseInsensitiveCompare(ref) == .orderedSame }) { return m }
        let exists = try !db.query("""
            SELECT 1 FROM ZSHORTCUT WHERE ZTOMBSTONED = 0 AND (ZWORKFLOWID = ? COLLATE NOCASE OR ZNAME = ? COLLATE NOCASE)
            """, [ref, ref]).isEmpty
        if privacy.hidesTitle(ref) || exists {
            throw AppleError.hidden("shortcut \(ref)")
        }
        throw AppleError.notFound("shortcut \(ref)")
    }

    func read(_ ref: String) throws -> ShortcutDetail {
        let m = try resolve(ref)
        var steps: [String] = []
        if let data = try db.query("SELECT ZDATA FROM ZSHORTCUTACTIONS WHERE ZSHORTCUT = ?", [m.pk]).first?.data("ZDATA"),
           let actions = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] {
            steps = actions.map { a in
                let id = a["WFWorkflowActionIdentifier"] as? String ?? "unknown"
                return id.hasPrefix("is.workflow.actions.") ? String(id.dropFirst("is.workflow.actions.".count)) : id
            }
        }
        return ShortcutDetail(shortcut: m.info, steps: steps)
    }

    func run(_ ref: String, input: String?, timeout: Double) throws -> ShortcutRun {
        let m = try resolve(ref)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apple-cli-sc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outFile = dir.appendingPathComponent("output.txt")
        var args = ["run", m.info.id, "--output-path", outFile.path, "--output-type", "public.plain-text"]
        if let input {
            let inFile = dir.appendingPathComponent("input.txt")
            try Data(input.utf8).write(to: inFile)
            args += ["--input-path", inFile.path]
        }
        let r = try runProcess("/usr/bin/shortcuts", args, timeout: timeout, what: m.info.name)
        guard r.status == 0 else { throw AppleError.app("shortcuts: \(r.err.isEmpty ? "exit \(r.status)" : r.err)") }
        let out = (try? String(contentsOf: outFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShortcutRun(shortcut: m.info.name, output: out?.isEmpty == false ? out : nil)
    }
}
