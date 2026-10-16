import Foundation
import EventKit

// Calendar: reads and writes through EventKit (calaccessd -> dataaccessd -> CalDAV).
// EventKit is fast here (30 days of events in ~20 ms) and expands recurrences correctly,
// so no SQLite read path is needed.

// MARK: - Domain

struct CalendarSettings: DomainSettings {
    static let key = "calendar"
    /// Source (account) of the default calendar for `add`. Your rule: identify the personal
    /// calendar by its iCloud source, never by title.
    var defaultSource: String
    /// Calendars hidden everywhere, by title.
    var excludeCalendars: [String]
    /// Regexes matched against event titles. A match hides the event everywhere.
    var excludeTitlePatterns: [String]

    static let defaults = CalendarSettings(defaultSource: "iCloud", excludeCalendars: [],
                                           excludeTitlePatterns: [#"(?i)therap(y|ist)|counsel(l?ing|or)"#])
}

let calendarDomain = Domain(name: "calendar", defaults: CalendarSettings.defaults, commands: calendarCommands, checks: { ctx in
    let st = EKEventStore.authorizationStatus(for: .event)
    guard st == .fullAccess else {
        return [Check(domain: "calendar", name: "eventkit", ok: st == .notDetermined,
                      detail: st == .notDetermined ? "not asked yet. The first command prompts." : "access is \(st.rawValue)",
                      fix: st == .notDetermined ? nil : "System Settings > Privacy & Security > Calendars")]
    }
    let t = Date()
    do {
        let store = try await CalendarStore(ctx)
        let n = try store.events(from: Date(), to: Date().addingTimeInterval(86400 * 30), calendar: nil).count
        let def = (try? store.defaultCalendar().title) ?? "none found"
        return [Check(domain: "calendar", name: "eventkit", ok: true,
                      detail: "\(store.visibleCalendars().count) calendars, \(n) events in the next 30 days, default for add: \(def), \(Int(Date().timeIntervalSince(t) * 1000)) ms", fix: nil)]
    } catch {
        return [Check(domain: "calendar", name: "eventkit", ok: false, detail: AppleError.wrap(error).description, fix: nil)]
    }
})

// MARK: - Outputs

struct CalendarInfo: Encodable { let id: String; let title: String; let source: String; let writable: Bool; let isDefault: Bool }
struct CalendarList: Output {
    let calendars: [CalendarInfo]
    var text: String {
        calendars.map { "\($0.title)  [\($0.source)]\($0.writable ? "" : "  read-only")\($0.isDefault ? "  (default for add)" : "")" }.joined(separator: "\n")
    }
}

struct EventInfo: Encodable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let calendar: String
    let source: String
    let location: String?
    let notes: String?
    let url: String?
    let recurring: Bool
    let attendees: [String]
    let alerts: [Int]          // minutes before start
    var created: Bool? = nil
    var deleted: Bool? = nil

    var line: String {
        let f = DateFormatter(); f.dateFormat = allDay ? "EEE yyyy-MM-dd" : "EEE yyyy-MM-dd HH:mm"
        let e = DateFormatter(); e.dateFormat = "HH:mm"
        let when = allDay ? f.string(from: start) + "  all day" : f.string(from: start) + "-" + e.string(from: end)
        return "\(when)  \(title)  [\(calendar)]" + (location.map { "  @ \($0)" } ?? "") + (recurring ? "  (repeats)" : "")
    }
}

struct EventList: Output {
    let events: [EventInfo]
    let hidden: Int?
    var text: String {
        (events.isEmpty ? "no events" : events.map(\.line).joined(separator: "\n"))
            + ((hidden ?? 0) > 0 ? "\n\(hidden!) event(s) hidden by privacy config" : "")
    }
}

struct EventResult: Output {
    let event: EventInfo
    var text: String { (event.deleted == true ? "deleted " : "created ") + event.line + "  \(event.id)" }
}

// MARK: - Commands

private func calendarCommands(_ ctx: Context) -> [Command] {
    let cal = Param("calendar", "Calendar title (default: all visible)")
    return [
        Command(["calendar", "calendars"], .read, "Event calendars with their account, and which one add uses by default.") { _ in
            let s = try await CalendarStore(ctx)
            let def = try? s.defaultCalendar()
            return CalendarList(calendars: s.visibleCalendars().map {
                CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title,
                             writable: $0.allowsContentModifications, isDefault: $0.calendarIdentifier == def?.calendarIdentifier)
            })
        },
        Command(["calendar", "today"], .read, "Today's events, including recurring ones.", [cal]) { a in
            let start = Calendar.current.startOfDay(for: Date())
            let (ev, hidden) = try await CalendarStore(ctx).eventsCounted(from: start, to: start.addingTimeInterval(86400), calendar: a.string("calendar"))
            return EventList(events: ev, hidden: hidden)
        },
        Command(["calendar", "agenda"], .read, "Events in a window: from now for N days, or between --from and --to.",
                [Param("days", .integer, "Days ahead (default 7)"), Param("from", "Start: YYYY-MM-DD [HH:MM], today, tomorrow"),
                 Param("to", "End: same forms"), cal]) { a in
            let from = try a.string("from").map { try parseWhen($0, defaultTime: "00:00") } ?? Date()
            let to = try a.string("to").map { try parseWhen($0, defaultTime: "23:59") } ?? from.addingTimeInterval(Double(a.int("days", 7)) * 86400)
            guard to > from else { throw AppleError.invalid("to must be after from") }
            let (ev, hidden) = try await CalendarStore(ctx).eventsCounted(from: from, to: to, calendar: a.string("calendar"))
            return EventList(events: ev, hidden: hidden)
        },
        Command(["calendar", "search"], .read, "Search event titles, locations, and notes, six months back and six months ahead by default.",
                [Param("query", required: true, positional: true, "Text to find"), Param("since", "YYYY-MM-DD, or 30d ago (default 180d)"),
                 Param("until", "YYYY-MM-DD or +30d (default +180d)"), cal, Param("limit", .integer, "Max (default 50)")]) { a in
            let q = try a.require("query")
            let since = try a.string("since").map(parseSince) ?? Date().addingTimeInterval(-180 * 86400)
            let until = try a.string("until").map { try parseWhen($0, defaultTime: "23:59") } ?? Date().addingTimeInterval(180 * 86400)
            let ev = try await CalendarStore(ctx).events(from: since, to: until, calendar: a.string("calendar")).filter {
                [$0.title, $0.location ?? "", $0.notes ?? ""].contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
            return EventList(events: Array(ev.prefix(a.int("limit", 50))), hidden: nil)
        },
        Command(["calendar", "add"], .write, "Add an event. Default calendar: the one whose account is iCloud (your personal calendar).",
                [Param("title", required: true, positional: true, "Event title"),
                 Param("start", required: true, "YYYY-MM-DD HH:MM, today|tomorrow HH:MM, +2h, or YYYY-MM-DD with all-day"),
                 Param("end", "End time (same forms)"), Param("duration", "Length like 30m, 1h, 90m (default 1h)"),
                 Param("all-day", .boolean, "All-day event on the start date"), Param("location", "Location"), Param("notes", "Notes"),
                 Param("alert", "Alert before start, like 15m or 1h (default none)"), Param("calendar", "Calendar title (default: personal iCloud)")]) { a in
            let s = try await CalendarStore(ctx)
            return EventResult(event: try s.add(title: try a.require("title"), start: try a.require("start"), end: a.string("end"),
                                                duration: a.string("duration"), allDay: a.bool("all-day"), location: a.string("location"),
                                                notes: a.string("notes"), alert: a.string("alert"), calendar: a.string("calendar")))
        },
        Command(["calendar", "delete"], .destructive, "Delete an event. A repeating event needs all to delete every occurrence.",
                [Param("id", required: true, positional: true, "Event ID"), Param("all", .boolean, "Delete every occurrence of a repeating event")]) { a in
            EventResult(event: try await CalendarStore(ctx).delete(try a.require("id"), all: a.bool("all")))
        },
    ]
}

/// "30m", "1h", "90m", "1h30m" -> seconds.
func parseDuration(_ s: String) throws -> TimeInterval {
    var total: TimeInterval = 0, num = ""
    for ch in s.lowercased() {
        if ch.isNumber { num.append(ch); continue }
        guard let n = Double(num), ch == "h" || ch == "m" || ch == "d" else { throw AppleError.invalid("duration \(s), use like 30m, 1h, 1h30m") }
        total += n * (ch == "h" ? 3600 : ch == "d" ? 86400 : 60); num = ""
    }
    guard num.isEmpty, total > 0 else { throw AppleError.invalid("duration \(s), use like 30m, 1h, 1h30m") }
    return total
}

// MARK: - Store

final class CalendarStore {
    let store = EKEventStore()
    let settings: CalendarSettings
    let titleFilter: PrivacyFilter

    init(_ ctx: Context) async throws {
        settings = try ctx.settings(CalendarSettings.self)
        titleFilter = try PrivacyFilter(titlePatterns: settings.excludeTitlePatterns, containers: settings.excludeCalendars, ids: [])
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: break
        case .notDetermined:
            if !(try await store.requestFullAccessToEvents()) { throw AppleError.permission("Calendar access was not granted") }
        default:
            throw AppleError.permission("allow Calendars for this app in System Settings > Privacy & Security > Calendars")
        }
    }

    func visibleCalendars() -> [EKCalendar] {
        store.calendars(for: .event).filter { !titleFilter.hidesContainer($0.title) }
    }

    private func calendars(named name: String?) throws -> [EKCalendar]? {
        guard let name else { return nil }
        let hits = visibleCalendars().filter { $0.title.compare(name, options: .caseInsensitive) == .orderedSame }
        guard !hits.isEmpty else { throw AppleError.notFound("calendar \(name)") }
        return hits
    }

    /// Your rule: the personal calendar is the writable event calendar whose source is iCloud.
    func defaultCalendar() throws -> EKCalendar {
        let hits = visibleCalendars().filter {
            $0.allowsContentModifications && $0.source.title.compare(settings.defaultSource, options: .caseInsensitive) == .orderedSame
        }
        guard hits.count == 1 else {
            throw hits.isEmpty ? AppleError.notFound("a writable calendar on the \(settings.defaultSource) account")
                : AppleError.invalid("\(hits.count) writable calendars on \(settings.defaultSource): \(hits.map(\.title).joined(separator: ", ")). Pass calendar.")
        }
        return hits[0]
    }

    private func hides(_ e: EKEvent) -> Bool {
        titleFilter.hidesContainer(e.calendar.title) || titleFilter.hidesTitle(e.title ?? "")
    }

    private func info(_ e: EKEvent) -> EventInfo {
        EventInfo(id: e.eventIdentifier ?? e.calendarItemIdentifier, title: e.title ?? "", start: e.startDate, end: e.endDate,
                  allDay: e.isAllDay, calendar: e.calendar.title, source: e.calendar.source.title,
                  location: e.location.flatMap { $0.isEmpty ? nil : $0 }, notes: e.notes.flatMap { $0.isEmpty ? nil : $0 },
                  url: e.url?.absoluteString, recurring: e.hasRecurrenceRules,
                  attendees: (e.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") },
                  alerts: (e.alarms ?? []).map { Int(-$0.relativeOffset / 60) })
    }

    /// EventKit predicates span at most 4 years, so long windows are split.
    private func raw(from: Date, to: Date, calendar: String?) throws -> [EKEvent] {
        let cals = try calendars(named: calendar)
        var out: [EKEvent] = [], cur = from
        while cur < to {
            let next = min(to, cur.addingTimeInterval(3 * 365 * 86400))
            out += try withDeadline(15, "reading events") { self.store.events(matching: self.store.predicateForEvents(withStart: cur, end: next, calendars: cals)) }
            cur = next
        }
        return out.sorted { $0.startDate < $1.startDate }
    }

    func eventsCounted(from: Date, to: Date, calendar: String?) throws -> ([EventInfo], Int) {
        let all = try raw(from: from, to: to, calendar: calendar)
        let visible = all.filter { !hides($0) }
        return (visible.map(info), all.count - visible.count)
    }

    func events(from: Date, to: Date, calendar: String?) throws -> [EventInfo] {
        try eventsCounted(from: from, to: to, calendar: calendar).0
    }

    func add(title: String, start: String, end: String?, duration: String?, allDay: Bool, location: String?,
             notes: String?, alert: String?, calendar: String?) throws -> EventInfo {
        if titleFilter.hidesTitle(title) { throw AppleError.refused("that title matches a privacy pattern, so the event would be hidden from you") }
        let cal = try calendar.map { name -> EKCalendar in
            guard let c = try calendars(named: name)?.first(where: \.allowsContentModifications) else { throw AppleError.refused("calendar \(name) is read-only") }
            return c
        } ?? defaultCalendar()
        let e = EKEvent(eventStore: store)
        e.title = title
        e.calendar = cal
        e.isAllDay = allDay
        let s = try parseWhen(start, defaultTime: "09:00")
        e.startDate = allDay ? Calendar.current.startOfDay(for: s) : s
        if allDay {
            e.endDate = e.startDate.addingTimeInterval(86400 - 1)
        } else if let end {
            e.endDate = try parseWhen(end, defaultTime: "10:00")
        } else {
            e.endDate = e.startDate.addingTimeInterval(try duration.map(parseDuration) ?? 3600)
        }
        guard e.endDate > e.startDate else { throw AppleError.invalid("end must be after start") }
        e.location = location
        e.notes = notes
        // An explicit alert replaces the calendar's default alerts instead of stacking on top of them.
        if let alert { e.alarms = [EKAlarm(relativeOffset: -(try parseDuration(alert)))] }
        try withDeadline(10, "saving the event") { try self.store.save(e, span: .thisEvent, commit: true) }
        var i = info(e)
        i.created = true
        return i
    }

    func delete(_ id: String, all: Bool) throws -> EventInfo {
        guard let e = store.event(withIdentifier: id), !hides(e) else { throw AppleError.notFound("event \(id)") }
        if e.hasRecurrenceRules && !all { throw AppleError.refused("this event repeats. Pass all to delete every occurrence.") }
        var i = info(e)
        try withDeadline(10, "deleting the event") { try self.store.remove(e, span: all ? .futureEvents : .thisEvent, commit: true) }
        i.deleted = true
        return i
    }
}
