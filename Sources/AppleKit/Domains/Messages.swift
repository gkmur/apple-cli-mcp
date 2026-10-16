import Foundation

// Messages: read-only. Reads ~/Library/Messages/chat.db, decodes attributedBody
// (NSArchiver typedstream) for messages with no plain text, and resolves handles
// to Contacts names. Sending is out of scope.

// MARK: - Domain

struct MessagesSettings: DomainSettings {
    static let key = "messages"
    /// Chats hidden everywhere: chat GUID, chat identifier, or group name.
    var excludeChats: [String]
    /// Phone numbers or emails whose chats are hidden everywhere.
    var excludeHandles: [String]
    /// Regexes matched against participants' contact names and group names.
    var excludeNamePatterns: [String]
    /// Replace one-time codes with a placeholder and leave them out of search.
    var maskOneTimeCodes: Bool
    var oneTimeCodePatterns: [String]

    static let defaults = MessagesSettings(
        excludeChats: [], excludeHandles: [], excludeNamePatterns: [], maskOneTimeCodes: true,
        oneTimeCodePatterns: [
            #"(?i)\b(verification|security|login|sign[- ]?in|one[- ]time|2fa|mfa|passcode|auth(entication)?|confirmation)\s+code\b"#,
            #"(?i)\bcode\b\D{0,25}\b\d{4,8}\b"#,
            #"(?i)\b\d{4,8}\b\D{0,30}\b(is your|code)\b"#,
        ])
}

let messagesDomain = Domain(name: "messages", defaults: MessagesSettings.defaults, commands: messagesCommands, checks: { ctx in
    let t = Date()
    do {
        let store = try MessagesStore(ctx, names: false)
        let chats = try store.chats()
        let (agree, compared, bodyOnly) = try store.decoderAgreement()
        let pct = compared == 0 ? 100.0 : Double(agree) / Double(compared) * 100
        return [
            Check(domain: "messages", name: "store", ok: true,
                  detail: "\(chats.visible.count) chats readable, \(chats.hidden) hidden, schema matches, \(Int(Date().timeIntervalSince(t) * 1000)) ms", fix: nil),
            Check(domain: "messages", name: "decoder", ok: pct >= 98,
                  detail: String(format: "attributedBody matches plain text on %.1f%% of %d recent messages; %d recent messages decode only from attributedBody", pct, compared, bodyOnly),
                  fix: pct >= 98 ? nil : "Apple may have changed the attributedBody format. Re-check the decoder against the plain text column."),
        ]
    } catch {
        let e = AppleError.wrap(error)
        return [Check(domain: "messages", name: "store", ok: false, detail: e.description,
                      fix: e.code == "permission" ? "System Settings > Privacy & Security > Full Disk Access: turn on AppleCLI" : nil)]
    }
})

// MARK: - Outputs

struct ChatInfo: Output {
    let id: String              // chat GUID
    let name: String
    let group: Bool
    let participants: [String]
    let service: String?
    let lastMessage: Date?
    let messages: Int
    let unread: Int
    var text: String {
        let when = lastMessage.map { String(localISO.string(from: $0).prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? ""
        return "\(when)  \(name)\(unread > 0 ? "  (\(unread) unread)" : "")  \(id)"
    }
}

struct ChatList: Output {
    let chats: [ChatInfo]
    let hidden: Int
    var text: String { chats.map(\.text).joined(separator: "\n") + (hidden > 0 ? "\n\(hidden) chat(s) hidden by privacy config" : "") }
}

struct AttachmentInfo: Encodable { let name: String?; let path: String?; let mimeType: String?; let bytes: Int? }
struct Reaction: Encodable { let reaction: String; let by: String }

struct MessageInfo: Encodable {
    let id: String              // message GUID
    let chatId: String
    let chat: String
    let date: Date?
    let fromMe: Bool
    let from: String
    let text: String?
    var attachments: [AttachmentInfo] = []
    var reactions: [Reaction] = []
    var replyTo: String? = nil
    var edited: Bool? = nil
    var unsent: Bool? = nil
    var event: String? = nil
    let service: String?

    var line: String {
        let when = date.map { String(localISO.string(from: $0).prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? ""
        var body = event.map { "(\($0))" } ?? (text ?? "")
        for a in attachments { body += (body.isEmpty ? "" : " ") + "[\(a.name ?? "attachment")]" }
        if unsent == true { body = "(unsent)" }
        var s = "\(when)  \(fromMe ? "me" : from): \(body)"
        if edited == true { s += "  (edited)" }
        if !reactions.isEmpty { s += "  " + reactions.map { "\($0.reaction) \($0.by)" }.joined(separator: ", ") }
        return s
    }
}

struct MessageThread: Output {
    let chat: ChatInfo
    let messages: [MessageInfo]
    var text: String { "\(chat.name)\n" + messages.map(\.line).joined(separator: "\n") }
}

struct MessageSearch: Output {
    let results: [MessageInfo]
    var text: String { results.map { "[\($0.chat)] " + $0.line }.joined(separator: "\n") }
}

struct UnreadChat: Encodable { let chat: ChatInfo; let messages: [MessageInfo] }
struct UnreadList: Output {
    let chats: [UnreadChat]
    var text: String {
        chats.isEmpty ? "no unread messages" :
            chats.map { "\($0.chat.name)\n" + $0.messages.map { "  " + $0.line }.joined(separator: "\n") }.joined(separator: "\n")
    }
}

struct CountRow: Encodable { let key: String; let messages: Int }
struct MessageStats: Output {
    let messages: Int
    let sent: Int
    let received: Int
    let chats: Int
    let first: Date?
    let last: Date?
    let byYear: [CountRow]
    let byService: [CountRow]
    let topChats: [CountRow]
    var text: String {
        var out = ["\(messages) messages (\(sent) sent, \(received) received) in \(chats) chats"]
        out.append("By year: " + byYear.map { "\($0.key) \($0.messages)" }.joined(separator: ", "))
        out.append("By service: " + byService.map { "\($0.key) \($0.messages)" }.joined(separator: ", "))
        out.append("Top chats:")
        out += topChats.map { "  \($0.messages)  \($0.key)" }
        return out.joined(separator: "\n")
    }
}

// MARK: - Commands

private func messagesCommands(_ ctx: Context) -> [Command] {
    let names = Param("no-names", .boolean, "Skip the Contacts name lookup (faster; shows phone numbers and emails)")
    return [
        Command(["messages", "chats"], .read, "Recent conversations with names, participants, last message time, and unread count.",
                [Param("limit", .integer, "Max (default 20)"), names]) { a in
            let store = try MessagesStore(ctx, names: !a.bool("no-names"))
            let all = try store.chats()
            return ChatList(chats: all.visible.prefix(a.int("limit", 20)).map(\.info), hidden: all.hidden)
        },
        Command(["messages", "read"], .read, "Read a conversation in order, with reactions, attachments, replies, and edits.",
                [Param("chat", required: true, positional: true, "Chat ID, group name, contact name, phone, or email"),
                 Param("limit", .integer, "Most recent N messages (default 50)"), Param("all", .boolean, "Every message (export)"),
                 Param("since", "Only after: YYYY-MM-DD, today, yesterday, 7d, 12h"), Param("before", "Only before: same forms"), names]) { a in
            let store = try MessagesStore(ctx, names: !a.bool("no-names"))
            let chat = try store.resolveChat(try a.require("chat"))
            let msgs = try store.messages(chats: [chat], since: try a.string("since").map(parseSince), before: try a.string("before").map(parseSince),
                                          limit: a.bool("all") ? nil : a.int("limit", 50))
            return MessageThread(chat: chat.info, messages: msgs)
        },
        Command(["messages", "search"], .read, "Search every message, including ones stored only in attributedBody. Newest first.",
                [Param("query", required: true, positional: true, "Text to find"), Param("chat", "Only this chat"),
                 Param("from", "Only from this contact name, phone, or email (use me for your own)"),
                 Param("since", "Only after: YYYY-MM-DD, today, yesterday, 7d, 12h"), Param("limit", .integer, "Max (default 20)"), names]) { a in
            let store = try MessagesStore(ctx, names: !a.bool("no-names"))
            return MessageSearch(results: try store.search(try a.require("query"), chat: a.string("chat"), from: a.string("from"),
                                                           since: try a.string("since").map(parseSince), limit: a.int("limit", 20)))
        },
        Command(["messages", "unread"], .read, "Incoming unread messages, grouped by chat.",
                [Param("since", "Only after: YYYY-MM-DD, today, yesterday, 7d, 12h"), names]) { a in
            let store = try MessagesStore(ctx, names: !a.bool("no-names"))
            return UnreadList(chats: try store.unread(since: try a.string("since").map(parseSince)))
        },
        Command(["messages", "stats"], .read, "Counts by year, service, and chat across visible history.", [names]) { a in
            try MessagesStore(ctx, names: !a.bool("no-names")).stats()
        },
        Command(["messages", "draft"], .write, "Draft a text for review. Nothing is sent until `messages send <draft-id>`; the draft is sent exactly as shown.",
                [Param("to", required: true, positional: true, "Chat ID, group name, contact name, phone, or email"),
                 Param("text", required: true, "The message text"), Param("file", "Path of a file to attach. Over MCP, it must be in ~/Downloads/apple-cli"),
                 Param("sms", .boolean, "Send as SMS through your iPhone, not iMessage (new recipients only)")]) { a in
            try MessageSender(ctx).draft(to: try a.require("to"), text: try a.require("text"),
                                         file: try a.string("file").map { try checkOutgoingFile($0, viaMCP: a.viaMCP) }, sms: a.bool("sms"))
        },
        Command(["messages", "send"], .write, "Send a drafted text, exactly as drafted, then confirm it reached Messages' outbox.",
                [Param("draft", required: true, positional: true, "Draft ID from messages draft")]) { a in
            try MessageSender(ctx).send(try a.require("draft"))
        },
    ]
}

/// Parses a past moment: "2026-10-01", "2026-10-01 09:00", "today", "yesterday", "7d", "12h", "30m" (ago).
func parseSince(_ s: String) throws -> Date {
    let t = s.trimmingCharacters(in: .whitespaces).lowercased()
    let cal = Calendar.current
    if t == "today" { return cal.startOfDay(for: Date()) }
    if t == "yesterday" { return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))! }
    if let m = t.range(of: #"^-?(\d{1,5})([mhd])$"#, options: .regularExpression) {
        let v = Int(t[m].filter(\.isNumber))!
        let unit: Calendar.Component = t.hasSuffix("m") ? .minute : t.hasSuffix("h") ? .hour : .day
        return cal.date(byAdding: unit, value: -v, to: Date())!
    }
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
    for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
        f.dateFormat = fmt
        if let d = f.date(from: t.uppercased()) { return d }
    }
    throw AppleError.invalid("date \(s). Use YYYY-MM-DD [HH:MM], today, yesterday, or 7d/12h/30m")
}

// MARK: - attributedBody

/// Pulls the string out of an NSArchiver typedstream: header, the NSString class entry,
/// then '+' (0x2B) and a length-prefixed UTF-8 payload. 0x81 and 0x82 mark 2- and 4-byte lengths.
/// Verified against the plain text column on this Mac.
func decodeAttributedBody(_ data: Data) -> String? {
    let b = [UInt8](data)
    let header: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8)
    guard b.count > header.count, Array(b[0..<header.count]) == header else { return nil }
    let marker = Array("NSString".utf8)
    guard let i = (0...(b.count - marker.count)).first(where: { Array(b[$0..<$0 + marker.count]) == marker }) else { return nil }
    let searchEnd = min(i + marker.count + 12, b.count)
    guard let j = (i + marker.count..<searchEnd).first(where: { b[$0] == 0x2B }), j + 1 < b.count else { return nil }
    var k = j + 1
    let n = Int(b[k])
    let len: Int
    switch n {
    case 0..<0x80: len = n; k += 1
    case 0x81: guard k + 3 <= b.count else { return nil }; len = Int(b[k + 1]) | Int(b[k + 2]) << 8; k += 3
    case 0x82: guard k + 5 <= b.count else { return nil }
        len = Int(b[k + 1]) | Int(b[k + 2]) << 8 | Int(b[k + 3]) << 16 | Int(b[k + 4]) << 24; k += 5
    default: return nil
    }
    guard len >= 0, len <= b.count - k else { return nil }
    return String(bytes: b[k..<k + len], encoding: .utf8)
}

// MARK: - Store

struct ChatRow {
    let rowid: Int
    let guid: String
    let identifier: String?
    let handles: [String]
    let info: ChatInfo
}

final class MessagesStore {
    static let path = NSHomeDirectory() + "/Library/Messages/chat.db"

    /// Every column this file reads. Checked on open (schema guard).
    static let schema: [String: [String]] = [
        "message": ["ROWID", "guid", "text", "attributedBody", "date", "is_from_me", "handle_id", "is_read", "service",
                    "associated_message_type", "associated_message_guid", "associated_message_emoji", "thread_originator_guid",
                    "date_edited", "date_retracted", "item_type", "group_title", "cache_has_attachments"],
        "chat": ["ROWID", "guid", "chat_identifier", "display_name", "style", "service_name"],
        "handle": ["ROWID", "id"],
        "chat_message_join": ["chat_id", "message_id"],
        "chat_handle_join": ["chat_id", "handle_id"],
        "message_attachment_join": ["message_id", "attachment_id"],
        "attachment": ["ROWID", "filename", "transfer_name", "mime_type", "total_bytes"],
    ]

    let db: SQLiteReader
    let settings: MessagesSettings
    let namePatterns: PrivacyFilter
    let codePatterns: PrivacyFilter
    let excludeChats: Set<String>
    let excludeHandles: Set<String>
    private var names: [String: String] = [:]
    private var hiddenHandles = Set<String>()
    private var chatCache: (visible: [ChatRow], hidden: Int)?

    init(_ ctx: Context, names wantNames: Bool) throws {
        db = try SQLiteReader(path: Self.path)
        try db.require(Self.schema)
        settings = try ctx.settings(MessagesSettings.self)
        namePatterns = try PrivacyFilter(titlePatterns: settings.excludeNamePatterns, containers: [], ids: [])
        codePatterns = try PrivacyFilter(titlePatterns: settings.oneTimeCodePatterns, containers: [], ids: [])
        excludeChats = Set(settings.excludeChats.map { $0.lowercased() })
        excludeHandles = Set(settings.excludeHandles.flatMap(handleKeys))

        // Contacts are read when names are wanted, or when any rule needs them. A privacy rule
        // that cannot be checked fails the command (fail closed); a name lookup that fails just
        // falls back to raw phone numbers and emails.
        let contactRules = try ContactsStore.hasPrivacyRules(ctx) || !settings.excludeNamePatterns.isEmpty
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

    // Dates are nanoseconds since 2001-01-01 (older stores used seconds).
    static func date(_ raw: Int?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw > 1_000_000_000_000 ? Double(raw) / 1e9 : Double(raw))
    }

    static func raw(_ d: Date) -> Int64 { Int64(d.timeIntervalSinceReferenceDate * 1e9) }

    func displayName(_ handle: String?) -> String {
        guard let h = handle, !h.isEmpty else { return "unknown" }
        return normalizeHandle(h).flatMap { names[$0] } ?? h
    }

    func hides(handle: String) -> Bool {
        let keys = handleKeys(handle)
        if keys.contains(where: { excludeHandles.contains($0) || hiddenHandles.contains($0) }) { return true }
        if let name = normalizeHandle(handle).flatMap({ names[$0] }), namePatterns.hidesTitle(name) { return true }
        return false
    }

    /// Chats that have messages, newest first, with hidden chats removed.
    func chats() throws -> (visible: [ChatRow], hidden: Int) {
        if let chatCache { return chatCache }
        var participants: [Int: [String]] = [:]
        for r in try db.query("SELECT j.chat_id, h.id FROM chat_handle_join j JOIN handle h ON h.ROWID = j.handle_id") {
            if let c = r.int("chat_id"), let h = r.str("id") { participants[c, default: []].append(h) }
        }
        // Everyone who ever sent a message in a chat, including people who have since left a group.
        // Privacy checks use this set, not only the current participants.
        var senders: [Int: Set<String>] = [:]
        for r in try db.query("""
            SELECT DISTINCT j.chat_id, h.id FROM chat_message_join j
            JOIN message m ON m.ROWID = j.message_id JOIN handle h ON h.ROWID = m.handle_id
            """) {
            if let c = r.int("chat_id"), let h = r.str("id") { senders[c, default: []].insert(h) }
        }
        let rows = try db.query("""
            SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.style, c.service_name,
                   MAX(m.date) AS LAST, COUNT(*) AS N,
                   SUM(m.is_read = 0 AND m.is_from_me = 0 AND m.item_type = 0 AND m.associated_message_type = 0) AS UNREAD
            FROM chat c
            JOIN chat_message_join j ON j.chat_id = c.ROWID
            JOIN message m ON m.ROWID = j.message_id
            GROUP BY c.ROWID ORDER BY LAST DESC
            """)
        var visible: [ChatRow] = [], hidden = 0
        for r in rows {
            let rowid = r.int("ROWID") ?? 0
            let guid = r.str("guid") ?? ""
            let ident = r.str("chat_identifier")
            let display = r.str("display_name").flatMap { $0.isEmpty ? nil : $0 }
            let handles = participants[rowid] ?? ident.map { [$0] } ?? []
            let blocked = [guid, ident, display].compactMap { $0?.lowercased() }.contains(where: excludeChats.contains)
                || handles.contains(where: hides)
                || (senders[rowid] ?? []).contains(where: hides)
                || display.map(namePatterns.hidesTitle) == true
            if blocked { hidden += 1; continue }
            let people = handles.map(displayName)
            let name = display ?? (people.isEmpty ? (ident ?? guid) : people.joined(separator: ", "))
            let info = ChatInfo(id: guid, name: name, group: r.int("style") == 43, participants: people,
                                service: r.str("service_name"), lastMessage: Self.date(r.int("LAST")),
                                messages: r.int("N") ?? 0, unread: r.int("UNREAD") ?? 0)
            visible.append(ChatRow(rowid: rowid, guid: guid, identifier: ident, handles: handles, info: info))
        }
        chatCache = (visible, hidden)
        return (visible, hidden)
    }

    /// Accepts a chat GUID, chat identifier, group name, contact name, phone, or email.
    /// A hidden chat gets the same not_found as one that does not exist.
    func resolveChat(_ ref: String) throws -> ChatRow {
        let all = try chats().visible
        let r = ref.lowercased()
        if let c = all.first(where: { $0.guid.lowercased() == r || $0.identifier?.lowercased() == r || String($0.rowid) == r }) { return c }
        var hits = all.filter { $0.info.name.lowercased() == r }
        if hits.isEmpty, let n = normalizeHandle(ref) {
            hits = all.filter { !$0.info.group && $0.handles.contains { normalizeHandle($0) == n } }
        }
        if hits.isEmpty { hits = all.filter { !$0.info.group && $0.info.name.lowercased().contains(r) } }
        guard !hits.isEmpty else { throw AppleError.notFound("chat \(ref)") }
        // One-to-one duplicates (iMessage and SMS threads with one person) are merged by taking the newest.
        let names = Set(hits.map(\.info.name))
        if names.count > 1 {
            throw AppleError.invalid("\(hits.count) chats match \(ref): " + hits.prefix(5).map { "\($0.info.name) (\($0.guid))" }.joined(separator: "; "))
        }
        return hits[0]
    }

    func isOneTimeCode(_ t: String) -> Bool {
        settings.maskOneTimeCodes && codePatterns.hidesTitle(t)
    }

    private func bodyText(_ r: [String: Any]) -> String? {
        let raw = r.str("text") ?? r.data("attributedBody").flatMap(decodeAttributedBody)
        guard let t = raw?.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return isOneTimeCode(t) ? "[one-time code hidden]" : t
    }

    private static let reactionNames: [Int: String] = [2000: "loved", 2001: "liked", 2002: "disliked", 2003: "laughed at",
                                                       2004: "emphasized", 2005: "questioned", 2006: "reacted"]

    /// Messages for some chats, oldest first within the window. Reactions fold into their target.
    func messages(chats: [ChatRow], since: Date?, before: Date?, limit: Int?) throws -> [MessageInfo] {
        guard !chats.isEmpty else { return [] }
        let ids = chats.map { String($0.rowid) }.joined(separator: ",")
        let byRow = Dictionary(chats.map { ($0.rowid, $0) }, uniquingKeysWith: { a, _ in a })
        var sql = """
            SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.is_from_me, h.id AS HANDLE, m.service,
                   m.thread_originator_guid, m.date_edited, m.date_retracted, m.item_type, m.group_title,
                   m.cache_has_attachments, j.chat_id
            FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE j.chat_id IN (\(ids)) AND m.associated_message_type = 0
            """
        var params: [Any] = []
        if let since { sql += " AND m.date >= ?"; params.append(Self.raw(since)) }
        if let before { sql += " AND m.date < ?"; params.append(Self.raw(before)) }
        sql += " ORDER BY m.date DESC"
        if let limit { sql += " LIMIT \(max(1, limit))" }
        let rows = try db.query(sql, params).reversed()
        return try build(Array(rows), chats: byRow)
    }

    private func build(_ allRows: [[String: Any]], chats byRow: [Int: ChatRow]) throws -> [MessageInfo] {
        // Backstop: drop any row sent by a hidden person, even inside a chat that is otherwise visible.
        let rows = allRows.filter { r in r.bool("is_from_me") || !hides(handle: r.str("HANDLE") ?? "") }
        guard !rows.isEmpty else { return [] }
        let guids = rows.compactMap { $0.str("guid") }
        // Attachments for these messages.
        var atts: [Int: [AttachmentInfo]] = [:]
        let withAtts = rows.filter { $0.bool("cache_has_attachments") }.compactMap { $0.int("ROWID") }
        if !withAtts.isEmpty {
            for a in try db.query("""
                SELECT j.message_id, a.filename, a.transfer_name, a.mime_type, a.total_bytes
                FROM message_attachment_join j JOIN attachment a ON a.ROWID = j.attachment_id
                WHERE j.message_id IN (\(withAtts.map(String.init).joined(separator: ",")))
                """) {
                guard let mid = a.int("message_id") else { continue }
                let path = a.str("filename").map { ($0 as NSString).expandingTildeInPath }
                atts[mid, default: []].append(AttachmentInfo(name: a.str("transfer_name") ?? path.map { ($0 as NSString).lastPathComponent },
                                                             path: path, mimeType: a.str("mime_type"), bytes: a.int("total_bytes")))
            }
        }
        // Reactions that target these messages, applied in time order so removals (3000+) cancel adds.
        var reactions: [String: [(String, String)]] = [:]
        if !guids.isEmpty {
            let likes = guids.map { _ in "m.associated_message_guid LIKE ?" }.joined(separator: " OR ")
            for r in try db.query("""
                SELECT m.associated_message_guid AS T, m.associated_message_type AS K, m.associated_message_emoji AS E,
                       m.is_from_me, h.id AS HANDLE
                FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
                WHERE m.associated_message_type BETWEEN 2000 AND 3006 AND (\(likes)) ORDER BY m.date
                """, guids.map { "%" + $0 }) {
                guard let target = r.str("T")?.components(separatedBy: "/").last, let k = r.int("K") else { continue }
                if !r.bool("is_from_me"), hides(handle: r.str("HANDLE") ?? "") { continue }
                let by = r.bool("is_from_me") ? "me" : displayName(r.str("HANDLE"))
                let base = k >= 3000 ? k - 1000 : k
                let label = base == 2006 ? (r.str("E") ?? "reacted") : (Self.reactionNames[base] ?? "reacted")
                if k >= 3000 { reactions[target]?.removeAll { $0.1 == by && $0.0 == label } }
                else { reactions[target, default: []].append((label, by)) }
            }
        }
        return rows.map { r in
            let rowid = r.int("ROWID") ?? 0
            let guid = r.str("guid") ?? ""
            let chat = r.int("chat_id").flatMap { byRow[$0] }
            let fromMe = r.bool("is_from_me")
            let itemType = r.int("item_type") ?? 0
            var m = MessageInfo(id: guid, chatId: chat?.guid ?? "", chat: chat?.info.name ?? "", date: Self.date(r.int("date")),
                                fromMe: fromMe, from: fromMe ? "me" : displayName(r.str("HANDLE")),
                                text: itemType == 0 ? bodyText(r) : nil, service: r.str("service"))
            m.attachments = atts[rowid] ?? []
            m.reactions = (reactions[guid] ?? []).map { Reaction(reaction: $0.0, by: $0.1) }
            m.replyTo = r.str("thread_originator_guid")
            if (r.int("date_edited") ?? 0) > 0 { m.edited = true }
            if (r.int("date_retracted") ?? 0) > 0 { m.unsent = true }
            if itemType != 0 {
                m.event = r.str("group_title").map { "renamed the group to \($0)" } ?? "group change"
            }
            return m
        }
    }

    func search(_ query: String, chat: String?, from: String?, since: Date?, limit: Int) throws -> [MessageInfo] {
        let scope = try chat.map { [try resolveChat($0)] } ?? chats().visible
        guard !scope.isEmpty else { return [] }
        let byRow = Dictionary(scope.map { ($0.rowid, $0) }, uniquingKeysWith: { a, _ in a })
        var sql = """
            SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.is_from_me, h.id AS HANDLE, m.service,
                   m.thread_originator_guid, m.date_edited, m.date_retracted, m.item_type, m.group_title,
                   m.cache_has_attachments, j.chat_id
            FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE j.chat_id IN (\(scope.map { String($0.rowid) }.joined(separator: ","))) AND m.associated_message_type = 0 AND m.item_type = 0
            """
        var params: [Any] = []
        if let since { sql += " AND m.date >= ?"; params.append(Self.raw(since)) }
        sql += " ORDER BY m.date DESC"
        let fromNorm = from.flatMap { $0.lowercased() == "me" ? nil : normalizeHandle($0) }
        let fromName = from?.lowercased()
        var hits: [[String: Any]] = []
        for r in try db.query(sql, params) {
            if !r.bool("is_from_me"), hides(handle: r.str("HANDLE") ?? "") { continue }
            if let from {
                if from.lowercased() == "me" { if !r.bool("is_from_me") { continue } }
                else {
                    if r.bool("is_from_me") { continue }
                    let h = r.str("HANDLE") ?? ""
                    let ok = (fromNorm != nil && normalizeHandle(h) == fromNorm) || displayName(h).lowercased().contains(fromName ?? "")
                    if !ok { continue }
                }
            }
            guard let raw = r.str("text") ?? r.data("attributedBody").flatMap(decodeAttributedBody),
                  raw.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                  !isOneTimeCode(raw) else { continue }
            hits.append(r)
            if hits.count >= limit { break }
        }
        return try build(hits, chats: byRow)
    }

    func unread(since: Date?) throws -> [UnreadChat] {
        try chats().visible.filter { $0.info.unread > 0 }.compactMap { c in
            var sql = """
                SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.is_from_me, h.id AS HANDLE, m.service,
                       m.thread_originator_guid, m.date_edited, m.date_retracted, m.item_type, m.group_title,
                       m.cache_has_attachments, j.chat_id
                FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id LEFT JOIN handle h ON h.ROWID = m.handle_id
                WHERE j.chat_id = ? AND m.is_read = 0 AND m.is_from_me = 0 AND m.item_type = 0 AND m.associated_message_type = 0
                """
            var params: [Any] = [c.rowid]
            if let since { sql += " AND m.date >= ?"; params.append(Self.raw(since)) }
            let msgs = try build(try db.query(sql + " ORDER BY m.date", params), chats: [c.rowid: c])
            return msgs.isEmpty ? nil : UnreadChat(chat: c.info, messages: msgs)
        }
    }

    func stats() throws -> MessageStats {
        let visible = try chats().visible
        let ids = visible.map { String($0.rowid) }.joined(separator: ",")
        guard !ids.isEmpty else {
            return MessageStats(messages: 0, sent: 0, received: 0, chats: 0, first: nil, last: nil, byYear: [], byService: [], topChats: [])
        }
        let base = "FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id WHERE j.chat_id IN (\(ids)) AND m.associated_message_type = 0 AND m.item_type = 0"
        let t = try db.query("SELECT COUNT(*) AS N, SUM(m.is_from_me) AS S, MIN(m.date) AS A, MAX(m.date) AS B \(base)").first ?? [:]
        var years: [String: Int] = [:]
        for r in try db.query("SELECT m.date \(base)") {
            if let d = Self.date(r.int("date")) { years[String(Calendar.current.component(.year, from: d)), default: 0] += 1 }
        }
        let services = try db.query("SELECT IFNULL(m.service, 'unknown') AS K, COUNT(*) AS N \(base) GROUP BY K ORDER BY N DESC")
            .map { CountRow(key: $0.str("K") ?? "", messages: $0.int("N") ?? 0) }
        let n = t.int("N") ?? 0, sent = t.int("S") ?? 0
        return MessageStats(messages: n, sent: sent, received: n - sent, chats: visible.count,
                            first: Self.date(t.int("A")), last: Self.date(t.int("B")),
                            byYear: years.sorted { $0.key < $1.key }.map { CountRow(key: $0.key, messages: $0.value) },
                            byService: services,
                            topChats: visible.sorted { $0.info.messages > $1.info.messages }.prefix(10).map { CountRow(key: $0.info.name, messages: $0.info.messages) })
    }

    /// Doctor self-test: decode the 1,000 most recent attributedBody blobs and compare with plain text.
    func decoderAgreement() throws -> (agree: Int, compared: Int, bodyOnly: Int) {
        var agree = 0, compared = 0, bodyOnly = 0
        for r in try db.query("SELECT text, attributedBody FROM message WHERE attributedBody IS NOT NULL AND associated_message_type = 0 ORDER BY date DESC LIMIT 1000") {
            let decoded = r.data("attributedBody").flatMap(decodeAttributedBody)
            guard let text = r.str("text") else { if decoded != nil { bodyOnly += 1 }; continue }
            compared += 1
            if decoded?.replacingOccurrences(of: "\u{FFFC}", with: "") == text.replacingOccurrences(of: "\u{FFFC}", with: "") { agree += 1 }
        }
        return (agree, compared, bodyOnly)
    }
}

// MARK: - Sending (Messages.app scripting, by chat ID or one participant)

struct SendResult: Output {
    /// sent, delivered, sending (not confirmed yet), or failed
    let status: String
    let to: String
    let messageId: String?
    let detail: String?
    var text: String { "\(status): \(to)" + (detail.map { " (\($0))" } ?? "") }
}

final class MessageSender {
    let ctx: Context
    init(_ ctx: Context) { self.ctx = ctx }

    func draft(to: String, text: String, file: String?, sms: Bool) throws -> DraftOutput {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || file != nil else { throw AppleError.invalid("empty message") }
        if (to + (file ?? "")).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw AppleError.invalid("recipient and file path cannot contain line breaks or control characters")
        }
        let store = try MessagesStore(ctx, names: true)
        var payload: [String: [String]] = ["text": [text], "file": file.map { [$0] } ?? []]
        let label: String
        // An existing chat (a group, or a person you have texted) is used as is; privacy-hidden chats never resolve.
        if let chat = try? store.resolveChat(to) {
            payload["chat"] = [chat.guid]
            label = "\(chat.info.name) (\(chat.handles.joined(separator: ", ")), \(chat.info.service ?? "iMessage"))"
        } else {
            let handle: String
            if to.contains("@") || to.filter(\.isNumber).count >= 7 {
                handle = to.trimmingCharacters(in: .whitespaces)
            } else {
                let hits = try ContactsStore(ctx).search(to).map { contactInfo($0) }
                guard hits.count == 1 else {
                    throw hits.isEmpty ? AppleError.notFound("no chat or contact named \(to)")
                        : AppleError.invalid("\(hits.count) contacts match \(to): " + hits.prefix(5).map(\.name).joined(separator: "; "))
                }
                guard let h = hits[0].phones.first?.value ?? hits[0].emails.first?.value else { throw AppleError.notFound("a phone or email for \(hits[0].name)") }
                handle = h
            }
            if store.hides(handle: handle) { throw AppleError.hidden(to) }
            payload["handle"] = [handle]
            payload["service"] = [sms ? "SMS" : "iMessage"]
            label = "\(store.displayName(handle)) (\(handle), new chat, \(sms ? "SMS" : "iMessage"))"
        }
        let summary = "To: \(label)\n" + (file.map { "Attachment: \(($0 as NSString).lastPathComponent)\n" } ?? "") + "Text: \(text)"
        let d = try Draft.save(kind: "message", summary: summary, payload: payload)
        Audit.write("messages draft", ["draft": d.id, "to": label, "chars": text.count])
        return DraftOutput(d, sendWith: "apple-cli messages send \(d.id)")
    }

    func send(_ id: String) throws -> SendResult {
        try Audit.withSendSlot(ctx) { try sendNow(id) }
    }

    private func sendNow(_ id: String) throws -> SendResult {
        let d = try Draft.take(id, kind: "message")
        let text = d.payload["text"]?.first ?? "", file = d.payload["file"]?.first
        let to = d.summary.split(separator: "\n").first.map { String($0.dropFirst(4)) } ?? "?"
        let started = Date()
        // The text and target travel as argv, never spliced into the script.
        let script = """
            on run argv
                set {refKind, destID, svcName, msgText, filePath} to argv
                tell application "Messages"
                    if refKind is "chat" then
                        set dest to chat id destID
                    else
                        if svcName is "SMS" then
                            set svc to first account whose service type is SMS
                        else
                            set svc to first account whose service type is iMessage
                        end if
                        set dest to participant destID of svc
                    end if
                    if msgText is not "" then send msgText to dest
                    if filePath is not "" then send (POSIX file filePath) to dest
                end tell
            end run
            """
        let target = d.payload["chat"]?.first ?? d.payload["handle"]?.first ?? ""
        do {
            _ = try Osascript.run(script, [d.payload["chat"] != nil ? "chat" : "participant", target, d.payload["service"]?.first ?? "iMessage",
                                           text, file ?? ""], app: "Messages", timeout: 30)
        } catch {
            Audit.write("messages send", ["draft": id, "to": to, "status": "failed", "error": AppleError.wrap(error).description])
            throw error
        }
        let result = confirm(target: target, isChat: d.payload["chat"] != nil, text: text, since: started, to: to)
        Audit.write("messages send", ["draft": id, "to": to, "status": result.status, "chars": text.count])
        return result
    }

    /// How Messages names a one-person chat: an email as is, a phone number as +digits (+1 added to a
    /// 10-digit US number), so "(555) 010-0199" finds the chat "+15550100199".
    static func chatIdentifier(_ handle: String) -> String {
        if handle.contains("@") { return handle.lowercased() }
        let digits = handle.filter(\.isNumber)
        return digits.count == 10 && !handle.hasPrefix("+") ? "+1" + digits : "+" + digits
    }

    /// Watches chat.db for the outgoing row for up to 15 seconds and reports what Messages did with it.
    private func confirm(target: String, isChat: Bool, text: String, since: Date, to: String) -> SendResult {
        let deadline = Date().addingTimeInterval(15)
        var last: [String: Any]?
        while Date() < deadline {
            usleep(500_000)
            guard let db = try? SQLiteReader(path: MessagesStore.path) else { continue }
            let rows = (try? db.query("""
                SELECT m.guid, m.text, m.is_sent, m.is_delivered, m.error FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID JOIN chat c ON c.ROWID = j.chat_id
                WHERE m.is_from_me = 1 AND m.date >= ? AND (c.guid = ? OR c.chat_identifier = ?)
                ORDER BY m.date DESC LIMIT 5
                """, [MessagesStore.raw(since.addingTimeInterval(-2)), target, isChat ? target : Self.chatIdentifier(target)])) ?? []
            // Only this send's row counts. A file-only send has no text to match, so it takes the newest row.
            guard let r = text.isEmpty ? rows.first : rows.first(where: { ($0.str("text") ?? "") == text }) else { continue }
            last = r
            if (r.int("error") ?? 0) != 0 { return SendResult(status: "failed", to: to, messageId: r.str("guid"), detail: "Messages error \(r.int("error")!)") }
            if r.bool("is_delivered") { return SendResult(status: "delivered", to: to, messageId: r.str("guid"), detail: nil) }
            if r.bool("is_sent") { return SendResult(status: "sent", to: to, messageId: r.str("guid"), detail: nil) }
        }
        return SendResult(status: "sending", to: to, messageId: last?.str("guid"),
                          detail: last == nil ? "Messages accepted it but it has not appeared in chat.db yet" : "not confirmed sent within 15 s")
    }
}
