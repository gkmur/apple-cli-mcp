import Contacts
import CoreServices
import EventKit
import Foundation

// Commands that read several apps at once: one person everywhere, today's brief, one search across
// apps, and the permission checklist. Each app's part fails on its own, so one missing permission
// still returns everything else, with the failure listed under `errors`.

let acrossDomain = Domain(name: "across", defaults: nil, commands: acrossCommands, checks: { _ in [] })

/// Runs one app's part of a combined command. A failure is recorded and the command carries on.
/// An app whose store does not exist on this Mac (never set up or synced here) is skipped without an error.
private func part<T>(_ app: String, _ errors: inout [String: String], _ body: () async throws -> T) async -> T? {
    do { return try await body() } catch {
        if case .notFound(let what) = AppleError.wrap(error), what.hasPrefix("database ") { return nil }
        errors[app] = AppleError.wrap(error).description
        return nil
    }
}

private func stamp(_ d: Date?) -> String {
    d.map { String(localISO.string(from: $0).prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? ""
}

private func errorLines(_ errors: [String: String]) -> String {
    errors.isEmpty ? "" : "\n\n" + errors.sorted { $0.key < $1.key }.map { "\($0.key) unavailable: \($0.value)" }.joined(separator: "\n")
}

// MARK: - Outputs

struct PersonReport: Output {
    let contact: ContactInfo
    /// Newest message, email, or call with them.
    let lastContact: Date?
    let messages: [MessageInfo]
    let mail: [MailSummary]
    let calls: [CallInfo]
    let events: [EventInfo]
    let errors: [String: String]
    var text: String {
        var s = contact.name + (contact.organization.map { "  (\($0))" } ?? "")
        let handles = contact.phones.map(\.value) + contact.emails.map(\.value)
        if !handles.isEmpty { s += "\n" + handles.joined(separator: ", ") }
        s += "\nlast contact: " + (lastContact.map(stamp) ?? "none found")
        s += "\n\nmessages\n" + (messages.isEmpty ? "  none" : messages.map { "  " + $0.line }.joined(separator: "\n"))
        s += "\n\nmail from them\n" + (mail.isEmpty ? "  none" : mail.map { "  " + $0.line }.joined(separator: "\n"))
        s += "\n\ncalls\n" + (calls.isEmpty ? "  none" : calls.map { "  " + $0.line }.joined(separator: "\n"))
        s += "\n\nevents with them\n" + (events.isEmpty ? "  none" : events.map { "  " + $0.line }.joined(separator: "\n"))
        return s + errorLines(errors)
    }
}

struct TodayReport: Output {
    let events: [EventInfo]
    let reminders: [ReminderInfo]
    let unreadMessages: [UnreadChat]
    let missedCalls: [CallInfo]
    let unreadMail: [MailSummary]
    let mailIndexedThrough: Date?
    let warnings: [String]
    let errors: [String: String]
    var text: String {
        var s = "calendar\n" + (events.isEmpty ? "  nothing today" : events.map { "  " + $0.line }.joined(separator: "\n"))
        s += "\n\nreminders due\n" + (reminders.isEmpty ? "  none" : reminders.map { "  " + $0.text }.joined(separator: "\n"))
        s += "\n\nunread texts\n" + (unreadMessages.isEmpty ? "  none" : unreadMessages.map { c in
            "  \(c.chat.name)\n" + c.messages.suffix(3).map { "    " + $0.line }.joined(separator: "\n")
        }.joined(separator: "\n"))
        s += "\n\nmissed calls\n" + (missedCalls.isEmpty ? "  none" : missedCalls.map { "  " + $0.line }.joined(separator: "\n"))
        s += "\n\nunread mail\n" + (unreadMail.isEmpty ? "  none" : unreadMail.map { "  " + $0.line }.joined(separator: "\n"))
        if !warnings.isEmpty { s += "\n\n" + warnings.map { "warning: " + $0 }.joined(separator: "\n") }
        return s + errorLines(errors)
    }
}

struct SearchHit: Encodable {
    let app: String
    let date: Date?
    let title: String
    let snippet: String?
    /// Pass to that app's read command (chat ID for messages, URL for safari).
    let id: String?
    var line: String {
        "\(stamp(date))  [\(app)]  \(title)" + (snippet.map { "\n      \($0)" } ?? "")
    }
}

struct SearchResults: Output {
    let query: String
    let results: [SearchHit]
    let errors: [String: String]
    var text: String { (results.isEmpty ? "no matches for \(query)" : results.map(\.line).joined(separator: "\n")) + errorLines(errors) }
}

struct PermissionRow: Encodable {
    let name: String
    /// granted, not_asked, denied, or missing.
    let status: String
    let fix: String?
}

struct PermissionReport: Output {
    let app: String
    let permissions: [PermissionRow]
    var text: String {
        "permissions held by \(app)\n" + permissions.map {
            "  \($0.status == "granted" ? "ok  " : "TODO") \($0.name): \($0.status)" + ($0.fix.map { "\n       \($0)" } ?? "")
        }.joined(separator: "\n")
    }
}

// MARK: - Commands

let searchApps = ["messages", "mail", "notes", "safari", "voicememos"]

private func acrossCommands(_ ctx: Context) -> [Command] {[
    Command(["person"], .read, "One person across apps: contact card, recent texts, mail from them, calls, and shared events, plus when you were last in touch.",
            [Param("who", required: true, positional: true, "Contact name, contact ID, phone, or email"),
             Param("limit", .integer, "Max items per app (default 10)")]) { a in
        try await person(ctx, try a.require("who"), limit: a.int("limit", 10))
    },
    Command(["today"], .read, "Today's brief: calendar, reminders due or overdue, unread texts (7 days), missed calls (24 hours), and unread mail (2 days).") { _ in
        await today(ctx)
    },
    Command(["search"], .read, "Search Messages, Mail, Notes, Safari history, and Voice Memos at once, newest first.",
            [Param("query", required: true, positional: true, "Text to find"),
             Param("apps", "Only these apps, comma-separated: " + searchApps.joined(separator: ", ")),
             Param("limit", .integer, "Max results overall (default 30)")]) { a in
        let apps = a.list("apps").isEmpty ? searchApps : a.list("apps").map { $0.lowercased() }
        if let bad = apps.first(where: { !searchApps.contains($0) }) { throw AppleError.invalid("unknown app \(bad); use \(searchApps.joined(separator: ", "))") }
        return await search(ctx, try a.require("query"), apps: apps, limit: a.int("limit", 30))
    },
    Command(["permissions"], .read, "Which macOS permissions apple-cli itself holds. --request shows every prompt not yet answered and opens the Full Disk Access pane if it is missing.",
            [Param("request", .boolean, "Ask for each permission not yet granted")]) { a in
        await permissions(request: a.bool("request"))
    },
]}

// MARK: - person

private func person(_ ctx: Context, _ who: String, limit: Int) async throws -> PersonReport {
    let contacts = try ContactsStore(ctx)
    let contact: ContactInfo
    if let byID = try? contacts.contact(who) {
        contact = contactInfo(byID)
    } else {
        let hits = try contacts.search(who).map { contactInfo($0) }
        let exact = hits.filter { $0.name.lowercased() == who.lowercased() }
        if exact.count == 1 { contact = exact[0] } else if hits.count == 1 { contact = hits[0] } else if hits.isEmpty {
            throw AppleError.notFound("contact \(who)")
        } else {
            throw AppleError.invalid("\(hits.count) contacts match \(who): "
                                     + hits.prefix(6).map { "\($0.name) (\($0.id))" }.joined(separator: "; ") + ". Use the full name or the contact ID")
        }
    }
    let emails = contact.emails.map { $0.value.lowercased() }
    let rawHandles = contact.phones.map(\.value) + contact.emails.map(\.value)
    let handles = Set(rawHandles.compactMap(normalizeHandle))
    var errors: [String: String] = [:]

    let messages = await part("messages", &errors) { () -> [MessageInfo] in
        let ms = try MessagesStore(ctx, names: true)
        let chats = try ms.chats().visible.filter { c in !c.info.group && c.handles.contains { normalizeHandle($0).map(handles.contains) ?? false } }
        return try ms.messages(chats: chats, since: nil, before: nil, limit: limit)
    } ?? []

    let mail = await part("mail", &errors) { () -> [MailSummary] in
        guard !emails.isEmpty else { return [] }
        let s = try MailStore(ctx)
        var seen = Set<String>(), out: [MailSummary] = []
        for e in emails {
            for m in try s.find(MailQuery(text: nil, from: e, mailbox: nil, account: nil, since: nil, unread: false, flagged: false, body: false), limit: limit)
            where seen.insert(m.id).inserted { out.append(m) }
        }
        return Array(out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(limit))
    } ?? []

    let calls = await part("calls", &errors) { () -> [CallInfo] in
        let s = try CallsStore(ctx, names: true)
        var seen = Set<String>(), out: [CallInfo] = []
        for h in rawHandles {
            for c in try s.calls(since: nil, missedOnly: false, who: h, limit: limit) where seen.insert(c.id).inserted { out.append(c) }
        }
        return Array(out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(limit))
    } ?? []

    // Attendees carry a display name or an email. A name match needs the full name, so a first name alone never matches.
    let events = await part("calendar", &errors) { () -> [EventInfo] in
        let name = contact.name.lowercased()
        let all = try await CalendarStore(ctx).events(from: Date().addingTimeInterval(-90 * 86400), to: Date().addingTimeInterval(30 * 86400), calendar: nil)
        let mine = all.filter { e in
            e.attendees.contains { att in
                let l = att.lowercased()
                return l == name || emails.contains(l)
            }
        }
        return Array(mine.suffix(limit))
    } ?? []

    let last = (messages.compactMap(\.date) + mail.compactMap(\.date) + calls.compactMap(\.date)).max()
    return PersonReport(contact: contact, lastContact: last, messages: messages, mail: mail, calls: calls, events: events, errors: errors)
}

// MARK: - today

private func today(_ ctx: Context) async -> TodayReport {
    var errors: [String: String] = [:]
    let start = Calendar.current.startOfDay(for: Date())
    let events = await part("calendar", &errors) {
        try await CalendarStore(ctx).events(from: start, to: start.addingTimeInterval(86400), calendar: nil)
    } ?? []
    let reminders = await part("reminders", &errors) { try RemindersStore(ctx).dueToday() } ?? []
    let unread = await part("messages", &errors) {
        try MessagesStore(ctx, names: true).unread(since: Date().addingTimeInterval(-7 * 86400))
    } ?? []
    let missed = await part("calls", &errors) {
        try CallsStore(ctx, names: true).calls(since: Date().addingTimeInterval(-86400), missedOnly: true, who: nil, limit: 20)
    } ?? []
    var newest: Date?
    let mail = await part("mail", &errors) { () -> [MailSummary] in
        let s = try MailStore(ctx)
        newest = try s.newest()
        return try s.find(MailQuery(text: nil, from: nil, mailbox: nil, account: nil, since: Date().addingTimeInterval(-2 * 86400),
                                    unread: true, flagged: false, body: false), limit: 20)
    } ?? []
    return TodayReport(events: events, reminders: reminders, unreadMessages: unread, missedCalls: missed, unreadMail: mail,
                       mailIndexedThrough: newest, warnings: [mailStaleWarning(newest)].compactMap { $0 }, errors: errors)
}

// MARK: - search

private func search(_ ctx: Context, _ q: String, apps: [String], limit: Int) async -> SearchResults {
    var errors: [String: String] = [:]
    var hits: [SearchHit] = []
    if apps.contains("messages") {
        hits += await part("messages", &errors) {
            try MessagesStore(ctx, names: true).search(q, chat: nil, from: nil, since: nil, limit: limit).map {
                SearchHit(app: "messages", date: $0.date, title: $0.chat, snippet: "\($0.fromMe ? "me" : $0.from): \($0.text ?? "")", id: $0.chatId)
            }
        } ?? []
    }
    if apps.contains("mail") {
        hits += await part("mail", &errors) {
            try MailStore(ctx).find(MailQuery(text: q, from: nil, mailbox: nil, account: nil, since: nil, unread: false, flagged: false, body: false),
                                    limit: limit).map {
                SearchHit(app: "mail", date: $0.date, title: $0.subject, snippet: $0.from + ($0.preview.map { ": " + $0 } ?? ""), id: $0.id)
            }
        } ?? []
    }
    if apps.contains("notes") {
        hits += await part("notes", &errors) {
            try searchNotes(ctx, q, limit: limit).results.map {
                SearchHit(app: "notes", date: $0.modified, title: $0.title ?? "(untitled)", snippet: $0.match, id: $0.id)
            }
        } ?? []
    }
    if apps.contains("safari") {
        hits += await part("safari", &errors) {
            try SafariStore(ctx).visits(query: q, domain: nil, since: Date().addingTimeInterval(-365 * 86400), limit: limit).map {
                SearchHit(app: "safari", date: $0.time, title: $0.title ?? $0.domain, snippet: $0.url, id: $0.url)
            }
        } ?? []
    }
    if apps.contains("voicememos") {
        hits += await part("voicememos", &errors) {
            try VoiceMemosStore(ctx).search(q, limit: limit).map {
                SearchHit(app: "voicememos", date: $0.date, title: $0.title, snippet: nil, id: $0.id)
            }
        } ?? []
    }
    hits.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    return SearchResults(query: q, results: Array(hits.prefix(limit)), errors: errors)
}

// MARK: - permissions

private func permissions(request: Bool) async -> PermissionReport {
    var rows: [PermissionRow] = []
    let bundle = OwnApp.bundlePath ?? "apple-cli"

    // Full Disk Access cannot be asked for. Opening a store file is the only real test; ls succeeds without it.
    let home = NSHomeDirectory()
    let stores = ["/Library/Messages/chat.db", "/Library/Safari/History.db", "/Library/Application Support/CallHistoryDB/CallHistory.storedata"]
        .map { home + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
    let fda = stores.isEmpty || stores.allSatisfy { (try? SQLiteReader(path: $0, allowCopy: false).query("SELECT 1")) != nil }
    if !fda && request {
        _ = try? runProcess("/usr/bin/open", ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"], timeout: 10, what: "System Settings")
        _ = try? runProcess("/usr/bin/open", ["-R", bundle], timeout: 10, what: "Finder")
    }
    rows.append(PermissionRow(name: "full disk access", status: fda ? "granted" : "missing",
                              fix: fda ? nil : "System Settings > Privacy & Security > Full Disk Access: add \(bundle) and turn it on"))

    var contacts = CNContactStore.authorizationStatus(for: .contacts)
    if request && contacts == .notDetermined {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        contacts = CNContactStore.authorizationStatus(for: .contacts)
    }
    rows.append(row("contacts", contacts == .authorized ? "granted" : contacts == .notDetermined ? "not_asked" : "denied", pane: "Contacts"))

    for (name, type) in [("calendars", EKEntityType.event), ("reminders", EKEntityType.reminder)] {
        var st = EKEventStore.authorizationStatus(for: type)
        if request && st == .notDetermined {
            let store = EKEventStore()
            _ = try? await (type == .event ? store.requestFullAccessToEvents() : store.requestFullAccessToReminders())
            st = EKEventStore.authorizationStatus(for: type)
        }
        rows.append(row(name, st == .fullAccess ? "granted" : st == .notDetermined ? "not_asked" : "denied", pane: name.capitalized))
    }

    let photos = (try? await PhotoAccess.check(request: request))?.status ?? "unknown"
    rows.append(row("photos", photos == "authorized" ? "granted" : photos == "not_determined" ? "not_asked" : photos, pane: "Photos"))

    for (name, id) in [("automation: Notes", "com.apple.Notes"), ("automation: Music", "com.apple.Music"), ("automation: Messages", "com.apple.MobileSMS"),
                       ("automation: Mail", "com.apple.mail"), ("automation: Safari", "com.apple.Safari")] {
        rows.append(row(name, automation(id, request: request), pane: "Automation"))
    }
    return PermissionReport(app: bundle, permissions: rows)
}

private func row(_ name: String, _ status: String, pane: String) -> PermissionRow {
    PermissionRow(name: name, status: status, fix: status == "granted" ? nil
                  : status == "not_asked" ? "run apple-cli permissions --request in a logged-in session"
                  : status == "prompt_waiting" ? "a permission prompt for AppleCLI is on this Mac's screen; answer it"
                  : "System Settings > Privacy & Security > \(pane): turn on AppleCLI")
}

/// Apple Events permission for one app. Asking needs the app running, so a request launches it hidden first.
private func automation(_ bundleID: String, request: Bool) -> String {
    let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
    // While any AppleCLI prompt is on screen, macOS holds every other permission check until it is answered.
    // A plain check gives up after 5 seconds instead of hanging; a request waits for the click.
    func check() -> OSStatus {
        if request { return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true) }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var st = OSStatus(errAEEventWouldRequireUserConsent)
        DispatchQueue.global().async { st = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false); done.signal() }
        return done.wait(timeout: .now() + 5) == .success ? st : OSStatus(1)  // 1: still waiting on a prompt
    }
    var st = check()
    if st == OSStatus(procNotFound) && request {
        _ = try? runProcess("/usr/bin/open", ["-gj", "-b", bundleID], timeout: 15, what: bundleID)
        let deadline = Date().addingTimeInterval(120)  // a cold Notes can take a minute to load its iCloud store
        while st == OSStatus(procNotFound) && Date() < deadline { usleep(500_000); st = check() }
    }
    switch st {
    case noErr: return "granted"
    case OSStatus(errAEEventWouldRequireUserConsent): return "not_asked"
    case OSStatus(errAEEventNotPermitted): return "denied"
    case OSStatus(procNotFound): return "not_asked"
    case 1: return "prompt_waiting"
    default: return "unknown (\(st))"
    }
}
