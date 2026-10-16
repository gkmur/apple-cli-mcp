import Foundation
import Photos

// Photos: reads from the library's Photos.sqlite (2.2 GB, opened read-only, never copied).
// Download and delete go through PhotoKit. Delete always shows Apple's own confirmation
// dialog and is CLI only.

// MARK: - Domain

struct PhotosSettings: DomainSettings {
    static let key = "photos"
    /// Library path. Empty means ~/Pictures/Photos.photoslibrary, else the first library in ~/Pictures.
    var libraryPath: String
    /// Show items in the Hidden album. Off by default.
    var includeHidden: Bool
    /// Album names whose items are hidden everywhere.
    var excludeAlbums: [String]
    /// Downloads refuse to leave less free disk space than this.
    var minFreeGBAfterDownload: Double

    static let defaults = PhotosSettings(libraryPath: "", includeHidden: false, excludeAlbums: [], minFreeGBAfterDownload: 5)
}

let photosDomain = Domain(name: "photos", defaults: PhotosSettings.defaults, commands: photosCommands, checks: { ctx in
    var out: [Check] = []
    let t = Date()
    do {
        let store = try PhotosStore(ctx)
        let s = try store.stats()
        out.append(Check(domain: "photos", name: "library", ok: true,
                         detail: "\(s.items) items readable (\(store.libraryPath)), schema matches, \(Int(Date().timeIntervalSince(t) * 1000)) ms", fix: nil))
    } catch {
        let e = AppleError.wrap(error)
        out.append(Check(domain: "photos", name: "library", ok: false, detail: e.description,
                         fix: e.code == "permission" ? "System Settings > Privacy & Security > Full Disk Access" : nil))
    }
    let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    out.append(Check(domain: "photos", name: "photokit", ok: st == .authorized || st == .notDetermined,
                     detail: st == .authorized ? "full access granted (download and delete work)" :
                        st == .notDetermined ? "not asked yet. The first download or delete prompts." : "access is \(st.rawValue)",
                     fix: st == .authorized || st == .notDetermined ? nil : "System Settings > Privacy & Security > Photos"))
    return out
})

// MARK: - Outputs

struct PhotoItem: Encodable {
    let id: String              // ZUUID; PhotoKit localIdentifier is "<id>/L0/001"
    let filename: String?
    let kind: String            // photo, video, other
    let subtype: String?
    let date: Date?
    let bytes: Int?
    let width: Int?
    let height: Int?
    let duration: Double?
    let favorite: Bool
    var line: String {
        let when = date.map { String(localISO.string(from: $0).prefix(10)) } ?? "          "
        let dur = duration.map { $0 > 0 ? String(format: "  %d:%02d", Int($0) / 60, Int($0) % 60) : "" } ?? ""
        return "\(when)  \(humanBytes(bytes ?? 0).padding(toLength: 9, withPad: " ", startingAt: 0))  \(kind)\(dur)  \(filename ?? "")  \(id)"
    }
}

struct PhotoList: Output {
    let items: [PhotoItem]
    var text: String { items.map(\.line).joined(separator: "\n") }
}

struct PhotoStats: Output {
    let items: Int
    let photos: Int
    let videos: Int
    let bytes: Int
    let oldest: Date?
    let newest: Date?
    let favorites: Int
    let hidden: Int             // in the Hidden album, excluded unless includeHidden
    let recentlyDeleted: Int
    var text: String {
        let range = [oldest, newest].compactMap { $0.map { String(localISO.string(from: $0).prefix(10)) } }.joined(separator: " to ")
        return "\(items) items (\(photos) photos, \(videos) videos), \(humanBytes(bytes)) of originals, \(range)\n"
            + "\(favorites) favorites; \(hidden) hidden and \(recentlyDeleted) recently deleted are not counted"
    }
}

struct StorageRow: Encodable { let key: String; let items: Int; let bytes: Int }
struct PhotoStorage: Output {
    let by: String
    let rows: [StorageRow]
    let total: Int
    var text: String {
        rows.map { "\($0.key.padding(toLength: 8, withPad: " ", startingAt: 0))  \(String($0.items).padding(toLength: 7, withPad: " ", startingAt: 0))  \(humanBytes($0.bytes))" }
            .joined(separator: "\n") + "\ntotal     \(humanBytes(total))"
    }
}

struct AlbumInfo: Encodable { let id: String; let name: String; let items: Int }
struct AlbumList: Output {
    let albums: [AlbumInfo]
    var text: String { albums.map { "\($0.name)  (\($0.items))" }.joined(separator: "\n") }
}

struct DownloadResult: Output {
    let folder: String
    let saved: [String]
    let skipped: [String]
    let failed: [String]
    let bytes: Int
    var text: String {
        "saved \(saved.count) file(s), \(humanBytes(bytes)) to \(folder)" + (skipped.isEmpty ? "" : "; skipped \(skipped.count) already there")
            + (failed.isEmpty ? "" : "; failed: " + failed.joined(separator: ", "))
    }
}

struct DeleteResult: Output {
    let deleted: [String]
    var text: String { "moved \(deleted.count) item(s) to Recently Deleted" }
}

func humanBytes(_ b: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
}

// MARK: - Commands

private func photosCommands(_ ctx: Context) -> [Command] {
    let kind = Param("kind", "photo or video")
    return [
        Command(["photos", "stats"], .read, "Library totals: items, photos, videos, size of originals, date range.") { _ in
            try PhotosStore(ctx).stats()
        },
        Command(["photos", "storage"], .read, "Size of originals broken down by year or by kind.",
                [Param("by", "year (default) or kind")]) { a in
            try PhotosStore(ctx).storage(by: a.string("by") ?? "year")
        },
        Command(["photos", "top"], .read, "Largest items by original file size.",
                [Param("limit", .integer, "Max (default 20)"), kind]) { a in
            PhotoList(items: try PhotosStore(ctx).items(kind: a.string("kind"), album: nil, since: nil, order: .size, limit: a.int("limit", 20)))
        },
        Command(["photos", "videos"], .read, "Largest videos, with duration.",
                [Param("limit", .integer, "Max (default 20)")]) { a in
            PhotoList(items: try PhotosStore(ctx).items(kind: "video", album: nil, since: nil, order: .size, limit: a.int("limit", 20)))
        },
        Command(["photos", "list"], .read, "Items newest first, optionally from one album, since a date, or of one kind.",
                [Param("album", "Album name"), Param("since", "YYYY-MM-DD, today, yesterday, 7d"), kind, Param("limit", .integer, "Max (default 50)")]) { a in
            PhotoList(items: try PhotosStore(ctx).items(kind: a.string("kind"), album: a.string("album"),
                                                        since: try a.string("since").map(parseSince), order: .date, limit: a.int("limit", 50)))
        },
        Command(["photos", "albums"], .read, "Your albums with item counts.") { _ in
            AlbumList(albums: try PhotosStore(ctx).albums())
        },
        Command(["photos", "download"], .write, "Download full-size originals (from iCloud if needed) into a folder. Refuses if it would leave too little free disk space.",
                [Param("ids", required: true, positional: true, "Item IDs, space or comma separated"),
                 Param("to", required: true, "Destination folder, created if missing. Over MCP it is a folder name under ~/Downloads/apple-cli")]) { a in
            let ids = try a.require("ids").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            // Privacy check first: a hidden or missing ID fails before PhotoKit is ever asked for access.
            let items = try PhotosStore(ctx).resolve(ids)
            let to = try PhotosWriter.destination(try a.require("to"), agent: a.viaMCP)
            let floor = try ctx.settings(PhotosSettings.self).minFreeGBAfterDownload
            return try await PhotosWriter().download(items, to: to, minFreeGB: floor)
        },
        Command(["photos", "delete"], .destructive, "Move items to Recently Deleted. macOS asks you to confirm in its own dialog every time.",
                [Param("ids", required: true, positional: true, "Item IDs, space or comma separated")]) { a in
            let ids = try a.require("ids").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            let items = try PhotosStore(ctx).resolve(ids)
            FileHandle.standardError.write(Data(("About to move to Recently Deleted:\n" + items.map { "  " + $0.line }.joined(separator: "\n")
                                                 + "\nmacOS will ask you to confirm.\n").utf8))
            return DeleteResult(deleted: try await PhotosWriter().delete(items))
        },
    ]
}

// MARK: - Store

final class PhotosStore {
    enum Order { case size, date }

    let db: SQLiteReader
    let libraryPath: String
    let settings: PhotosSettings
    private var ent: [String: Int] = [:]
    private var albumJoin: (table: String, album: String, asset: String)?
    /// PKs of excluded albums, matched in Swift with the same case folding used everywhere else.
    private var excludedAlbumPKs: [Int] = []

    static let schema: [String: [String]] = [
        "ZASSET": ["Z_PK", "ZUUID", "ZKIND", "ZKINDSUBTYPE", "ZDATECREATED", "ZTRASHEDSTATE", "ZHIDDEN", "ZVISIBILITYSTATE",
                   "ZFAVORITE", "ZWIDTH", "ZHEIGHT", "ZDURATION", "ZFILENAME", "ZSAVEDASSETTYPE"],
        "ZADDITIONALASSETATTRIBUTES": ["ZASSET", "ZORIGINALFILESIZE", "ZORIGINALFILENAME"],
        "ZGENERICALBUM": ["Z_PK", "Z_ENT", "ZUUID", "ZTITLE", "ZKIND", "ZTRASHEDSTATE"],
        "Z_PRIMARYKEY": ["Z_ENT", "Z_NAME"],
    ]

    init(_ ctx: Context) throws {
        settings = try ctx.settings(PhotosSettings.self)
        libraryPath = try Self.findLibrary(settings.libraryPath)
        db = try SQLiteReader(path: libraryPath + "/database/Photos.sqlite", allowCopy: false)
        try db.require(Self.schema)
        for r in try db.query("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY") { ent[r.str("Z_NAME") ?? ""] = r.int("Z_ENT") }
        // Album membership lives in Z_<Album entity>ASSETS with columns Z_<Album>ALBUMS and Z_<Asset>ASSETS.
        if let al = ent["Album"], let asx = ent["Asset"] {
            let t = "Z_\(al)ASSETS", a = "Z_\(al)ALBUMS", s = "Z_\(asx)ASSETS"
            let cols = Set(try db.query("SELECT name FROM pragma_table_info(?)", [t]).compactMap { $0.str("name") })
            if cols.contains(a) && cols.contains(s) { albumJoin = (t, a, s) }
        }
        if !settings.excludeAlbums.isEmpty {
            guard albumJoin != nil else { throw AppleError.schemaChanged("album membership table not found, so excludeAlbums cannot be applied") }
            let wanted = Set(settings.excludeAlbums.map { $0.lowercased() })
            excludedAlbumPKs = try db.query("SELECT Z_PK, ZTITLE FROM ZGENERICALBUM WHERE ZTITLE IS NOT NULL")
                .filter { wanted.contains(($0.str("ZTITLE") ?? "").lowercased()) }.compactMap { $0.int("Z_PK") }
        }
    }

    static func findLibrary(_ configured: String) throws -> String {
        let fm = FileManager.default
        if !configured.isEmpty {
            let p = (configured as NSString).expandingTildeInPath
            guard fm.fileExists(atPath: p + "/database/Photos.sqlite") else { throw AppleError.notFound("Photos library at \(p)") }
            return p
        }
        let pics = NSHomeDirectory() + "/Pictures"
        let preferred = pics + "/Photos.photoslibrary"
        if fm.fileExists(atPath: preferred + "/database/Photos.sqlite") { return preferred }
        let any = ((try? fm.contentsOfDirectory(atPath: pics)) ?? []).filter { $0.hasSuffix(".photoslibrary") }.sorted()
            .map { pics + "/" + $0 }.first { fm.fileExists(atPath: $0 + "/database/Photos.sqlite") }
        guard let any else { throw AppleError.notFound("Photos library in ~/Pictures. Set photos.libraryPath in the config.") }
        return any
    }

    /// The library as Photos shows it, minus privacy exclusions.
    private var visibleWhere: String {
        // Saved-asset type 12 is excluded because Photos.app does not count it (observed: 28,788 - 16 = 28,772, Photos' own count).
        var w = "z.ZTRASHEDSTATE = 0 AND z.ZVISIBILITYSTATE = 0 AND IFNULL(z.ZSAVEDASSETTYPE, 0) != 12"
        if !settings.includeHidden { w += " AND z.ZHIDDEN = 0" }
        if let j = albumJoin, !excludedAlbumPKs.isEmpty {
            // Integers only, so nothing user-supplied is spliced into SQL.
            w += " AND z.Z_PK NOT IN (SELECT \(j.asset) FROM \(j.table) WHERE \(j.album) IN (\(excludedAlbumPKs.map(String.init).joined(separator: ","))))"
        }
        return w
    }

    private static let select = """
        SELECT z.ZUUID, z.ZKIND, z.ZKINDSUBTYPE, z.ZDATECREATED, z.ZFAVORITE, z.ZWIDTH, z.ZHEIGHT, z.ZDURATION, z.ZFILENAME,
               a.ZORIGINALFILESIZE, a.ZORIGINALFILENAME
        FROM ZASSET z LEFT JOIN ZADDITIONALASSETATTRIBUTES a ON a.ZASSET = z.Z_PK
        """

    private func item(_ r: [String: Any]) -> PhotoItem {
        let k = r.int("ZKIND") ?? -1, st = r.int("ZKINDSUBTYPE") ?? 0
        let subtypes: [Int: String] = [1: "panorama", 2: "live", 10: "screenshot", 100: "slo-mo", 101: "time-lapse", 103: "screen recording"]
        return PhotoItem(id: r.str("ZUUID") ?? "", filename: r.str("ZORIGINALFILENAME") ?? r.str("ZFILENAME"),
                         kind: k == 0 ? "photo" : k == 1 ? "video" : "other", subtype: subtypes[st],
                         date: r.date("ZDATECREATED"), bytes: r.int("ZORIGINALFILESIZE"), width: r.int("ZWIDTH"), height: r.int("ZHEIGHT"),
                         duration: k == 1 ? (r["ZDURATION"] as? Double) : nil, favorite: r.bool("ZFAVORITE"))
    }

    func stats() throws -> PhotoStats {
        let r = try db.query("""
            SELECT COUNT(*) AS N, SUM(z.ZKIND = 0) AS P, SUM(z.ZKIND = 1) AS V, SUM(a.ZORIGINALFILESIZE) AS B,
                   MIN(z.ZDATECREATED) AS A, MAX(z.ZDATECREATED) AS Z, SUM(z.ZFAVORITE) AS F
            FROM ZASSET z LEFT JOIN ZADDITIONALASSETATTRIBUTES a ON a.ZASSET = z.Z_PK WHERE \(visibleWhere)
            """).first ?? [:]
        let x = try db.query("SELECT SUM(ZHIDDEN = 1 AND ZTRASHEDSTATE = 0) AS H, SUM(ZTRASHEDSTATE = 1) AS T FROM ZASSET").first ?? [:]
        return PhotoStats(items: r.int("N") ?? 0, photos: r.int("P") ?? 0, videos: r.int("V") ?? 0, bytes: r.int("B") ?? 0,
                          oldest: r.date("A"), newest: r.date("Z"), favorites: r.int("F") ?? 0,
                          hidden: settings.includeHidden ? 0 : (x.int("H") ?? 0), recentlyDeleted: x.int("T") ?? 0)
    }

    func storage(by: String) throws -> PhotoStorage {
        let key: String
        switch by {
        case "year": key = "strftime('%Y', z.ZDATECREATED + 978307200, 'unixepoch', 'localtime')"
        case "kind": key = "CASE z.ZKIND WHEN 0 THEN 'photo' WHEN 1 THEN 'video' ELSE 'other' END"
        default: throw AppleError.invalid("by must be year or kind")
        }
        let rows = try db.query("""
            SELECT \(key) AS K, COUNT(*) AS N, IFNULL(SUM(a.ZORIGINALFILESIZE), 0) AS B
            FROM ZASSET z LEFT JOIN ZADDITIONALASSETATTRIBUTES a ON a.ZASSET = z.Z_PK WHERE \(visibleWhere)
            GROUP BY K ORDER BY \(by == "year" ? "K" : "B DESC")
            """).map { StorageRow(key: $0.str("K") ?? "unknown", items: $0.int("N") ?? 0, bytes: $0.int("B") ?? 0) }
        return PhotoStorage(by: by, rows: rows, total: rows.reduce(0) { $0 + $1.bytes })
    }

    func items(kind: String?, album: String?, since: Date?, order: Order, limit: Int) throws -> [PhotoItem] {
        var w = visibleWhere
        var params: [Any] = []
        switch kind?.lowercased() {
        case nil: break
        case "photo": w += " AND z.ZKIND = 0"
        case "video": w += " AND z.ZKIND = 1"
        default: throw AppleError.invalid("kind must be photo or video")
        }
        if let since { w += " AND z.ZDATECREATED >= ?"; params.append(since.timeIntervalSinceReferenceDate) }
        if let album {
            guard let j = albumJoin else { throw AppleError.schemaChanged("album membership table not found") }
            let pk = try albumPK(album)
            w += " AND z.Z_PK IN (SELECT \(j.asset) FROM \(j.table) WHERE \(j.album) = ?)"
            params.append(pk)
        }
        let by = order == .size ? "a.ZORIGINALFILESIZE DESC" : "z.ZDATECREATED DESC"
        return try db.query("\(Self.select) WHERE \(w) ORDER BY \(by) LIMIT \(max(1, limit))", params).map(item)
    }

    /// User albums only (kind 2). Excluded albums get the same not_found as missing ones.
    private func albumPK(_ name: String) throws -> Int {
        if settings.excludeAlbums.contains(where: { $0.lowercased() == name.lowercased() }) { throw AppleError.notFound("album \(name)") }
        let pks = try db.query("SELECT Z_PK, ZTITLE FROM ZGENERICALBUM WHERE ZKIND = 2 AND ZTRASHEDSTATE = 0 AND ZTITLE IS NOT NULL")
            .filter { ($0.str("ZTITLE") ?? "").lowercased() == name.lowercased() }.compactMap { $0.int("Z_PK") }
            .filter { !excludedAlbumPKs.contains($0) }
        guard pks.count == 1 else {
            throw pks.isEmpty ? AppleError.notFound("album \(name)") : AppleError.invalid("\(pks.count) albums are named \(name)")
        }
        return pks[0]
    }

    func albums() throws -> [AlbumInfo] {
        guard let j = albumJoin else { throw AppleError.schemaChanged("album membership table not found") }
        let hidden = Set(settings.excludeAlbums.map { $0.lowercased() })
        return try db.query("""
            SELECT g.ZUUID, g.ZTITLE, (SELECT COUNT(*) FROM \(j.table) m JOIN ZASSET z ON z.Z_PK = m.\(j.asset)
                                      WHERE m.\(j.album) = g.Z_PK AND \(visibleWhere)) AS N
            FROM ZGENERICALBUM g WHERE g.ZKIND = 2 AND g.ZTRASHEDSTATE = 0 AND g.ZTITLE IS NOT NULL ORDER BY g.ZTITLE
            """).compactMap { r in
            guard let name = r.str("ZTITLE"), !hidden.contains(name.lowercased()) else { return nil }
            return AlbumInfo(id: r.str("ZUUID") ?? "", name: name, items: r.int("N") ?? 0)
        }
    }

    /// Maps IDs to visible items. A hidden, trashed, or excluded item gets not_found, like a missing one.
    func resolve(_ ids: [String]) throws -> [PhotoItem] {
        guard !ids.isEmpty, ids.count <= 500 else { throw AppleError.invalid("give between 1 and 500 IDs") }
        let clean = ids.map { $0.components(separatedBy: "/").first ?? $0 }
        let marks = clean.map { _ in "?" }.joined(separator: ",")
        let found = try db.query("\(Self.select) WHERE \(visibleWhere) AND z.ZUUID IN (\(marks))", clean).map(item)
        let missing = Set(clean).subtracting(found.map(\.id))
        if !missing.isEmpty { throw AppleError.notFound("photo \(missing.sorted().joined(separator: ", "))") }
        return found
    }
}

// MARK: - Write path (PhotoKit -> photolibraryd -> cloudphotod)

final class PhotosWriter {
    init() async throws {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return
        case .notDetermined:
            let st = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if st != .authorized { throw AppleError.permission("Photos full access was not granted") }
        default:
            throw AppleError.permission("allow full Photos access for this app in System Settings > Privacy & Security > Photos")
        }
    }

    private func assets(_ items: [PhotoItem]) throws -> [PHAsset] {
        let r = PHAsset.fetchAssets(withLocalIdentifiers: items.map { $0.id + "/L0/001" }, options: nil)
        var out: [PHAsset] = []
        r.enumerateObjects { a, _, _ in out.append(a) }
        guard out.count == items.count else { throw AppleError.notFound("\(items.count - out.count) item(s) not found through PhotoKit") }
        return out
    }

    static let agentRoot = NSHomeDirectory() + "/Downloads/apple-cli"

    /// CLI: any folder. MCP (an agent): only a folder inside ~/Downloads/apple-cli, checked after
    /// resolving symlinks, so an agent cannot write into ~/Library, dotfiles, or elsewhere.
    static func destination(_ raw: String, agent: Bool) throws -> URL {
        guard agent else { return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL }
        // One plain folder name only: no separators, no "..", no leading dot.
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), name != "..", !name.hasPrefix(".") else {
            throw AppleError.refused("over MCP, to must be a single folder name; files go to \(agentRoot)/<name>")
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: agentRoot)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let dest = root.appendingPathComponent(name)
        // Refuse an existing symlink at the name (attributesOfItem does not follow the last component).
        if let type = (try? fm.attributesOfItem(atPath: dest.path))?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            throw AppleError.refused("\(dest.path) is a symlink")
        }
        if !fm.fileExists(atPath: dest.path) { try fm.createDirectory(at: dest, withIntermediateDirectories: false) }
        // Re-check after creation, on real (resolved) paths that now exist.
        let rootReal = root.resolvingSymlinksInPath().standardizedFileURL.path
        let destReal = dest.resolvingSymlinksInPath().standardizedFileURL
        guard destReal.deletingLastPathComponent().path == rootReal else {
            throw AppleError.refused("over MCP, downloads must stay inside \(agentRoot)")
        }
        return destReal
    }

    /// A plain file name: last path component only, no separators, no leading dot.
    static func safeName(_ s: String, fallback: String) -> String {
        var n = (s as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        while n.hasPrefix(".") { n.removeFirst() }
        return n.isEmpty ? fallback : n
    }

    func download(_ items: [PhotoItem], to dir: URL, minFreeGB: Double) async throws -> DownloadResult {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let need = items.reduce(0) { $0 + ($1.bytes ?? 0) }
        let free = (try dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])).volumeAvailableCapacityForImportantUsage ?? 0
        let floor = Int64(minFreeGB * 1_000_000_000)
        if free - Int64(need) < floor {
            throw AppleError.refused("downloading \(humanBytes(need)) would leave \(humanBytes(Int(max(0, free - Int64(need))))) free, under the \(minFreeGB) GB floor")
        }
        var saved: [String] = [], skipped: [String] = [], failed: [String] = [], bytes = 0
        for (asset, item) in zip(try assets(items), items) {
            let resources = PHAssetResource.assetResources(for: asset)
            // The original: photo, video, or full-size photo, in that order.
            guard let res = resources.first(where: { $0.type == .photo || $0.type == .video }) ?? resources.first(where: { $0.type == .fullSizePhoto }) else {
                failed.append(item.id); continue
            }
            let dest = dir.appendingPathComponent(Self.safeName(res.originalFilename, fallback: item.id))
            // lstat-style check: an existing file or any symlink (even dangling) at the name is left alone.
            if (try? FileManager.default.attributesOfItem(atPath: dest.path)) != nil { skipped.append(dest.lastPathComponent); continue }
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true
            // Write to a fresh temp name in the same folder, then move into place. The move fails rather
            // than overwrite or follow anything that appeared at the destination in the meantime.
            let tmp = dir.appendingPathComponent(".apple-cli-\(UUID().uuidString)")
            do {
                try await PHAssetResourceManager.default().writeData(for: res, toFile: tmp, options: opts)
                try FileManager.default.moveItem(at: tmp, to: dest)
                saved.append(dest.lastPathComponent)
                bytes += (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                failed.append("\(item.id) (\(error.localizedDescription))")
            }
        }
        return DownloadResult(folder: dir.path, saved: saved, skipped: skipped, failed: failed, bytes: bytes)
    }

    /// PhotoKit shows the system confirmation dialog. Cancelling there throws.
    func delete(_ items: [PhotoItem]) async throws -> [String] {
        let list = try assets(items) as NSArray
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(list) }
        } catch {
            throw AppleError.refused("delete was not confirmed or failed: \(error.localizedDescription)")
        }
        return items.map(\.id)
    }
}
