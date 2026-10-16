import Foundation
import EventKit

// MARK: - Fast read path (Data-*.sqlite, read-only, one file per account)

public struct ReminderRow {
    public let id: String            // ZCKIDENTIFIER: CloudKit record name
    public let title: String
    public let notes: String?
    public let list: String
    public let completed: Bool
    public let completedAt: Date?
    public let due: Date?
    public let allDay: Bool
    public let flagged: Bool
    public let priority: Int
    public let parentID: String?
    public let created: Date?
    public let synced: Bool          // CloudKit returned a server record for this row
    public var alarms: [String] = []
    public var recurrence: String?
    public var tags: [String] = []

    public func json() -> [String: Any] {
        [
            "id": id, "title": title, "notes": notes ?? NSNull(), "list": list, "completed": completed,
            "completedAt": isoString(completedAt), "due": dueString ?? NSNull(), "allDay": allDay,
            "flagged": flagged, "priority": priority, "parentId": parentID ?? NSNull(),
            "created": isoString(created), "synced": synced, "alarms": alarms,
            "recurrence": recurrence ?? NSNull(), "tags": tags,
        ]
    }

    /// All-day dates are stored at UTC midnight, so they print as a plain date.
    public var dueString: String? {
        guard let due else { return nil }
        if allDay {
            let f = DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
            return f.string(from: due)
        }
        return isoString(due) as? String
    }
}

public final class RemindersStore {
    public static let storesDir = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores"

    public init() {}

    public func storePaths() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.storesDir)) ?? []
        return files.filter { $0.hasPrefix("Data-") && $0.hasSuffix(".sqlite") }.sorted().map { Self.storesDir + "/" + $0 }
    }

    /// Every live reminder across every account store.
    public func all(includeCompleted: Bool) throws -> [ReminderRow] {
        var out: [ReminderRow] = []
        for p in storePaths() {
            let db = try SQLiteReader(path: p)
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
            for r in try db.query("""
                SELECT ZREMINDER4, ZFREQUENCY, ZINTERVAL FROM ZREMCDOBJECT
                WHERE Z_ENT = ? AND IFNULL(ZMARKEDFORDELETION,0) = 0
                """, [ent["REMCDRecurrenceRule"] ?? -1]) {
                guard let rk = r.int("ZREMINDER4") else { continue }
                let unit = ["day", "week", "month", "year"][min(max(r.int("ZFREQUENCY") ?? 0, 0), 3)]
                let n = r.int("ZINTERVAL") ?? 1
                recur[rk] = n == 1 ? "every \(unit)" : "every \(n) \(unit)s"
            }
            var tags: [Int: [String]] = [:]
            for t in try db.query("""
                SELECT ZREMINDER3, ZNAME1 FROM ZREMCDOBJECT WHERE Z_ENT = ? AND IFNULL(ZMARKEDFORDELETION,0) = 0
                """, [ent["REMCDHashtag"] ?? -1]) {
                if let rk = t.int("ZREMINDER3"), let n = t.str("ZNAME1") { tags[rk, default: []].append(n) }
            }

            for r in rows {
                guard let id = r.str("ZCKIDENTIFIER") else { continue }
                let pk = r.int("Z_PK") ?? 0
                var row = ReminderRow(
                    id: id, title: r.str("ZTITLE") ?? "", notes: r.str("ZNOTES"), list: r.str("LIST") ?? "",
                    completed: r.bool("ZCOMPLETED"), completedAt: r.date("ZCOMPLETIONDATE"), due: r.date("ZDUEDATE"),
                    allDay: r.bool("ZALLDAY"), flagged: r.bool("ZFLAGGED"), priority: r.int("ZPRIORITY") ?? 0,
                    parentID: r.str("PARENT"), created: r.date("ZCREATIONDATE"), synced: r.bool("SYNCED"))
                row.alarms = alarms[pk] ?? []
                row.recurrence = recur[pk]
                row.tags = tags[pk] ?? []
                out.append(row)
            }
        }
        return out.sorted { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) }
    }

    public func find(_ id: String) throws -> ReminderRow? {
        try all(includeCompleted: true).first { $0.id == id }
    }

    /// Incomplete reminders due today or earlier. Earlier ones are marked overdue.
    public func dueToday(now: Date = Date()) throws -> [(ReminderRow, overdue: Bool)] {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let endOfToday = cal.date(byAdding: .day, value: 1, to: startOfToday)!
        let todayString: String = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: now) }()
        return try all(includeCompleted: false).compactMap { r in
            guard r.due != nil else { return nil }
            if r.allDay, let d = r.dueString {
                return d <= todayString ? (r, d < todayString) : nil
            }
            guard let due = r.due, due < endOfToday else { return nil }
            return (r, due < startOfToday)
        }
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

public final class RemindersWriter {
    let store = EKEventStore()

    public init() async throws {
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
    public func add(title: String, list: String, at: Date, notes: String?, priority: Int?) throws -> EKReminder {
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = try calendar(named: list)
        r.notes = notes
        if let priority { r.priority = priority }
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        comps.timeZone = TimeZone.current
        r.dueDateComponents = comps
        r.addAlarm(EKAlarm(absoluteDate: at))
        try store.save(r, commit: true)
        return r
    }

    /// Resolves an ID from the read path (CloudKit record name) or an EventKit identifier.
    public func reminder(_ id: String) throws -> EKReminder {
        if let r = store.calendarItem(withIdentifier: id) as? EKReminder { return r }
        if let r = store.calendarItems(withExternalIdentifier: id).compactMap({ $0 as? EKReminder }).first { return r }
        throw AppleError.notFound("reminder \(id)")
    }

    public func complete(_ id: String) throws -> EKReminder {
        let r = try reminder(id)
        r.isCompleted = true
        try store.save(r, commit: true)
        return r
    }

    public func delete(_ id: String) throws {
        try store.remove(try reminder(id), commit: true)
    }
}

/// Parses `--at`: "2026-10-16 09:00", "2026-10-16T09:00", "2026-10-16", "today 17:00",
/// "tomorrow", "tomorrow 8:30", "+30m", "+2h", "+1d". A bare date takes `defaultTime`.
public func parseWhen(_ s: String?, defaultTime: String, now: Date = Date()) throws -> Date {
    let cal = Calendar.current
    func at(_ day: Date, _ hm: String) throws -> Date {
        let parts = hm.split(separator: ":").map { Int($0) }
        guard parts.count == 2, let h = parts[0], let m = parts[1], (0..<24).contains(h), (0..<60).contains(m) else {
            throw AppleError.invalid("time \(hm), use HH:MM")
        }
        return cal.date(bySettingHour: h, minute: m, second: 0, of: day)!
    }
    let t = (s ?? "tomorrow").trimmingCharacters(in: .whitespaces).lowercased()
    if let m = t.range(of: #"^\+(\d+)([mhd])$"#, options: .regularExpression) {
        let v = Int(t[m].dropFirst().dropLast())!
        let unit: Calendar.Component = t.hasSuffix("m") ? .minute : t.hasSuffix("h") ? .hour : .day
        // Drop seconds so the due time and the alarm land on the same minute.
        let t = cal.date(byAdding: unit, value: v, to: now)!
        return cal.date(from: cal.dateComponents([.year, .month, .day, .hour, .minute], from: t))!
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
