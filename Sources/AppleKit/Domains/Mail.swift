import Foundation

// Mail: read-only. Headers, previews, mailboxes and Gmail labels come from Mail's
// "Envelope Index" SQLite store; bodies come from the .emlx files beside it.
// Sending stays with the user's mail MCP.

// MARK: - Domain

struct MailSettings: DomainSettings {
    static let key = "mail"
    /// Mailboxes (or Gmail labels) hidden everywhere, by path ("Finance", "[Gmail]/Important") or last component.
    var excludeMailboxes: [String]
    /// Senders or recipients hidden everywhere: an email address, or a domain like "bank.com".
    var excludeAddresses: [String]
    /// Regexes matched against subjects. A match hides the message everywhere.
    var excludeSubjectPatterns: [String]
    /// Replace one-time codes and sign-in or password-reset links with a placeholder, and leave them out of search.
    var maskOneTimeCodes: Bool
    var oneTimeCodePatterns: [String]

    static let defaults = MailSettings(
        excludeMailboxes: [], excludeAddresses: [], excludeSubjectPatterns: [], maskOneTimeCodes: true,
        oneTimeCodePatterns: MessagesSettings.defaults.oneTimeCodePatterns + [
            #"(?i)\b(reset|change) your password\b"#,
            #"(?i)\bpassword reset\b"#,
            #"(?i)\b(magic|sign[- ]?in|log[- ]?in) link\b"#,
        ])
}

let mailDomain = Domain(name: "mail", defaults: MailSettings.defaults, commands: mailCommands, checks: { ctx in
    let t = Date()
    do {
        let s = try MailStore(ctx)
        let n = try s.db.query("SELECT COUNT(*) AS N, MAX(date_received) AS Z FROM messages WHERE deleted = 0").first
        let newest = n?.int("Z").map { Date(timeIntervalSince1970: Double($0)) }
        return [
            Check(domain: "mail", name: "store", ok: true,
                  detail: "\(n?.int("N") ?? 0) messages readable, schema matches, \(Int(Date().timeIntervalSince(t) * 1000)) ms", fix: nil),
            // An old index is information, not a failure: the user may read mail elsewhere.
            Check(domain: "mail", name: "freshness", ok: true,
                  detail: "newest message \(newest.map { localISO.string(from: $0) } ?? "none"). "
                      + (mailStaleWarning(newest) ?? "The index is only as fresh as Mail.app's last sync"),
                  fix: mailStaleWarning(newest) == nil ? nil : "Open Mail so it syncs"),
        ]
    } catch {
        let e = AppleError.wrap(error)
        return [Check(domain: "mail", name: "store", ok: false, detail: e.description,
                      fix: e.code == "permission" ? "System Settings > Privacy & Security > Full Disk Access: turn on AppleCLI" : nil)]
    }
})

// MARK: - Outputs

struct MailboxInfo: Encodable { let account: String; let mailbox: String; let messages: Int; let unread: Int }
struct MailboxList: Output {
    let mailboxes: [MailboxInfo]
    var text: String {
        mailboxes.map { "\($0.account) / \($0.mailbox)  \($0.messages) (\($0.unread) unread)" }.joined(separator: "\n")
    }
}

struct MailSummary: Encodable {
    let id: String
    let subject: String
    let from: String
    let fromAddress: String?
    let date: Date?
    let account: String
    let mailbox: String
    let unread: Bool
    let flagged: Bool
    let preview: String?
    var line: String {
        let when = date.map { String(localISO.string(from: $0).prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? ""
        return "\(unread ? "*" : " ") \(when)  \(from)  \(subject)  [\(mailbox)]  id \(id)"
    }
}
struct MailList: Output {
    let messages: [MailSummary]
    /// Newest message in the index. Mail's index only updates while Mail.app runs.
    let indexedThrough: Date?
    /// Set when the index is over a day old, so a reader knows newer mail may be missing.
    let warning: String?

    init(messages: [MailSummary], indexedThrough: Date?) {
        self.messages = messages
        self.indexedThrough = indexedThrough
        warning = mailStaleWarning(indexedThrough)
    }
    var text: String {
        (messages.isEmpty ? "no messages" : messages.map(\.line).joined(separator: "\n"))
            + "\n(index current through \(indexedThrough.map { localISO.string(from: $0) } ?? "unknown"))"
            + (warning.map { "\nwarning: \($0)" } ?? "")
    }
}

/// Mail.app writes its index only while it runs. Nil when the newest message is under a day old.
func mailStaleWarning(_ newest: Date?) -> String? {
    guard let newest, Date().timeIntervalSince(newest) > 86400 else { return nil }
    let hours = Int(Date().timeIntervalSince(newest) / 3600)
    return "Mail.app has not synced for \(hours / 24)d \(hours % 24)h, so newer mail is missing. Open Mail.app on this Mac to catch up."
}

struct MailMessage: Output {
    let id: String
    let subject: String
    let from: String
    let fromAddress: String?
    let to: [String]
    let cc: [String]
    let date: Date?
    let account: String
    let mailbox: String
    let unread: Bool
    let flagged: Bool
    let conversationId: Int?
    let attachments: [String]
    let body: String?
    /// False when Mail has not downloaded the body; `preview` is then all there is.
    let bodyAvailable: Bool
    let truncated: Bool
    let preview: String?
    var text: String {
        var out = ["Subject: \(subject)", "From: \(from)", "To: \(to.joined(separator: ", "))"]
        if !cc.isEmpty { out.append("Cc: \(cc.joined(separator: ", "))") }
        out.append("Date: \(date.map { localISO.string(from: $0) } ?? "?")  [\(account) / \(mailbox)]")
        if !attachments.isEmpty { out.append("Attachments: \(attachments.joined(separator: ", "))") }
        out.append("")
        out.append(body ?? "(body not downloaded by Mail) " + (preview ?? ""))
        if truncated { out.append("\n[truncated; pass --max-chars to read more]") }
        return out.joined(separator: "\n")
    }
}

// MARK: - Commands

private func mailCommands(_ ctx: Context) -> [Command] {
    let since = Param("since", "Only after: YYYY-MM-DD, today, yesterday, 7d, 12h")
    let mailbox = Param("mailbox", "Only this mailbox or Gmail label (path or last part, e.g. INBOX, Finance)")
    let account = Param("account", "Only this account (e.g. iCloud, Google Personal)")
    let limit = Param("limit", .integer, "Max (default 20)")
    return [
        Command(["mail", "mailboxes"], .read, "Mailboxes and Gmail labels per account, with message and unread counts.") { _ in
            MailboxList(mailboxes: try MailStore(ctx).mailboxList())
        },
        Command(["mail", "list"], .read, "Recent messages, newest first. Skips junk and trash unless --mailbox names one.",
                [mailbox, account, since, Param("unread", .boolean, "Only unread"), Param("flagged", .boolean, "Only flagged"), limit]) { a in
            let s = try MailStore(ctx)
            return MailList(messages: try s.find(MailQuery(text: nil, from: nil, mailbox: a.string("mailbox"), account: a.string("account"),
                                                           since: try a.string("since").map(parseSince), unread: a.bool("unread"),
                                                           flagged: a.bool("flagged"), body: false), limit: a.int("limit", 20)),
                            indexedThrough: try s.newest())
        },
        Command(["mail", "search"], .read, "Search subjects, senders, and previews, newest first. --body also scans downloaded bodies (slower).",
                [Param("query", required: true, positional: true, "Text to find"), Param("from", "Only from this name or address"),
                 mailbox, account, since, Param("body", .boolean, "Also search message bodies (default window 90d)"), limit]) { a in
            let s = try MailStore(ctx)
            let body = a.bool("body")
            let from = try a.string("since").map(parseSince) ?? (body ? Date().addingTimeInterval(-90 * 86400) : nil)
            return MailList(messages: try s.find(MailQuery(text: try a.require("query"), from: a.string("from"), mailbox: a.string("mailbox"),
                                                           account: a.string("account"), since: from, unread: false, flagged: false, body: body),
                                                 limit: a.int("limit", 20)),
                            indexedThrough: try s.newest())
        },
        Command(["mail", "unread"], .read, "Unread messages, newest first (default last 7 days).", [account, since, limit]) { a in
            let s = try MailStore(ctx)
            return MailList(messages: try s.find(MailQuery(text: nil, from: nil, mailbox: nil, account: a.string("account"),
                                                           since: try a.string("since").map(parseSince) ?? Date().addingTimeInterval(-7 * 86400),
                                                           unread: true, flagged: false, body: false), limit: a.int("limit", 50)),
                            indexedThrough: try s.newest())
        },
        Command(["mail", "draft"], .write, "Draft an email for review: new, reply, reply-all, or forward. Nothing is sent until `mail send <draft-id>`; it goes out exactly as shown.",
                [Param("to", "Recipients, comma-separated (a reply fills these in)"), Param("cc", "Cc, comma-separated"), Param("bcc", "Bcc, comma-separated"),
                 Param("subject", "Subject (a reply or forward fills it in)"), Param("body", required: true, "Body text"),
                 Param("from", "Send from this address (default: Mail's default account)"),
                 Param("attach", "Files to attach, comma-separated. Over MCP, files must be in ~/Downloads/apple-cli"),
                 Param("reply-to", "Message ID to reply to"), Param("reply-all", .boolean, "Reply to everyone on the message"),
                 Param("forward", "Message ID to forward")]) { a in
            try MailWriter(ctx).draft(a)
        },
        Command(["mail", "send"], .write, "Send a drafted email exactly as drafted, then confirm it reached a Sent mailbox.",
                [Param("draft", required: true, positional: true, "Draft ID from mail draft"),
                 Param("save-only", .boolean, "Save it to Mail's Drafts mailbox (syncs to your phone) instead of sending")]) { a in
            try MailWriter(ctx).send(try a.require("draft"), saveOnly: a.bool("save-only"))
        },
        Command(["mail", "modify"], .write, "Change messages: archive, trash (recoverable), move, read, unread, flag, unflag. Reads each back and reports what took.",
                [Param("ids", required: true, positional: true, "Message IDs, space or comma separated"),
                 Param("action", required: true, "archive, trash, move, read, unread, flag, or unflag"),
                 Param("mailbox", "Target mailbox for move (path within the same account, e.g. Receipts)")]) { a in
            let ids = try a.require("ids").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            return try MailWriter(ctx).modify(ids, action: try a.require("action"), mailbox: a.string("mailbox"))
        },
        Command(["mail", "attachments"], .write, "Save a message's attachments into a folder.",
                [Param("id", required: true, positional: true, "Message ID"),
                 Param("to", required: true, "Destination folder. Over MCP it is a folder name under ~/Downloads/apple-cli")]) { a in
            try MailWriter(ctx).saveAttachments(try a.require("id"), to: try PhotosWriter.destination(try a.require("to"), agent: a.viaMCP))
        },
        Command(["mail", "read"], .read, "Read one message: headers, recipients, attachments, and the body as plain text.",
                [Param("id", required: true, positional: true, "Message ID from list or search"),
                 Param("max-chars", .integer, "Body length cap (default 20000)")]) { a in
            try MailStore(ctx).read(try a.require("id"), maxChars: a.int("max-chars", 20000))
        },
    ]
}

// MARK: - Store

struct MailQuery {
    let text: String?
    let from: String?
    let mailbox: String?
    let account: String?
    let since: Date?
    let unread: Bool
    let flagged: Bool
    let body: Bool
}

final class MailStore {
    static let root = NSHomeDirectory() + "/Library/Mail/V10"
    static let path = root + "/MailData/Envelope Index"
    static let schema: [String: [String]] = [
        "messages": ["ROWID", "sender", "subject_prefix", "subject", "summary", "date_received", "mailbox", "read", "flagged", "deleted", "conversation_id"],
        "mailboxes": ["ROWID", "url", "total_count", "unread_count"],
        "subjects": ["ROWID", "subject"],
        "addresses": ["ROWID", "address", "comment"],
        "recipients": ["message", "address", "type", "position"],
        "summaries": ["ROWID", "summary"],
        "labels": ["message_id", "mailbox_id"],
        "attachments": ["message", "name"],
    ]
    /// Mailboxes skipped unless asked for by name.
    static let junk: Set<String> = ["junk", "spam", "trash", "bin", "deleted messages", "deleted items"]

    struct Box { let id: Int; let accountID: String; let account: String; let path: String; let total: Int; let unread: Int }

    let db: SQLiteReader
    let settings: MailSettings
    let subjectFilter: PrivacyFilter
    let codePatterns: PrivacyFilter
    let boxes: [Int: Box]
    /// Mailboxes hidden by config, and address rows hidden by config or by Contacts privacy rules.
    let hiddenBoxes: Set<Int>
    let hiddenAddresses: Set<Int>
    private var storeDirs: [Int: [String]] = [:]

    init(_ ctx: Context) throws {
        db = try SQLiteReader(path: Self.path)
        try db.require(Self.schema)
        settings = try ctx.settings(MailSettings.self)
        subjectFilter = try PrivacyFilter(titlePatterns: settings.excludeSubjectPatterns, containers: settings.excludeMailboxes, ids: [])
        codePatterns = try PrivacyFilter(titlePatterns: settings.oneTimeCodePatterns, containers: [], ids: [])

        let names = Self.accountNames()
        var b: [Int: Box] = [:]
        for r in try db.query("SELECT ROWID, url, total_count, unread_count FROM mailboxes") {
            guard let id = r.int("ROWID"), let url = r.str("url"), let u = URL(string: url) else { continue }
            let acct = u.host ?? ""
            let path = (u.path.removingPercentEncoding ?? u.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            b[id] = Box(id: id, accountID: acct, account: names[acct] ?? String(acct.prefix(8)), path: path,
                        total: r.int("total_count") ?? 0, unread: r.int("unread_count") ?? 0)
        }
        boxes = b
        let filter = subjectFilter
        hiddenBoxes = Set(b.values.filter { box in
            filter.hidesContainer(box.path) || filter.hidesContainer(box.path.split(separator: "/").last.map(String.init) ?? box.path)
        }.map(\.id))

        // Addresses: config entries, plus every handle of a person hidden in Contacts. A Contacts
        // rule that cannot be checked fails the command (fail closed).
        var keys = Set<String>(), domains: [String] = []
        for e in settings.excludeAddresses.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }) where !e.isEmpty {
            if e.contains("@") && !e.hasPrefix("@") { keys.insert(e) } else { domains.append(e.trimmingCharacters(in: CharacterSet(charactersIn: "@."))) }
        }
        if try ContactsStore.hasPrivacyRules(ctx) { keys.formUnion(try ContactsStore(ctx).handleIndex().hidden) }
        var hidden = Set<Int>()
        if !keys.isEmpty || !domains.isEmpty {
            for r in try db.query("SELECT ROWID, address FROM addresses") {
                guard let id = r.int("ROWID"), let a = r.str("address")?.lowercased().trimmingCharacters(in: .whitespaces) else { continue }
                let host = a.split(separator: "@").last.map(String.init) ?? ""
                if keys.contains(a) || domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { hidden.insert(id) }
            }
        }
        hiddenAddresses = hidden
    }

    /// Account display names from the system accounts store, keyed by account ID. Empty when unreadable.
    static func accountNames() -> [String: String] {
        guard let db = try? SQLiteReader(path: NSHomeDirectory() + "/Library/Accounts/Accounts4.sqlite"),
              let rows = try? db.query("""
                SELECT a.ZIDENTIFIER AS ID, COALESCE(a.ZACCOUNTDESCRIPTION, p.ZACCOUNTDESCRIPTION, a.ZUSERNAME) AS NAME
                FROM ZACCOUNT a LEFT JOIN ZACCOUNT p ON p.Z_PK = a.ZPARENTACCOUNT
                """) else { return [:] }
        var out: [String: String] = [:]
        for r in rows { if let id = r.str("ID"), let n = r.str("NAME"), !n.isEmpty { out[id] = n } }
        return out
    }

    func newest() throws -> Date? {
        try db.query("SELECT MAX(date_received) AS Z FROM messages WHERE deleted = 0").first?.int("Z").map { Date(timeIntervalSince1970: Double($0)) }
    }

    func mailboxList() -> [MailboxInfo] {
        boxes.values.filter { !hiddenBoxes.contains($0.id) && $0.total > 0 }
            .sorted { ($0.account, $0.path) < ($1.account, $1.path) }
            .map { MailboxInfo(account: $0.account, mailbox: $0.path, messages: $0.total, unread: $0.unread) }
    }

    private func matchBoxes(_ name: String) -> [Int] {
        let n = name.lowercased()
        return boxes.values.filter { $0.path.lowercased() == n || $0.path.split(separator: "/").last?.lowercased() == n }.map(\.id)
    }

    private func isJunk(_ box: Box) -> Bool {
        box.path.split(separator: "/").last.map { Self.junk.contains($0.lowercased()) } ?? false
    }

    private static func idList(_ ids: some Collection<Int>) -> String { ids.isEmpty ? "-1" : ids.map(String.init).joined(separator: ",") }

    /// SQL that removes hidden messages: hidden mailboxes or labels, hidden senders or recipients.
    private var privacySQL: String {
        var w = ["m.deleted = 0"]
        if !hiddenBoxes.isEmpty {
            let l = Self.idList(hiddenBoxes)
            w.append("m.mailbox NOT IN (\(l)) AND NOT EXISTS (SELECT 1 FROM labels x WHERE x.message_id = m.ROWID AND x.mailbox_id IN (\(l)))")
        }
        if !hiddenAddresses.isEmpty {
            let l = Self.idList(hiddenAddresses)
            w.append("COALESCE(m.sender, -1) NOT IN (\(l)) AND NOT EXISTS (SELECT 1 FROM recipients x WHERE x.message = m.ROWID AND x.address IN (\(l)))")
        }
        return w.joined(separator: " AND ")
    }

    private static let select = """
        SELECT m.ROWID AS id, m.subject_prefix AS prefix, s.subject AS subject, a.address AS address, a.comment AS name,
               m.date_received AS date, m.read AS read, m.flagged AS flagged, m.mailbox AS mailbox, su.summary AS summary,
               m.conversation_id AS conv
        FROM messages m JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender LEFT JOIN summaries su ON su.ROWID = m.summary
        """

    func isOneTimeCode(_ t: String) -> Bool {
        settings.maskOneTimeCodes && codePatterns.hidesTitle(t)
    }

    private func subject(_ r: [String: Any]) -> String { (r.str("prefix") ?? "") + (r.str("subject") ?? "") }

    /// True when a row must not print at all (subject pattern), checked after SQL.
    private func hiddenRow(_ r: [String: Any]) -> Bool { subjectFilter.hidesTitle(subject(r)) }

    private func summary(_ r: [String: Any], masked: Bool) -> MailSummary {
        let box = r.int("mailbox").flatMap { boxes[$0] }
        let name = r.str("name").flatMap { $0.isEmpty ? nil : $0 }
        let addr = r.str("address")
        let preview = r.str("summary").map { String($0.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines) }
        // A masked message's subject can hold the code itself, so it is replaced too.
        return MailSummary(id: String(r.int("id") ?? 0), subject: masked ? "[one-time code hidden]" : subject(r),
                           from: name.map { n in addr.map { "\(n) <\($0)>" } ?? n } ?? addr ?? "unknown", fromAddress: addr,
                           date: r.int("date").map { Date(timeIntervalSince1970: Double($0)) },
                           account: box?.account ?? "", mailbox: box?.path ?? "",
                           unread: !r.bool("read"), flagged: r.bool("flagged"), preview: masked ? "[one-time code hidden]" : preview)
    }

    private func masked(_ r: [String: Any]) -> Bool { isOneTimeCode(subject(r) + "\n" + (r.str("summary") ?? "")) }

    func find(_ q: MailQuery, limit: Int) throws -> [MailSummary] {
        var w = [privacySQL]
        var p: [Any] = []
        if let m = q.mailbox {
            let ids = matchBoxes(m)
            if ids.isEmpty { throw AppleError.notFound("mailbox \(m)") }
            if ids.allSatisfy(hiddenBoxes.contains) { throw AppleError.hidden("mailbox \(m)") }
            let l = Self.idList(ids)
            w.append("(m.mailbox IN (\(l)) OR EXISTS (SELECT 1 FROM labels x WHERE x.message_id = m.ROWID AND x.mailbox_id IN (\(l))))")
        } else {
            let junk = boxes.values.filter(isJunk).map(\.id)
            if !junk.isEmpty { w.append("m.mailbox NOT IN (\(Self.idList(junk)))") }
        }
        if let a = q.account?.lowercased() {
            let ids = boxes.values.filter { $0.account.lowercased() == a || $0.accountID.lowercased() == a }.map(\.id)
            if ids.isEmpty { throw AppleError.notFound("account \(q.account!)") }
            w.append("m.mailbox IN (\(Self.idList(ids)))")
        }
        if let s = q.since { w.append("m.date_received >= ?"); p.append(Int64(s.timeIntervalSince1970)) }
        if q.unread { w.append("m.read = 0") }
        if q.flagged { w.append("m.flagged = 1") }
        // Case- and accent-insensitive matching in SQL through fold(), so misses never leave SQLite.
        // Body search keeps header misses for the body scan, so it only filters on --from here.
        let containsFolded = { (col: String) in "instr(fold(\(col)), fold(?)) > 0" }
        if let t = q.text, !q.body {
            w.append("(\(containsFolded("s.subject")) OR \(containsFolded("a.address")) OR \(containsFolded("a.comment")) OR \(containsFolded("su.summary")))")
            p += Array(repeating: t, count: 4)
        }
        if let f = q.from {
            w.append("(\(containsFolded("a.address")) OR \(containsFolded("a.comment")))")
            p += [f, f]
        }
        let sql = "\(Self.select) WHERE \(w.joined(separator: " AND ")) ORDER BY m.date_received DESC"
        var out: [MailSummary] = []
        var scanned = 0
        // Text queries need every hit; listings stop early, so page through.
        let page = 500
        var offset = 0
        while out.count < limit {
            let rows = try db.query(sql + " LIMIT \(page) OFFSET \(offset)", p)
            if rows.isEmpty { break }
            offset += rows.count
            // Text and --from already matched in SQL; only privacy rules run here.
            let visible = rows.filter { !hiddenRow($0) }
            // Rows whose headers miss the query get a body scan, in parallel (about 3 ms each).
            var bodyHit = [Int: Bool]()
            if let t = q.text, q.body {
                let need = visible.filter { r in
                    !masked(r) && ![subject(r), r.str("address") ?? "", r.str("name") ?? "", r.str("summary") ?? ""]
                        .contains { $0.range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                }.prefix(max(0, 3000 - scanned))
                scanned += need.count
                let paths = need.map { r in (r.int("id") ?? 0, emlxPath(id: r.int("id") ?? 0, mailbox: r.int("mailbox"))) }
                var hits = [Bool](repeating: false, count: paths.count)
                hits.withUnsafeMutableBufferPointer { buf in
                    DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                        guard let p = paths[i].1, let d = FileManager.default.contents(atPath: p),
                              let body = MIMEText.parseEMLX(d, forSearch: true)?.text else { return }
                        buf[i] = body.range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                            && !self.isOneTimeCode(body)
                    }
                }
                for (i, x) in paths.enumerated() { bodyHit[x.0] = hits[i] }
            }
            for r in visible {
                let isCode = masked(r)
                if let t = q.text {
                    if isCode { continue }
                    // With --body, SQL kept header misses; keep them only if their body matched.
                    if q.body {
                        let hay = [subject(r), r.str("address") ?? "", r.str("name") ?? "", r.str("summary") ?? ""]
                        if !hay.contains(where: { $0.range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) != nil }),
                           bodyHit[r.int("id") ?? -1] != true { continue }
                    }
                }
                out.append(summary(r, masked: isCode))
                if out.count >= limit { break }
            }
        }
        return out
    }

    func read(_ id: String, maxChars: Int) throws -> MailMessage {
        guard let n = Int(id) else { throw AppleError.invalid("message id \(id) is not a number") }
        guard try !db.query("SELECT 1 FROM messages m WHERE m.ROWID = ? AND m.deleted = 0", [n]).isEmpty else { throw AppleError.notFound("message \(id)") }
        guard let r = try db.query("\(Self.select) WHERE m.ROWID = ? AND \(privacySQL)", [n]).first, !hiddenRow(r) else {
            throw AppleError.hidden("message \(id)")
        }
        let s = summary(r, masked: masked(r))
        var to: [String] = [], cc: [String] = []
        for x in try db.query("""
            SELECT a.address AS address, a.comment AS name, x.type AS type FROM recipients x JOIN addresses a ON a.ROWID = x.address
            WHERE x.message = ? ORDER BY x.type, x.position
            """, [n]) {
            let addr = x.str("address") ?? ""
            let label = x.str("name").flatMap { $0.isEmpty ? nil : "\($0) <\(addr)>" } ?? addr
            if x.int("type") == 1 { cc.append(label) } else { to.append(label) }
        }
        let parsed = loadBody(id: n, mailbox: r.int("mailbox"))
        var body = parsed?.text
        let codeHidden = s.preview == "[one-time code hidden]" || body.map(isOneTimeCode) == true
        if codeHidden { body = body == nil ? nil : "[one-time code hidden]" }
        let cap = max(0, maxChars)
        let truncated = (body?.count ?? 0) > cap
        if truncated { body = String(body!.prefix(cap)) }
        let dbNames = try db.query("SELECT name FROM attachments WHERE message = ? ORDER BY ROWID", [n]).compactMap { $0.str("name") }
        return MailMessage(id: s.id, subject: codeHidden ? "[one-time code hidden]" : s.subject, from: s.from, fromAddress: s.fromAddress, to: to, cc: cc, date: s.date,
                           account: s.account, mailbox: s.mailbox, unread: s.unread, flagged: s.flagged,
                           conversationId: r.int("conv"), attachments: dbNames.isEmpty ? (parsed?.attachments ?? []) : dbNames,
                           body: body, bodyAvailable: parsed != nil, truncated: truncated, preview: codeHidden ? "[one-time code hidden]" : s.preview)
    }

    /// Finds `<ROWID>.emlx` (or `.partial.emlx`) for a message. Mail stores it under
    /// `<account>/<path>.mbox/<store id>/Data/<digits of ROWID/1000, reversed>/Messages/`.
    func emlxPath(id: Int, mailbox: Int?) -> String? {
        guard let mailbox, let box = boxes[mailbox] else { return nil }
        let fm = FileManager.default
        let mbox = Self.root + "/" + box.accountID + "/" + box.path.split(separator: "/").map { $0 + ".mbox" }.joined(separator: "/")
        let k = id / 1000
        let sub = k == 0 ? "" : String(String(k).reversed()).map(String.init).joined(separator: "/") + "/"
        if storeDirs[mailbox] == nil { storeDirs[mailbox] = ((try? fm.contentsOfDirectory(atPath: mbox)) ?? []).filter { !$0.hasSuffix(".mbox") } }
        for store in storeDirs[mailbox] ?? [] {
            for name in ["\(id).emlx", "\(id).partial.emlx"] {
                let p = "\(mbox)/\(store)/Data/\(sub)Messages/\(name)"
                if fm.fileExists(atPath: p) { return p }
            }
        }
        return nil
    }

    func loadBody(id: Int, mailbox: Int?, forSearch: Bool = false) -> MIMEText? {
        guard let p = emlxPath(id: id, mailbox: mailbox), let data = FileManager.default.contents(atPath: p) else { return nil }
        return MIMEText.parseEMLX(data, forSearch: forSearch)
    }
}

// MARK: - MIME

/// Just enough MIME to get readable text out of an .emlx: multipart walking, base64 and
/// quoted-printable, charsets, and HTML reduced to text. Works in Latin-1 so bytes survive.
struct MIMEText {
    let text: String
    let attachments: [String]

    /// `forSearch` skips the HTML-to-text pass (the slow part); tags rarely contain a search term.
    static func parseEMLX(_ data: Data, forSearch: Bool = false) -> MIMEText? {
        // First line is the message length in bytes; a plist of Mail metadata follows the message.
        guard let nl = data.firstIndex(of: 0x0A), let n = Int(String(decoding: data[data.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)) else { return nil }
        let start = data.index(after: nl)
        let end = min(data.endIndex, start + max(0, n))
        let raw = String(data: data[start..<end], encoding: .isoLatin1) ?? ""
        var plain: String?, html: String?, files: [String] = []
        walk(raw, plain: &plain, html: &html, files: &files, depth: 0)
        // Some senders put HTML in the text/plain part.
        if let p = plain, p.range(of: #"(?i)<(html|body|div|table|p|br)\b"#, options: .regularExpression) != nil { html = p; plain = nil }
        if forSearch { return MIMEText(text: plain ?? html ?? "", attachments: files) }
        guard let t = plain ?? html.map(htmlToText) else { return MIMEText(text: "", attachments: files) }
        return MIMEText(text: tidy(t), attachments: files)
    }

    private static func split(_ s: String) -> (headers: [String: String], body: String) {
        let r1 = s.range(of: "\r\n\r\n"), r2 = s.range(of: "\n\n")
        let r = [r1, r2].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
        let head = r.map { String(s[..<$0.lowerBound]) } ?? s
        let body = r.map { String(s[$0.upperBound...]) } ?? ""
        var headers: [String: String] = [:]
        let unfolded = head.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: #"\n[ \t]+"#, with: " ", options: .regularExpression)
        for line in unfolded.split(separator: "\n") {
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = line[..<c].lowercased().trimmingCharacters(in: .whitespaces)
            if headers[k] == nil { headers[k] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces) }
        }
        return (headers, body)
    }

    private static func param(_ header: String?, _ name: String) -> String? {
        guard let h = header,
              let r = h.range(of: #"(?i)(^|;)\s*\#(name)\*?=\s*("[^"]*"|[^;]+)"#, options: .regularExpression) else { return nil }
        var v = String(h[r]); v = String(v[v.index(after: v.firstIndex(of: "=")!)...]).trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") { v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        if let q = v.range(of: "''") { v = String(v[q.upperBound...]).removingPercentEncoding ?? v }   // RFC 2231
        return v
    }

    private static func walk(_ part: String, plain: inout String?, html: inout String?, files: inout [String], depth: Int) {
        guard depth < 12 else { return }
        let (h, body) = split(part)
        let ctype = (h["content-type"] ?? "text/plain").lowercased()
        let disp = h["content-disposition"]?.lowercased() ?? ""
        if ctype.hasPrefix("multipart/"), let b = param(h["content-type"], "boundary") {
            for chunk in body.components(separatedBy: "--" + b).dropFirst() {
                if chunk.hasPrefix("--") { break }
                walk(String(chunk.drop { $0 == "\r" || $0 == "\n" }), plain: &plain, html: &html, files: &files, depth: depth + 1)
            }
            return
        }
        let fname = param(h["content-disposition"], "filename") ?? param(h["content-type"], "name")
        if disp.hasPrefix("attachment") || (fname != nil && !ctype.hasPrefix("text/")) {
            if let f = fname { files.append(decodeWords(f)) }
            return
        }
        guard ctype.hasPrefix("text/plain") || ctype.hasPrefix("text/html") else { return }
        let bytes = decodeTransfer(body, h["content-transfer-encoding"]?.lowercased() ?? "")
        let text = decodeCharset(bytes, param(h["content-type"], "charset"))
        if ctype.hasPrefix("text/plain") { if plain == nil { plain = text } } else if html == nil { html = text }
    }

    private static func decodeTransfer(_ body: String, _ enc: String) -> Data {
        if enc.contains("base64") {
            return Data(base64Encoded: body.filter { !$0.isWhitespace }, options: .ignoreUnknownCharacters) ?? Data()
        }
        let latin = body.data(using: .isoLatin1) ?? Data(body.utf8)
        guard enc.contains("quoted-printable") else { return latin }
        var out = Data(capacity: latin.count)
        var i = latin.startIndex
        func hex(_ b: UInt8) -> UInt8? {
            switch b { case 48...57: return b - 48; case 65...70: return b - 55; case 97...102: return b - 87; default: return nil }
        }
        while i < latin.endIndex {
            let b = latin[i]
            if b == 0x3D {   // "="
                let n1 = latin.index(after: i)
                if n1 < latin.endIndex, latin[n1] == 0x0A { i = latin.index(after: n1); continue }
                if n1 < latin.endIndex, latin[n1] == 0x0D {
                    let n2 = latin.index(after: n1)
                    i = n2 < latin.endIndex && latin[n2] == 0x0A ? latin.index(after: n2) : n2; continue
                }
                let n2 = n1 < latin.endIndex ? latin.index(after: n1) : n1
                if n2 < latin.endIndex, let hi = hex(latin[n1]), let lo = hex(latin[n2]) {
                    out.append(hi << 4 | lo); i = latin.index(after: n2); continue
                }
            }
            out.append(b); i = latin.index(after: i)
        }
        return out
    }

    private static func decodeCharset(_ d: Data, _ charset: String?) -> String {
        if let cs = charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            if cf != kCFStringEncodingInvalidId,
               let s = String(data: d, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) { return s }
        }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1252) ?? String(decoding: d, as: UTF8.self)
    }

    /// RFC 2047 encoded words in a filename.
    static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        var out = s
        let re = try! NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#)
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let all = Range(m.range, in: s), let cs = Range(m.range(at: 1), in: s), let e = Range(m.range(at: 2), in: s),
                  let t = Range(m.range(at: 3), in: s) else { continue }
            let payload = String(s[t])
            let data = s[e].lowercased() == "b" ? (Data(base64Encoded: payload) ?? Data())
                : decodeTransfer(payload.replacingOccurrences(of: "_", with: " "), "quoted-printable")
            if let r = Range(m.range, in: out), all == r { out.replaceSubrange(r, with: decodeCharset(data, String(s[cs]))) }
        }
        return out
    }

    static func htmlToText(_ h: String) -> String {
        var s = h
        for (p, r) in [(#"(?is)<(script|style|head)\b.*?</\1>"#, ""), (#"(?is)<!--.*?-->"#, ""),
                       (#"(?i)<br\s*/?>"#, "\n"), (#"(?i)</(p|div|tr|h[1-6]|li|table|blockquote)>"#, "\n"), (#"(?i)<li\b[^>]*>"#, "- "),
                       (#"(?s)<[^>]+>"#, "")] {
            s = s.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        for (e, c) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&zwnj;", ""), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: e, with: c)
        }
        let re = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: s), let x = Range(m.range(at: 1), in: s), let v = Range(m.range(at: 2), in: s),
                  let n = UInt32(s[v], radix: s[x].isEmpty ? 10 : 16), let u = Unicode.Scalar(n) else { continue }
            s.replaceSubrange(r, with: String(Character(u)))
        }
        return s
    }

    static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[ \t\u{00A0}\u{200C}\u{034F}]+\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Writing (Mail.app scripting, one message at a time by its Envelope Index ID)

/// Envelope Index ROWIDs are the IDs Mail's scripting uses, so every reference below is direct:
/// `«class mssg» id N of mailbox "path" of account id "UUID"`, never a `whose` search, which hangs.
/// The raw class code is needed because Mail also has a `message id` property (the Message-ID
/// header), and `message id N` does not compile.
struct MailChange: Encodable { let id: String; let ok: Bool; let detail: String }
struct MailChanges: Output {
    let action: String
    let results: [MailChange]
    var text: String { results.map { "\($0.ok ? "ok  " : "FAIL") \($0.id) \(action): \($0.detail)" }.joined(separator: "\n") }
}
struct SavedFiles: Output {
    let folder: String
    let saved: [String]
    var text: String { saved.isEmpty ? "no attachments saved" : "saved \(saved.count) file(s) to \(folder): " + saved.joined(separator: ", ") }
}

/// Over MCP, outgoing attachments must already be in the agent folder, so an agent cannot mail out arbitrary files.
func checkOutgoingFile(_ path: String, viaMCP: Bool) throws -> String {
    let real = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path
    guard FileManager.default.isReadableFile(atPath: real) else { throw AppleError.notFound("file \(path)") }
    if viaMCP {
        let root = URL(fileURLWithPath: PhotosWriter.agentRoot).resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard real.hasPrefix(root) else { throw AppleError.refused("over MCP, attachments must be inside \(PhotosWriter.agentRoot)") }
    }
    return real
}

final class MailWriter {
    let ctx: Context
    let store: MailStore
    init(_ ctx: Context) throws { self.ctx = ctx; store = try MailStore(ctx) }

    /// Account UUID, mailbox path, and ROWID for a visible message. Hidden or missing messages throw.
    func ref(_ id: String) throws -> (account: String, box: String, rowid: String, message: MailMessage) {
        let m = try store.read(id, maxChars: 4000)
        guard let n = Int(id), let boxID = try store.db.query("SELECT mailbox FROM messages WHERE ROWID = ?", [n]).first?.int("mailbox"),
              let box = store.boxes[boxID] else { throw AppleError.notFound("mailbox of message \(id)") }
        return (box.accountID, box.path, id, m)
    }

    func draft(_ a: Args) throws -> DraftOutput {
        let list = { (k: String) in a.list(k) }
        var to = list("to"), cc = list("cc")
        let bcc = list("bcc"), body = try a.require("body")
        var subject = a.string("subject") ?? ""
        var mode = "new", refParts: [String] = []
        var quoted: MailMessage?
        if let rid = a.string("reply-to") ?? a.string("forward") {
            let r = try ref(rid)
            // Mail.app quotes or forwards the real message, so a message apple-cli masks (a one-time code,
            // a sign-in or reset email) would leave with the very content the mask hides.
            if r.message.body == "[one-time code hidden]" || r.message.preview == "[one-time code hidden]" {
                throw AppleError.refused("message \(rid) is masked as a one-time code or sign-in email; it cannot be replied to or forwarded from apple-cli")
            }
            // Without the body, there is no way to know it holds no code, so the answer is no (fail closed).
            if store.settings.maskOneTimeCodes && !r.message.bodyAvailable {
                throw AppleError.refused("Mail has not downloaded message \(rid)'s body, so it cannot be checked for one-time codes. Open it in Mail once, then try again")
            }
            mode = a.string("forward") != nil ? "forward" : (a.bool("reply-all") ? "replyall" : "reply")
            quoted = r.message
            refParts = [r.account, r.box, r.rowid]
            let base = r.message.subject.replacingOccurrences(of: #"^(?i)(re|fwd?):\s*"#, with: "", options: .regularExpression)
            if subject.isEmpty { subject = (mode == "forward" ? "Fwd: " : "Re: ") + base }
            if mode != "forward" && to.isEmpty { to = [r.message.fromAddress ?? r.message.from] }
            if mode == "replyall" && cc.isEmpty { cc = (r.message.to + r.message.cc).filter { !$0.lowercased().contains((r.message.fromAddress ?? "~").lowercased()) } }
        }
        guard !to.isEmpty else { throw AppleError.invalid("no recipients; pass --to") }
        // Items travel to the script one per line, so a line break inside one could smuggle in another.
        for v in to + cc + bcc + list("attach") + [a.string("from") ?? "", subject] where v.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw AppleError.invalid("recipients, sender, subject, and attachment paths cannot contain line breaks or control characters")
        }
        let files = try list("attach").map { try checkOutgoingFile($0, viaMCP: a.viaMCP) }
        let from = a.string("from") ?? ""
        var lines = ["From: \(from.isEmpty ? "Mail's default account" : from)", "To: \(to.joined(separator: ", "))"]
        if !cc.isEmpty { lines.append("Cc: \(cc.joined(separator: ", "))") }
        if !bcc.isEmpty { lines.append("Bcc: \(bcc.joined(separator: ", "))") }
        lines.append("Subject: \(subject)")
        if mode != "new" { lines.append("\(mode == "forward" ? "Forwarding" : "Replying to") message \(refParts[2])") }
        if !files.isEmpty { lines.append("Attachments: " + files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")) }
        lines.append(""); lines.append(body)
        // What goes out also carries the original, so the review shows it.
        if let q = quoted {
            let excerpt = String((q.body ?? q.preview ?? "").prefix(1200))
            lines.append("")
            lines.append(mode == "forward" ? "--- Forwarded message (included in full) ---" : "--- Quoted original ---")
            lines.append("From: \(q.from)  Subject: \(q.subject)")
            if mode == "forward" && !q.attachments.isEmpty { lines.append("Forwarded attachments: \(q.attachments.joined(separator: ", "))") }
            lines.append(excerpt + ((q.body ?? "").count > 1200 ? "\n[...]" : ""))
        }
        let d = try Draft.save(kind: "mail", summary: lines.joined(separator: "\n"),
                               payload: ["mode": [mode], "ref": refParts, "from": [from], "to": to, "cc": cc, "bcc": bcc,
                                         "subject": [subject], "body": [body], "attach": files])
        Audit.write("mail draft", ["draft": d.id, "to": to.joined(separator: ", "), "mode": mode, "chars": body.count])
        return DraftOutput(d, sendWith: "apple-cli mail send \(d.id)")
    }

    func send(_ id: String, saveOnly: Bool) throws -> SendResult {
        saveOnly ? try sendNow(id, saveOnly: true) : try Audit.withSendSlot(ctx) { try sendNow(id, saveOnly: false) }
    }

    private func sendNow(_ id: String, saveOnly: Bool) throws -> SendResult {
        let d = try Draft.take(id, kind: "mail")
        let p = { (k: String) in d.payload[k] ?? [] }
        let ref = p("ref") + ["", "", ""]
        let script = """
            on splitLines(vT)
                if vT is "" then return {}
                set AppleScript's text item delimiters to linefeed
                set out to text items of vT
                set AppleScript's text item delimiters to ""
                return out
            end splitLines
            on run argv
                set {vMode, vAcct, vBoxPath, vRowid, vFromAddr, vToList, vCcList, vBccList, vSubj, vBodyText, vAttachList, vSaveOnly} to argv
                tell application "Mail"
                    -- Checked before any message exists, so a bad address leaves nothing behind. Some accounts
                    -- throw on reading their address list ("On My Mac", and Yahoo added through Internet Accounts),
                    -- so each read is tried on its own, and an account whose user name is the address counts too.
                    if vFromAddr is not "" then
                        set vKnown to false
                        repeat with a in accounts
                            try
                                if (user name of a as text) is vFromAddr then set vKnown to true
                            end try
                            try
                                repeat with e in (email addresses of a)
                                    if (e as text) is vFromAddr then set vKnown to true
                                end repeat
                            end try
                        end repeat
                        if not vKnown then error "not sent: no Mail account sends from " & vFromAddr
                    end if
                    if vMode is "new" then
                        set vMsg to make new outgoing message with properties {subject:vSubj, content:vBodyText, visible:false}
                    else
                        set vOrig to «class mssg» id (vRowid as integer) of mailbox vBoxPath of account id vAcct
                        if vMode is "forward" then
                            set vMsg to forward vOrig opening window false
                        else
                            set vMsg to reply vOrig opening window false reply to all (vMode is "replyall")
                        end if
                        set subject of vMsg to vSubj
                        set content of vMsg to vBodyText & return & return & (content of vMsg)
                        delete every to recipient of vMsg
                        delete every cc recipient of vMsg
                    end if
                    -- Anything that fails from here on closes the message unsaved, so Mail never files a
                    -- half-built copy in Drafts. "not sent:" tells the caller nothing left the Mac.
                    try
                    if vFromAddr is not "" then set sender of vMsg to vFromAddr
                    repeat with r in my splitLines(vToList)
                        make new to recipient at end of to recipients of vMsg with properties {address:(r as text)}
                    end repeat
                    repeat with r in my splitLines(vCcList)
                        make new cc recipient at end of cc recipients of vMsg with properties {address:(r as text)}
                    end repeat
                    repeat with r in my splitLines(vBccList)
                        make new bcc recipient at end of bcc recipients of vMsg with properties {address:(r as text)}
                    end repeat
                    repeat with f in my splitLines(vAttachList)
                        tell content of vMsg to make new attachment with properties {file name:(POSIX file (f as text))} at after last paragraph
                    end repeat
                    on error vErr
                        try
                            close vMsg saving no
                        end try
                        error "not sent: " & vErr
                    end try
                    if vSaveOnly is "1" then
                        save vMsg
                        close vMsg saving no
                    else
                        send vMsg
                    end if
                end tell
            end run
            """
        let to = p("to").joined(separator: ", ")
        let started = Date()
        do {
            _ = try Osascript.run(script, [p("mode").first ?? "new", ref[0], ref[1], ref[2], p("from").first ?? "",
                                           p("to").joined(separator: "\n"), p("cc").joined(separator: "\n"), p("bcc").joined(separator: "\n"),
                                           p("subject").first ?? "", p("body").first ?? "", p("attach").joined(separator: "\n"), saveOnly ? "1" : "0"],
                                  app: "Mail", timeout: 90)
        } catch {
            let e = AppleError.wrap(error)
            // Failed before Mail sent anything: the approved draft goes back, so it can be sent once fixed.
            let neverSent = e.description.contains("not sent: ")
            if neverSent { Draft.restore(d) }
            Audit.write(saveOnly ? "mail save" : "mail send", ["draft": id, "to": to, "status": "failed", "error": e.description, "draftKept": neverSent])
            throw neverSent ? AppleError.app(String(e.description[e.description.range(of: "not sent: ")!.upperBound...])
                                             + ". Nothing was sent; draft \(id) is kept") : error
        }
        if saveOnly {
            Audit.write("mail save", ["draft": id, "to": to, "status": "saved"])
            return SendResult(status: "saved", to: to, messageId: nil, detail: "in Mail's Drafts mailbox")
        }
        let result = confirmSent(subject: p("subject").first ?? "", since: started, to: to)
        Audit.write("mail send", ["draft": id, "to": to, "status": result.status, "chars": (p("body").first ?? "").count])
        return result
    }

    /// Mail files the sent copy into the account's Sent mailbox once the server takes it (Gmail: All Mail with
    /// the Sent label). Up to 45 seconds.
    private func confirmSent(subject: String, since: Date, to: String) -> SendResult {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            sleep(1)
            guard let s = try? MailStore(ctx) else { continue }
            let sent = s.boxes.values.filter { $0.path.lowercased().contains("sent") }.map(\.id)
            guard !sent.isEmpty, let r = try? s.db.query("""
                SELECT m.ROWID FROM messages m JOIN subjects su ON su.ROWID = m.subject
                WHERE (m.mailbox IN (\(sent.map(String.init).joined(separator: ",")))
                       OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(sent.map(String.init).joined(separator: ",")))))
                  AND m.date_received >= ? AND su.subject = ?
                ORDER BY m.ROWID DESC LIMIT 1
                """, [Int(since.timeIntervalSince1970) - 120,
                      subject.replacingOccurrences(of: #"^(?i)(re|fwd?):\s*"#, with: "", options: .regularExpression)]).first else { continue }
            return SendResult(status: "sent", to: to, messageId: r.int("ROWID").map(String.init), detail: nil)
        }
        return SendResult(status: "sending", to: to, messageId: nil, detail: "Mail accepted it; no copy in a Sent mailbox within 45 s. Check Mail's Outbox if it stays missing")
    }

    func modify(_ ids: [String], action: String, mailbox: String?) throws -> MailChanges {
        let actions = ["archive", "trash", "move", "read", "unread", "flag", "unflag"]
        guard actions.contains(action) else { throw AppleError.invalid("action must be one of \(actions.joined(separator: ", "))") }
        if action == "move" && (mailbox ?? "").isEmpty { throw AppleError.invalid("move needs --mailbox") }
        var out: [MailChange] = []
        for id in ids {
            do {
                let r = try ref(id)
                var target = mailbox ?? ""
                if action == "archive" {
                    let paths = store.boxes.values.filter { $0.accountID == r.account }.map(\.path)
                    guard let arch = ["Archive", "[Gmail]/All Mail", "Archives"].first(where: paths.contains) else {
                        throw AppleError.notFound("an Archive mailbox in this account")
                    }
                    target = arch
                }
                if action == "move" || action == "archive" {
                    guard store.boxes.values.contains(where: { $0.accountID == r.account && $0.path == target }) else {
                        throw AppleError.notFound("mailbox \(target) in this account")
                    }
                }
                _ = try Osascript.run("""
                    on run argv
                        set {vAct, vAcct, vBoxPath, vRowid, vDest} to argv
                        tell application "Mail"
                            set m to «class mssg» id (vRowid as integer) of mailbox vBoxPath of account id vAcct
                            if vAct is "read" then set read status of m to true
                            if vAct is "unread" then set read status of m to false
                            if vAct is "flag" then set flagged status of m to true
                            if vAct is "unflag" then set flagged status of m to false
                            if vAct is "move" or vAct is "archive" then move m to mailbox vDest of account id vAcct
                            if vAct is "trash" then delete m
                        end tell
                    end run
                    """, [action, r.account, r.box, r.rowid, target], app: "Mail", timeout: 30)
                out.append(MailChange(id: id, ok: true, detail: verify(id, action: action, from: r.box)))
                Audit.write("mail modify", ["id": id, "action": action, "mailbox": target, "status": "ok"])
            } catch {
                out.append(MailChange(id: id, ok: false, detail: AppleError.wrap(error).description))
                Audit.write("mail modify", ["id": id, "action": action, "status": "failed"])
            }
        }
        return MailChanges(action: action, results: out)
    }

    /// Reads the change back from Mail's index (it updates within a few seconds while Mail runs).
    private func verify(_ id: String, action: String, from box: String) -> String {
        for _ in 0..<10 {
            usleep(500_000)
            guard let s = try? MailStore(ctx), let n = Int(id) else { continue }
            guard let r = try? s.db.query("SELECT read, flagged, deleted, mailbox FROM messages WHERE ROWID = ?", [n]).first else {
                if ["move", "archive", "trash"].contains(action) { return "done (Mail gave it a new ID in the new mailbox)" }
                continue
            }
            switch action {
            case "read" where r.bool("read"), "unread" where !r.bool("read"), "flag" where r.bool("flagged"), "unflag" where !r.bool("flagged"):
                return "done, confirmed in Mail's index"
            case "move", "archive", "trash":
                if r.bool("deleted") || s.boxes[r.int("mailbox") ?? -1]?.path != box { return "done, confirmed in Mail's index" }
            default: break
            }
        }
        return "sent to Mail; not yet visible in its index"
    }

    func saveAttachments(_ id: String, to dir: URL) throws -> SavedFiles {
        let r = try ref(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = try Osascript.run("""
            on run argv
                set {vAcct, vBoxPath, vRowid, vDir} to argv
                set vSaved to {}
                tell application "Mail"
                    set m to «class mssg» id (vRowid as integer) of mailbox vBoxPath of account id vAcct
                    repeat with vAtt in (mail attachments of m)
                        set vN to name of vAtt
                        if vN does not start with "." and vN does not contain "/" and vN does not contain linefeed and vN does not contain return and vN does not contain ":" then
                            save vAtt in POSIX file (vDir & "/" & vN)
                            set end of vSaved to vN
                        end if
                    end repeat
                end tell
                set AppleScript's text item delimiters to linefeed
                return vSaved as text
            end run
            """, [r.account, r.box, r.rowid, dir.path], app: "Mail", timeout: 120)
        Audit.write("mail attachments", ["id": id, "folder": dir.path, "count": out.isEmpty ? 0 : out.split(separator: "\n").count])
        return SavedFiles(folder: dir.path, saved: out.isEmpty ? [] : out.split(separator: "\n").map(String.init))
    }
}
