import Foundation
import EventKit

// Reminders: reads from the per-account Data-*.sqlite stores, writes through EventKit
// (EventKit -> remindd -> CloudKit).

// MARK: - Domain

struct RemindersSettings: DomainSettings {
    static let key = "reminders"
    var defaultList: String
    /// Time used when `add` gets a date with no time, or no date at all (then: tomorrow).
    var defaultTime: String
    /// List names hidden everywhere.
    var excludeLists: [String]?

    static let defaults = RemindersSettings(defaultList: "Reminders", defaultTime: "09:00", excludeLists: [])
}

let remindersDomain = Domain(name: "reminders", defaults: RemindersSettings.defaults, commands: remindersCommands, checks: { ctx in
    var out: [Check] = []
    let t = Date()
    do {
        let store = try RemindersStore(ctx)
        let rows = try store.all(includeCompleted: false)
        out.append(Check(domain: "reminders", name: "stores", ok: true,
                         detail: "\(store.storePaths().count) account stores, \(rows.count) open reminders, schema matches, \(Int(Date().timeIntervalSince(t) * 1000)) ms", fix: nil))
    } catch {
        let e = AppleError.wrap(error)
        out.append(Check(domain: "reminders", name: "stores", ok: false, detail: e.description,
                         fix: e.code == "permission" ? "System Settings > Privacy & Security > Full Disk Access: turn on AppleCLI" : nil))
    }
    let status = EKEventStore.authorizationStatus(for: .reminder)
    let ok = status == .fullAccess
    out.append(Check(domain: "reminders", name: "eventkit", ok: ok || status == .notDetermined,
                     detail: ok ? "full access granted" : status == .notDetermined ? "not asked yet. The first write prompts." : "access is \(status.rawValue)",
                     fix: ok || status == .notDetermined ? nil : "System Settings > Privacy & Security > Reminders"))
    return out
})

// MARK: - Outputs

struct ReminderInfo: Output {
    let id: String            // ZCKIDENTIFIER, equal to EventKit calendarItemIdentifier
    let title: String
    let notes: String?
    let list: String
    let completed: Bool
    let completedAt: Date?
    let due: String?          // ISO time, or YYYY-MM-DD for all-day
    let allDay: Bool
    let flagged: Bool
    let priority: Int
    let parentId: String?
    let created: Date?
    let synced: Bool          // CloudKit returned a server record for this row
    var alarms: [String] = []
    var recurrence: String? = nil
    var tags: [String] = []
    var overdue: Bool? = nil
    var remindAt: Date? = nil

    var text: String {
        if let remindAt { return "added \(title) for \(localISO.string(from: remindAt)) [\(list)]  \(id)" }
        var line = (completed ? "[x] " : "[ ] ") + title
        if let due { line += "  due \(due)" }
        if overdue == true { line += " (overdue)" }
        if flagged { line += "  flagged" }
        return line + "  [\(list)]  \(id)"
    }
}

struct ReminderList: Output {
    let reminders: [ReminderInfo]
    var text: String { reminders.map(\.text).joined(separator: "\n") }
}

struct ReminderAck: Output {
    let id: String
    let title: String?
    var completed: Bool? = nil
    var deleted: Bool? = nil
    var text: String { deleted == true ? "deleted \(id)" : "completed \(title ?? id)" }
}

// MARK: - Commands

private func remindersCommands(_ ctx: Context) -> [Command] {[
    Command(["reminders", "list"], .read, "List open reminders (all lists, or one).",
            [Param("list", "List name"), Param("completed", .boolean, "Include completed"), Param("limit", .integer, "Max (default 100)")]) { a in
        let l = a.string("list")?.lowercased()
        let rows = try RemindersStore(ctx).all(includeCompleted: a.bool("completed"))
            .filter { l == nil || $0.list.lowercased() == l }.prefix(a.int("limit", 100))
        return ReminderList(reminders: Array(rows))
    },
    Command(["reminders", "due-today"], .read, "Open reminders due today, plus overdue ones.") { _ in
        ReminderList(reminders: try RemindersStore(ctx).dueToday())
    },
    Command(["reminders", "add"], .write, "Add a reminder with a remind-me date (due date plus alarm).",
            [Param("title", required: true, positional: true, "Reminder title"),
             Param("at", "When: YYYY-MM-DD [HH:MM], today|tomorrow [HH:MM], +30m/+2h/+1d (default: tomorrow at the default time)"),
             Param("list", "List name (default from config: Reminders)"), Param("notes", "Notes text"),
             Param("priority", .integer, "0 none, 1 high, 5 medium, 9 low")]) { a in
        let s = try ctx.settings(RemindersSettings.self)
        let list = a.string("list") ?? s.defaultList
        if (s.excludeLists ?? []).contains(where: { $0.lowercased() == list.lowercased() }) { throw AppleError.hidden("list \(list)") }
        let at = try parseWhen(a.string("at"), defaultTime: s.defaultTime)
        let r = try await RemindersWriter().add(title: try a.require("title"), list: list, at: at,
                                                notes: a.string("notes"), priority: a.intIfPresent("priority"))
        let ek = r.calendarItemIdentifier
        var info = try waitFor(3) { try RemindersStore(ctx).find(ek) }
            ?? ReminderInfo(id: ek, title: r.title ?? "", notes: r.notes, list: r.calendar.title, completed: false, completedAt: nil,
                            due: localISO.string(from: at), allDay: false, flagged: false, priority: r.priority, parentId: nil,
                            created: Date(), synced: false)
        info.remindAt = at
        return info
    },
    Command(["reminders", "complete"], .write, "Mark a reminder done.",
            [Param("id", required: true, positional: true, "Reminder ID")]) { a in
        let id = try a.require("id")
        try RemindersStore(ctx).checkVisible(id)
        let r = try await RemindersWriter().complete(id)
        return ReminderAck(id: id, title: r.title, completed: true)
    },
    Command(["reminders", "update"], .write, "Change a reminder's title, notes, priority, or list. Use move to change when it is due.",
            [Param("id", required: true, positional: true, "Reminder ID"), Param("title", "New title"), Param("notes", "New notes (empty string clears)"),
             Param("priority", .integer, "0 none, 1 high, 5 medium, 9 low"), Param("list", "Move to this list")]) { a in
        let id = try a.require("id")
        try RemindersStore(ctx).checkVisible(id)
        let s = try ctx.settings(RemindersSettings.self)
        if let l = a.string("list"), (s.excludeLists ?? []).contains(where: { $0.lowercased() == l.lowercased() }) { throw AppleError.hidden("list \(l)") }
        let w = try await RemindersWriter()
        let r = try w.update(id, title: a.string("title"), notes: a.raw["notes"] as? String, priority: a.intIfPresent("priority"), list: a.string("list"))
        Audit.write("reminders update", ["id": id, "status": "ok"])
        return Done(id: id, action: "updated \(r.title ?? "")")
    },
    Command(["reminders", "uncomplete"], .write, "Mark a completed reminder as not done.",
            [Param("id", required: true, positional: true, "Reminder ID")]) { a in
        let id = try a.require("id")
        try RemindersStore(ctx).checkVisible(id)
        let r = try await RemindersWriter().setCompleted(id, false)
        Audit.write("reminders uncomplete", ["id": id, "status": "ok"])
        return Done(id: id, action: "marked not done: \(r.title ?? "")")
    },
    Command(["reminders", "move"], .write, "Change when a reminder is due. The due date and its alarm both move.",
            [Param("id", required: true, positional: true, "Reminder ID"),
             Param("at", required: true, "When: YYYY-MM-DD [HH:MM], today|tomorrow [HH:MM], +30m/+2h/+1d")]) { a in
        let id = try a.require("id")
        try RemindersStore(ctx).checkVisible(id)
        let at = try parseWhen(a.string("at"), defaultTime: try ctx.settings(RemindersSettings.self).defaultTime)
        let r = try await RemindersWriter().move(id, to: at)
        var info = try waitFor(3) { try RemindersStore(ctx).find(id).flatMap { $0.due == localISO.string(from: at) ? $0 : nil } }
            ?? ReminderInfo(id: id, title: r.title ?? "", notes: r.notes, list: r.calendar.title, completed: r.isCompleted, completedAt: nil,
                            due: localISO.string(from: at), allDay: false, flagged: false, priority: r.priority, parentId: nil,
                            created: r.creationDate ?? Date(), synced: false)
        info.remindAt = at
        return info
    },
    Command(["reminders", "delete"], .destructive, "Delete a reminder (it goes to Recently Deleted in Reminders).",
            [Param("id", required: true, positional: true, "Reminder ID")]) { a in
        let id = try a.require("id")
        try RemindersStore(ctx).checkVisible(id)
        try await RemindersWriter().delete(id)
        return ReminderAck(id: id, title: nil, deleted: true)
    },
]}

// MARK: - Fast read path (Data-*.sqlite, read-only, one file per account)

final class RemindersStore {
    static let storesDir = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores"

    /// Every column this file reads. Checked on open (schema guard).
    static let schema: [String: [String]] = [
        "ZREMCDREMINDER": ["Z_PK", "ZCKIDENTIFIER", "ZTITLE", "ZNOTES", "ZCOMPLETED", "ZCOMPLETIONDATE", "ZDUEDATE", "ZALLDAY",
                           "ZFLAGGED", "ZPRIORITY", "ZPARENTREMINDER", "ZCREATIONDATE", "ZCKSERVERRECORDDATA", "ZLIST", "ZMARKEDFORDELETION"],
        "ZREMCDBASELIST": ["Z_PK", "ZNAME", "ZMARKEDFORDELETION"],
        "ZREMCDOBJECT": ["Z_PK", "Z_ENT", "ZREMINDER", "ZALARM", "ZDATECOMPONENTSDATA", "ZREMINDER3", "ZREMINDER4", "ZNAME1",
                         "ZFREQUENCY", "ZINTERVAL", "ZMARKEDFORDELETION"],
        "Z_PRIMARYKEY": ["Z_ENT", "Z_NAME"],
    ]

    let excludeLists: Set<String>

    init(_ ctx: Context) throws {
        excludeLists = Set((try ctx.settings(RemindersSettings.self).excludeLists ?? []).map { $0.lowercased() })
    }

    func storePaths() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.storesDir)) ?? []
        return files.filter { $0.hasPrefix("Data-") && $0.hasSuffix(".sqlite") }.sorted().map { Self.storesDir + "/" + $0 }
    }

    /// Every live reminder across every account store, minus hidden lists.
    func all(includeCompleted: Bool) throws -> [ReminderInfo] {
        var out: [ReminderInfo] = []
        for p in storePaths() {
            let db = try SQLiteReader(path: p)
            try db.require(Self.schema)
            var ent: [String: Int] = [:]
            for r in try db.query("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY") { ent[r.str("Z_NAME") ?? ""] = r.int("Z_ENT") }
            let rows = try db.query("""
                SELECT r.Z_PK, r.ZCKIDENTIFIER, r.ZTITLE, r.ZNOTES, r.ZCOMPLETED, r.ZCOMPLETIONDATE, r.ZDUEDATE,
                       r.ZALLDAY, r.ZFLAGGED, r.ZPRIORITY, p.ZCKIDENTIFIER AS PARENT, r.ZCREATIONDATE,
                       r.ZCKSERVERRECORDDATA IS NOT NULL AS SYNCED, l.ZNAME AS LIST
                FROM ZREMCDREMINDER r
                JOIN ZREMCDBASELIST l ON l.Z_PK = r.ZLIST
                LEFT JOIN ZREMCDREMINDER p ON p.Z_PK = r.ZPARENTREMINDER
                WHERE IFNULL(r.ZMARKEDFORDELETION,0) = 0 AND IFNULL(l.ZMARKEDFORDELETION,0) = 0
                  AND (? = 1 OR r.ZCOMPLETED = 0)
                """, [includeCompleted ? 1 : 0])
            if rows.isEmpty { continue }

            // Alarms: alarm row -> date trigger row with a JSON date-components payload.
            var alarms: [Int: [String]] = [:]
            for a in try db.query("""
                SELECT a.ZREMINDER, t.ZDATECOMPONENTSDATA FROM ZREMCDOBJECT a
                JOIN ZREMCDOBJECT t ON t.ZALARM = a.Z_PK AND t.Z_ENT = ?
                WHERE a.Z_ENT = ? AND IFNULL(a.ZMARKEDFORDELETION,0) = 0
                """, [ent["REMCDAlarmDateTrigger"] ?? -1, ent["REMCDAlarm"] ?? -1]) {
                guard let rk = a.int("ZREMINDER"), let d = a.data("ZDATECOMPONENTSDATA"),
                      let comps = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                alarms[rk, default: []].append(Self.componentsString(comps))
            }
            var recur: [Int: String] = [:]
            for r in try db.query("SELECT ZREMINDER4, ZFREQUENCY, ZINTERVAL FROM ZREMCDOBJECT WHERE Z_ENT = ? AND IFNULL(ZMARKEDFORDELETION,0) = 0",
                                  [ent["REMCDRecurrenceRule"] ?? -1]) {
                guard let rk = r.int("ZREMINDER4") else { continue }
                let unit = ["day", "week", "month", "year"][min(max(r.int("ZFREQUENCY") ?? 0, 0), 3)]
                let n = r.int("ZINTERVAL") ?? 1
                recur[rk] = n == 1 ? "every \(unit)" : "every \(n) \(unit)s"
            }
            var tags: [Int: [String]] = [:]
            for t in try db.query("SELECT ZREMINDER3, ZNAME1 FROM ZREMCDOBJECT WHERE Z_ENT = ? AND IFNULL(ZMARKEDFORDELETION,0) = 0",
                                  [ent["REMCDHashtag"] ?? -1]) {
                if let rk = t.int("ZREMINDER3"), let n = t.str("ZNAME1") { tags[rk, default: []].append(n) }
            }

            for r in rows {
                guard let id = r.str("ZCKIDENTIFIER") else { continue }
                let list = r.str("LIST") ?? ""
                if excludeLists.contains(list.lowercased()) { continue }
                let pk = r.int("Z_PK") ?? 0
                let allDay = r.bool("ZALLDAY")
                out.append(ReminderInfo(
                    id: id, title: r.str("ZTITLE") ?? "", notes: r.str("ZNOTES"), list: list,
                    completed: r.bool("ZCOMPLETED"), completedAt: r.date("ZCOMPLETIONDATE"),
                    due: r.date("ZDUEDATE").map { Self.dueString($0, allDay: allDay) }, allDay: allDay,
                    flagged: r.bool("ZFLAGGED"), priority: r.int("ZPRIORITY") ?? 0, parentId: r.str("PARENT"),
                    created: r.date("ZCREATIONDATE"), synced: r.bool("SYNCED"),
                    alarms: alarms[pk] ?? [], recurrence: recur[pk], tags: tags[pk] ?? []))
            }
        }
        return out.sorted { ($0.due ?? "~", $0.title) < ($1.due ?? "~", $1.title) }
    }

    func find(_ id: String) throws -> ReminderInfo? { try all(includeCompleted: true).first { $0.id == id } }

    /// Writes check this first, so a hidden list's reminders cannot be changed by ID either.
    func checkVisible(_ id: String) throws {
        guard try excludeLists.isEmpty || find(id) != nil else { throw AppleError.hidden("reminder \(id)") }
    }

    /// Incomplete reminders due today or earlier. Earlier ones are marked overdue.
    func dueToday(now: Date = Date()) throws -> [ReminderInfo] {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: now)
        return try all(includeCompleted: false).compactMap { r in
            guard let due = r.due else { return nil }
            // All-day dues are YYYY-MM-DD. Timed dues are local ISO, so their first 10 chars are the local date.
            let day = String(due.prefix(10))
            guard day <= today else { return nil }
            var x = r
            x.overdue = day < today
            return x
        }
    }

    /// All-day dates are stored at UTC midnight, so they print as a plain date.
    static func dueString(_ d: Date, allDay: Bool) -> String {
        if allDay {
            let f = DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
            return f.string(from: d)
        }
        return localISO.string(from: d)
    }

    static func componentsString(_ c: [String: Any]) -> String {
        func n(_ k: String) -> Int? { (c[k] as? NSNumber)?.intValue }
        guard let y = n("year"), let mo = n("month"), let d = n("day") else { return "relative" }
        var s = String(format: "%04d-%02d-%02d", y, mo, d)
        if let h = n("hour") { s += String(format: " %02d:%02d", h, n("minute") ?? 0) }
        return s
    }
}

// MARK: - Write path (EventKit -> remindd -> CloudKit)

final class RemindersWriter {
    let store = EKEventStore()

    init() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized: return
        case .denied, .restricted, .writeOnly:
            throw AppleError.permission("allow Reminders for this app in System Settings > Privacy & Security > Reminders")
        default:
            let ok = try await store.requestFullAccessToReminders()
            if !ok { throw AppleError.permission("Reminders access was not granted") }
        }
    }

    func calendar(named name: String) throws -> EKCalendar {
        let all = store.calendars(for: .reminder).filter { $0.title.compare(name, options: .caseInsensitive) == .orderedSame }
        // Prefer the iCloud copy when a local list shares the name.
        if let c = all.first(where: { $0.source.title == "iCloud" }) ?? all.first { return c }
        throw AppleError.notFound("reminders list \(name)")
    }

    /// Adds a reminder with a due date plus an alarm at that moment ("remind me" date).
    func add(title: String, list: String, at: Date, notes: String?, priority: Int?) throws -> EKReminder {
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = try calendar(named: list)
        r.notes = notes
        if let priority { r.priority = priority }
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        comps.timeZone = TimeZone.current
        r.dueDateComponents = comps
        r.addAlarm(EKAlarm(absoluteDate: at))
        try withDeadline(10, "saving the reminder") { try self.store.save(r, commit: true) }
        return r
    }

    /// Resolves an ID from the read path (CloudKit record name) or an EventKit identifier.
    func reminder(_ id: String) throws -> EKReminder {
        if let r = store.calendarItem(withIdentifier: id) as? EKReminder { return r }
        if let r = store.calendarItems(withExternalIdentifier: id).compactMap({ $0 as? EKReminder }).first { return r }
        throw AppleError.notFound("reminder \(id)")
    }

    func update(_ id: String, title: String?, notes: String?, priority: Int?, list: String?) throws -> EKReminder {
        let r = try reminder(id)
        if let title { r.title = title }
        if let notes { r.notes = notes.isEmpty ? nil : notes }
        if let priority { r.priority = priority }
        if let list { r.calendar = try calendar(named: list) }
        try withDeadline(10, "saving the reminder") { try self.store.save(r, commit: true) }
        return r
    }

    func setCompleted(_ id: String, _ done: Bool) throws -> EKReminder {
        let r = try reminder(id)
        r.isCompleted = done
        try withDeadline(10, "saving the reminder") { try self.store.save(r, commit: true) }
        return r
    }

    func complete(_ id: String) throws -> EKReminder {
        let r = try reminder(id)
        r.isCompleted = true
        try withDeadline(10, "saving the reminder") { try self.store.save(r, commit: true) }
        return r
    }

    /// Moves the due date and replaces the alarms with one at the new moment, the same shape add makes.
    func move(_ id: String, to at: Date) throws -> EKReminder {
        let r = try reminder(id)
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        comps.timeZone = TimeZone.current
        r.dueDateComponents = comps
        r.alarms = [EKAlarm(absoluteDate: at)]
        try withDeadline(10, "saving the reminder") { try self.store.save(r, commit: true) }
        return r
    }

    func delete(_ id: String) throws {
        let r = try reminder(id)
        try withDeadline(10, "deleting the reminder") { try self.store.remove(r, commit: true) }
    }
}

/// Parses `--at`: "2026-10-16 09:00", "2026-10-16T09:00", "2026-10-16", "today 17:00",
/// "tomorrow", "tomorrow 8:30", "+30m", "+2h", "+1d". A bare date takes `defaultTime`.
func parseWhen(_ s: String?, defaultTime: String, now: Date = Date()) throws -> Date {
    let cal = Calendar.current
    func at(_ day: Date, _ hm: String) throws -> Date {
        let parts = hm.split(separator: ":").map { Int($0) }
        guard parts.count == 2, let h = parts[0], let m = parts[1], (0..<24).contains(h), (0..<60).contains(m) else {
            throw AppleError.invalid("time \(hm), use HH:MM")
        }
        return cal.date(bySettingHour: h, minute: m, second: 0, of: day)!
    }
    let t = (s ?? "tomorrow").trimmingCharacters(in: .whitespaces).lowercased()
    if let m = t.range(of: #"^\+(\d{1,5})([mhd])$"#, options: .regularExpression) {
        let v = Int(t[m].dropFirst().dropLast())!
        let unit: Calendar.Component = t.hasSuffix("m") ? .minute : t.hasSuffix("h") ? .hour : .day
        // Drop seconds so the due time and the alarm land on the same minute.
        let d = cal.date(byAdding: unit, value: v, to: now)!
        return cal.date(from: cal.dateComponents([.year, .month, .day, .hour, .minute], from: d))!
    }
    let words = t.split(separator: " ").map(String.init)
    if let w = words.first, w == "today" || w == "tomorrow" {
        let day = w == "today" ? now : cal.date(byAdding: .day, value: 1, to: now)!
        return try at(day, words.count > 1 ? words[1] : defaultTime)
    }
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
    for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
        f.dateFormat = fmt
        if let d = f.date(from: t.uppercased()) { return d }
    }
    f.dateFormat = "yyyy-MM-dd"
    if let d = f.date(from: t) { return try at(d, defaultTime) }
    throw AppleError.invalid("date \(s ?? ""). Use YYYY-MM-DD [HH:MM], today|tomorrow [HH:MM], or +30m/+2h/+1d")
}
