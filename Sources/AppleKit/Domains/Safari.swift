import Foundation

// Safari: read-only. History.db (visits, local and synced from other devices),
// CloudTabs.db (tabs open on other devices), Bookmarks.plist.

// MARK: - Domain

struct SafariSettings: DomainSettings {
    static let key = "safari"
    /// Domains (and their subdomains) hidden everywhere, e.g. "bank.com".
    var excludeDomains: [String]
    /// Regexes matched against page titles and URLs.
    var excludePatterns: [String]

    static let defaults = SafariSettings(excludeDomains: [], excludePatterns: [])
}

let safariDomain = Domain(name: "safari", defaults: SafariSettings.defaults, commands: safariCommands, checks: { ctx in
    let t = Date()
    do {
        let s = try SafariStore(ctx)
        let n = try s.db.query("SELECT COUNT(*) AS N FROM history_visits").first?.int("N") ?? 0
        return [Check(domain: "safari", name: "history", ok: true,
                      detail: "\(n) visits readable, schema matches, \(Int(Date().timeIntervalSince(t) * 1000)) ms", fix: nil)]
    } catch {
        let e = AppleError.wrap(error)
        return [Check(domain: "safari", name: "history", ok: false, detail: e.description,
                      fix: e.code == "permission" ? "System Settings > Privacy & Security > Full Disk Access" : nil)]
    }
})

// MARK: - Outputs

struct Visit: Encodable {
    let url: String
    let title: String?
    let domain: String
    let time: Date?
    let fromOtherDevice: Bool
    var line: String {
        let when = time.map { String(localISO.string(from: $0).prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? ""
        return "\(when)  \(title ?? "(no title)")  \(url)" + (fromOtherDevice ? "  (other device)" : "")
    }
}
struct VisitList: Output {
    let visits: [Visit]
    var text: String { visits.isEmpty ? "no visits" : visits.map(\.line).joined(separator: "\n") }
}

struct DomainRow: Encodable { let domain: String; let visits: Int; let pages: Int; let lastVisit: Date? }
struct DomainList: Output {
    let domains: [DomainRow]
    var text: String { domains.map { "\(String($0.visits).padding(toLength: 6, withPad: " ", startingAt: 0))  \($0.domain)  (\($0.pages) pages)" }.joined(separator: "\n") }
}

struct VisitedResult: Output {
    let query: String
    let visited: Bool
    let visits: Int
    let firstVisit: Date?
    let lastVisit: Date?
    let urls: Int
    var text: String {
        visited ? "\(query): \(visits) visits across \(urls) page(s), first \(firstVisit.map { localISO.string(from: $0) } ?? "?"), last \(lastVisit.map { localISO.string(from: $0) } ?? "?")"
            : "\(query): never visited (in the last year of history)"
    }
}

struct Bookmark: Encodable { let title: String; let url: String; let folder: String }
struct BookmarkList: Output {
    let bookmarks: [Bookmark]
    var text: String { bookmarks.map { "[\($0.folder)] \($0.title)  \($0.url)" }.joined(separator: "\n") }
}

struct CloudTab: Encodable { let device: String; let title: String?; let url: String; let pinned: Bool; let lastViewed: Date? }
struct CloudTabList: Output {
    let tabs: [CloudTab]
    var text: String { tabs.isEmpty ? "no tabs from other devices" : tabs.map { "[\($0.device)] \($0.title ?? "")  \($0.url)" }.joined(separator: "\n") }
}

// MARK: - Commands

private func safariCommands(_ ctx: Context) -> [Command] {
    let since = Param("since", "YYYY-MM-DD, today, yesterday, 7d, 12h")
    let domain = Param("domain", "Only this domain (and subdomains)")
    return [
        Command(["safari", "history"], .read, "Recent visits, newest first, including ones synced from your other devices.",
                [since, domain, Param("limit", .integer, "Max (default 50)")]) { a in
            VisitList(visits: try SafariStore(ctx).visits(query: nil, domain: a.string("domain"),
                                                          since: try a.string("since").map(parseSince) ?? Date().addingTimeInterval(-86400),
                                                          limit: a.int("limit", 50)))
        },
        Command(["safari", "search"], .read, "Search visited page titles and URLs, newest first.",
                [Param("query", required: true, positional: true, "Text to find"), Param("since", "Default 90d"), domain,
                 Param("limit", .integer, "Max (default 30)")]) { a in
            VisitList(visits: try SafariStore(ctx).visits(query: try a.require("query"), domain: a.string("domain"),
                                                          since: try a.string("since").map(parseSince) ?? Date().addingTimeInterval(-90 * 86400),
                                                          limit: a.int("limit", 30)))
        },
        Command(["safari", "domains"], .read, "Most-visited domains over a window.",
                [Param("since", "Default 7d"), Param("limit", .integer, "Max (default 20)")]) { a in
            DomainList(domains: try SafariStore(ctx).domains(since: try a.string("since").map(parseSince) ?? Date().addingTimeInterval(-7 * 86400),
                                                             limit: a.int("limit", 20)))
        },
        Command(["safari", "visited"], .read, "Whether a URL or domain was visited, with first and last visit and counts.",
                [Param("target", required: true, positional: true, "A URL or a domain")]) { a in
            try SafariStore(ctx).visited(try a.require("target"))
        },
        Command(["safari", "bookmarks"], .read, "Bookmarks with their folder.", [Param("folder", "Only this folder")]) { a in
            BookmarkList(bookmarks: try SafariStore(ctx).bookmarks(folder: a.string("folder")))
        },
        Command(["safari", "tabs"], .read, "Tabs open on your other devices (iCloud Tabs).") { _ in
            CloudTabList(tabs: try SafariStore(ctx).cloudTabs())
        },
    ]
}

// MARK: - Store

final class SafariStore {
    static let historyPath = NSHomeDirectory() + "/Library/Safari/History.db"
    static let tabsPath = NSHomeDirectory() + "/Library/Containers/com.apple.Safari/Data/Library/Safari/CloudTabs.db"
    static let bookmarksPath = NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
    static let schema: [String: [String]] = [
        "history_items": ["id", "url", "visit_count"],
        "history_visits": ["id", "history_item", "visit_time", "title", "load_successful", "origin"],
    ]

    let db: SQLiteReader
    let domains: [String]
    let patterns: PrivacyFilter

    init(_ ctx: Context) throws {
        let s = try ctx.settings(SafariSettings.self)
        domains = s.excludeDomains.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty }
        patterns = try PrivacyFilter(titlePatterns: s.excludePatterns, containers: [], ids: [])
        db = try SQLiteReader(path: Self.historyPath)
        try db.require(Self.schema)
    }

    /// Lowercased host with trailing dots dropped. Falls back to a lenient parse when
    /// URLComponents rejects the URL, so an odd URL cannot slip past a domain exclusion.
    static func host(_ url: String) -> String {
        var h = URLComponents(string: url)?.host ?? ""
        if h.isEmpty, let r = url.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://(?:[^@/?#]*@)?\[?([^/?#:\]]+)"#, options: .regularExpression) {
            let m = String(url[r])
            h = String(m[(m.range(of: "://")!.upperBound)...]).split(separator: "@").last.map(String.init) ?? ""
            h = h.trimmingCharacters(in: CharacterSet(charactersIn: "["))
        }
        return h.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// History items with any visit whose title matches an exclude pattern. Aggregate
    /// commands (domains, visited) read no titles, so they check this set instead.
    private lazy var itemsHiddenByTitle: Set<Int> = {
        guard !patterns.patterns.isEmpty else { return [] }
        let rows = (try? db.query("SELECT DISTINCT history_item, title FROM history_visits WHERE title IS NOT NULL AND title != ''")) ?? []
        return Set(rows.compactMap { r in r.str("title").flatMap { patterns.hidesTitle($0) ? r.int("history_item") : nil } })
    }()

    /// Registrable-ish domain: drop a leading "www." only, so subdomains stay distinct.
    static func domain(_ url: String) -> String {
        let h = host(url)
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    private func hides(url: String, title: String?) -> Bool {
        let h = Self.host(url)
        if domains.contains(where: { h == $0 || h.hasSuffix("." + $0) }) { return true }
        return patterns.hidesTitle(url) || title.map(patterns.hidesTitle) == true
    }

    func visits(query: String?, domain: String?, since: Date, limit: Int) throws -> [Visit] {
        let rows = try db.query("""
            SELECT i.url, v.title, v.visit_time, v.origin FROM history_visits v JOIN history_items i ON i.id = v.history_item
            WHERE v.visit_time >= ? AND v.load_successful = 1 ORDER BY v.visit_time DESC
            """, [since.timeIntervalSinceReferenceDate])
        let d = domain?.lowercased()
        var out: [Visit] = []
        for r in rows {
            guard let url = r.str("url") else { continue }
            let title = r.str("title")
            if hides(url: url, title: title) { continue }
            let h = Self.host(url)
            if let d, !(h == d || h.hasSuffix("." + d)) { continue }
            if let q = query, !(url.range(of: q, options: .caseInsensitive) != nil || title?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil) { continue }
            out.append(Visit(url: url, title: title, domain: Self.domain(url), time: r.date("visit_time"), fromOtherDevice: r.int("origin") == 1))
            if out.count >= limit { break }
        }
        return out
    }

    func domains(since: Date, limit: Int) throws -> [DomainRow] {
        var agg: [String: (visits: Int, pages: Set<String>, last: Date?)] = [:]
        for r in try db.query("""
            SELECT i.id, i.url, v.visit_time FROM history_visits v JOIN history_items i ON i.id = v.history_item
            WHERE v.visit_time >= ? AND v.load_successful = 1
            """, [since.timeIntervalSinceReferenceDate]) {
            guard let url = r.str("url"), !hides(url: url, title: nil), !itemsHiddenByTitle.contains(r.int("id") ?? -1) else { continue }
            let d = Self.domain(url)
            guard !d.isEmpty else { continue }
            var e = agg[d] ?? (0, [], nil)
            e.visits += 1; e.pages.insert(url)
            if let t = r.date("visit_time"), e.last.map({ t > $0 }) ?? true { e.last = t }
            agg[d] = e
        }
        return agg.map { DomainRow(domain: $0.key, visits: $0.value.visits, pages: $0.value.pages.count, lastVisit: $0.value.last) }
            .sorted { ($0.visits, $1.domain) > ($1.visits, $0.domain) }.prefix(limit).map { $0 }
    }

    func visited(_ target: String) throws -> VisitedResult {
        let t = target.lowercased()
        let isURL = t.contains("/") || t.hasPrefix("http")
        let host = isURL ? Self.host(t.hasPrefix("http") ? t : "https://" + t) : t
        if hides(url: isURL ? target : "https://" + host, title: nil) { throw AppleError.hidden("\(target)") }
        let rows = try db.query("""
            SELECT i.id, i.url, MIN(v.visit_time) AS A, MAX(v.visit_time) AS Z, COUNT(*) AS N
            FROM history_visits v JOIN history_items i ON i.id = v.history_item GROUP BY i.id
            """)
        let hits = rows.filter { r in
            guard let u = r.str("url") else { return false }
            if isURL { return u.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == (t.hasPrefix("http") ? t : "https://" + t).trimmingCharacters(in: CharacterSet(charactersIn: "/")) || u.lowercased() == t }
            let h = Self.host(u)
            return h == host || h.hasSuffix("." + host)
        }.filter { !hides(url: $0.str("url") ?? "", title: nil) && !itemsHiddenByTitle.contains($0.int("id") ?? -1) }
        let visits = hits.reduce(0) { $0 + ($1.int("N") ?? 0) }
        return VisitedResult(query: target, visited: !hits.isEmpty, visits: visits,
                             firstVisit: hits.compactMap { $0.date("A") }.min(), lastVisit: hits.compactMap { $0.date("Z") }.max(), urls: hits.count)
    }

    func bookmarks(folder: String?) throws -> [Bookmark] {
        guard let data = FileManager.default.contents(atPath: Self.bookmarksPath),
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AppleError.notFound("Safari bookmarks")
        }
        var out: [Bookmark] = []
        func walk(_ n: [String: Any], _ path: String) {
            let type = n["WebBookmarkType"] as? String
            if type == "WebBookmarkTypeLeaf", let url = n["URLString"] as? String {
                let title = (n["URIDictionary"] as? [String: Any])?["title"] as? String ?? url
                if !hides(url: url, title: title) { out.append(Bookmark(title: title, url: url, folder: path)) }
            }
            if type == "WebBookmarkTypeList" {
                let t = n["Title"] as? String ?? ""
                let name = t == "BookmarksBar" ? "Favorites" : t == "BookmarksMenu" ? "Menu" : t == "com.apple.ReadingList" ? "Reading List" : t
                for c in n["Children"] as? [[String: Any]] ?? [] { walk(c, path.isEmpty ? name : (name.isEmpty ? path : path + "/" + name)) }
            }
        }
        walk(root, "")
        return folder.map { f in out.filter { $0.folder.lowercased() == f.lowercased() || $0.folder.lowercased().hasPrefix(f.lowercased() + "/") } } ?? out
    }

    func cloudTabs() throws -> [CloudTab] {
        let t = try SQLiteReader(path: Self.tabsPath)
        try t.require(["cloud_tabs": ["device_uuid", "title", "url", "is_pinned", "last_viewed_time"], "cloud_tab_devices": ["device_uuid", "device_name"]])
        return try t.query("""
            SELECT d.device_name, c.title, c.url, c.is_pinned, c.last_viewed_time FROM cloud_tabs c
            LEFT JOIN cloud_tab_devices d ON d.device_uuid = c.device_uuid ORDER BY d.device_name, c.position
            """).compactMap { r in
            guard let url = r.str("url"), !hides(url: url, title: r.str("title")) else { return nil }
            return CloudTab(device: r.str("device_name") ?? "unknown", title: r.str("title"), url: url, pinned: r.bool("is_pinned"),
                            lastViewed: r.date("last_viewed_time"))
        }
    }
}
