import Foundation

// Calls: read-only phone and FaceTime history from CallHistory.storedata (Core Data, synced from
// the iPhone by CallHistorySyncHelper over CloudKit).

// MARK: - Domain

struct CallsSettings: DomainSettings {
    static let key = "calls"
    /// Phone numbers or emails whose calls are hidden everywhere.
    var excludeHandles: [String]
    /// Regexes matched against contact names and caller names.
    var excludeNamePatterns: [String]

    static let defaults = CallsSettings(excludeHandles: [], excludeNamePatterns: [])
}

let callsDomain = Domain(name: "calls", defaults: CallsSettings.defaults, commands: callsCommands, checks: { ctx in
    let t = Date()
    do {
        let s = try CallsStore(ctx, names: false)
        let n = try s.db.query("SELECT COUNT(*) AS N FROM ZCALLRECORD").first?.int("N") ?? 0
        return [Check(domain: "calls", name: "store", ok: true,
                      detail: "\(n) calls readable, schema matches, \(Int(Date().timeIntervalSince(t) * 1000)) ms", fix: nil)]
    } catch {
        let e = AppleError.wrap(error)
        return [Check(domain: "calls", name: "store", ok: false, detail: e.description,
                      fix: e.code == "permission" ? "System Settings > Privacy & Security > Full Disk Access" : nil)]
    }
})

// MARK: - Outputs

struct CallInfo: Encodable {
    let id: String
    let who: String
    let handle: String?
    let date: Date?
    let seconds: Int
    /// "outgoing", "incoming", or "missed" (incoming and not answered).
    let direction: String
    /// "phone", "facetime video", or "facetime audio".
    let kind: String
    let device: String?
    var line: String {
        let when = date.map { String(localISO.string(from: $0).prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? ""
        let len = seconds > 0 ? "  \(seconds / 60)m\(String(format: "%02d", seconds % 60))s" : ""
        return "\(when)  \(direction.padding(toLength: 8, withPad: " ", startingAt: 0))  \(who)  (\(kind))\(len)"
    }
}
struct CallList: Output {
    let calls: [CallInfo]
    let hidden: Int
    var text: String { (calls.isEmpty ? "no calls" : calls.map(\.line).joined(separator: "\n")) + (hidden > 0 ? "\n(\(hidden) hidden)" : "") }
}

// MARK: - Commands

private func callsCommands(_ ctx: Context) -> [Command] {
    let names = Param("no-names", .boolean, "Skip the Contacts name lookup (faster; shows numbers)")
    let since = Param("since", "Only after: YYYY-MM-DD, today, yesterday, 7d, 12h")
    return [
        Command(["calls", "recent"], .read, "Recent phone and FaceTime calls, newest first (default last 7 days).",
                [since, Param("limit", .integer, "Max (default 50)"), names]) { a in
            let s = try CallsStore(ctx, names: !a.bool("no-names"))
            return CallList(calls: try s.calls(since: try a.string("since").map(parseSince) ?? Date().addingTimeInterval(-7 * 86400),
                                               missedOnly: false, who: nil, limit: a.int("limit", 50)), hidden: s.hiddenCount)
        },
        Command(["calls", "missed"], .read, "Missed incoming calls, newest first (default last 7 days).",
                [since, Param("limit", .integer, "Max (default 50)"), names]) { a in
            let s = try CallsStore(ctx, names: !a.bool("no-names"))
            return CallList(calls: try s.calls(since: try a.string("since").map(parseSince) ?? Date().addingTimeInterval(-7 * 86400),
                                               missedOnly: true, who: nil, limit: a.int("limit", 50)), hidden: s.hiddenCount)
        },
        Command(["calls", "with"], .read, "Every call with one person, by contact name, phone, or email. Newest first.",
                [Param("who", required: true, positional: true, "Contact name, phone, or email"), since, Param("limit", .integer, "Max (default 50)")]) { a in
            let s = try CallsStore(ctx, names: true)
            return CallList(calls: try s.calls(since: try a.string("since").map(parseSince), missedOnly: false,
                                               who: try a.require("who"), limit: a.int("limit", 50)), hidden: 0)
        },
    ]
}

// MARK: - Store

final class CallsStore {
    static let path = NSHomeDirectory() + "/Library/Application Support/CallHistoryDB/CallHistory.storedata"
    static let schema: [String: [String]] = [
        "ZCALLRECORD": ["ZDATE", "ZDURATION", "ZADDRESS", "ZNAME", "ZORIGINATED", "ZANSWERED", "ZCALLTYPE", "ZUNIQUE_ID", "ZORIGINATINGDEVICENAME"],
    ]

    let db: SQLiteReader
    let namePatterns: PrivacyFilter
    let excludeHandles: Set<String>
    private var names: [String: String] = [:]
    private var hiddenHandles = Set<String>()
    private(set) var hiddenCount = 0

    /// Same rule as Messages: a Contacts privacy rule that cannot be checked fails the command.
    init(_ ctx: Context, names wantNames: Bool) throws {
        db = try SQLiteReader(path: Self.path)
        try db.require(Self.schema)
        let s = try ctx.settings(CallsSettings.self)
        namePatterns = try PrivacyFilter(titlePatterns: s.excludeNamePatterns, containers: [], ids: [])
        excludeHandles = Set(s.excludeHandles.flatMap(handleKeys))
        let contactRules = try ContactsStore.hasPrivacyRules(ctx) || !s.excludeNamePatterns.isEmpty
        if wantNames || contactRules {
            do {
                let idx = try ContactsStore(ctx).handleIndex()
                names = idx.names
                hiddenHandles = idx.hidden
            } catch {
                if contactRules { throw error }
            }
        }
    }

    private func hides(handle: String?, callerName: String?) -> Bool {
        if let h = handle {
            if handleKeys(h).contains(where: { excludeHandles.contains($0) || hiddenHandles.contains($0) }) { return true }
            if let n = normalizeHandle(h).flatMap({ names[$0] }), namePatterns.hidesTitle(n) { return true }
        }
        if let n = callerName, namePatterns.hidesTitle(n) { return true }
        return false
    }

    private static func kind(_ t: Int?) -> String {
        switch t { case 8: return "facetime video"; case 16: return "facetime audio"; default: return "phone" }
    }

    func calls(since: Date?, missedOnly: Bool, who: String?, limit: Int) throws -> [CallInfo] {
        var w = ["1"], p: [Any] = []
        if let since { w.append("ZDATE >= ?"); p.append(since.timeIntervalSinceReferenceDate) }
        if missedOnly { w.append("ZORIGINATED = 0 AND ZANSWERED = 0") }
        // A name, a number, or an email: matched against handles after resolving names.
        var targets: Set<String>?
        var whoName: String?
        if let who {
            let keys = Set(handleKeys(who))
            if who.contains("@") || who.filter(\.isNumber).count >= 3 { targets = keys } else {
                whoName = who.lowercased()
                targets = Set(names.filter { $0.value.lowercased().contains(whoName!) }.map(\.key))
            }
            if handleKeys(who).contains(where: { excludeHandles.contains($0) || hiddenHandles.contains($0) }) || namePatterns.hidesTitle(who) {
                throw AppleError.hidden(who)
            }
        }
        hiddenCount = 0
        var out: [CallInfo] = []
        for r in try db.query("""
            SELECT ZUNIQUE_ID, ZDATE, ZDURATION, ZADDRESS, ZNAME, ZORIGINATED, ZANSWERED, ZCALLTYPE, ZORIGINATINGDEVICENAME
            FROM ZCALLRECORD WHERE \(w.joined(separator: " AND ")) ORDER BY ZDATE DESC
            """, p) {
            let handle = r.str("ZADDRESS").flatMap { $0.isEmpty ? nil : $0 }
            let caller = r.str("ZNAME").flatMap { $0.isEmpty ? nil : $0 }
            if hides(handle: handle, callerName: caller) { hiddenCount += 1; continue }
            let contact = handle.flatMap(normalizeHandle).flatMap { names[$0] }
            if let targets {
                let keys = Set(handle.map(handleKeys) ?? [])
                let byName = whoName.map { n in (contact ?? caller ?? "").lowercased().contains(n) } ?? false
                guard !keys.isDisjoint(with: targets) || byName else { continue }
            }
            let out1 = r.bool("ZORIGINATED")
            out.append(CallInfo(id: r.str("ZUNIQUE_ID") ?? "", who: contact ?? caller ?? handle ?? "unknown", handle: handle,
                                date: r.date("ZDATE"), seconds: Int(((r["ZDURATION"] as? Double) ?? 0).rounded()),
                                direction: out1 ? "outgoing" : (r.bool("ZANSWERED") ? "incoming" : "missed"),
                                kind: Self.kind(r.int("ZCALLTYPE")), device: r.str("ZORIGINATINGDEVICENAME")))
            if out.count >= limit { break }
        }
        return out
    }
}
