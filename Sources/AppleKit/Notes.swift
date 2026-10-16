import Foundation

// MARK: - Fast read path (NoteStore.sqlite, read-only)

public struct NoteRow {
    public let pk: Int
    public let id: String?            // ZIDENTIFIER, stable across devices
    public let title: String?
    public let snippet: String?
    public let folder: String?
    public let folderPath: [String]   // folder, then each parent folder up to the top
    public let folderIsTrash: Bool
    public let created: Date?
    public let modified: Date?
    public let pinned: Bool
    public let locked: Bool           // password protected, body is encrypted
    public let downloaded: Bool       // false = Notes has not fetched the body from iCloud yet
    public let synced: Bool           // CloudKit returned a server record for this note
    public let hasChecklist: Bool
    public let body: Data?            // gzipped protobuf from ZICNOTEDATA

    /// The ID Notes.app's AppleScript dictionary uses for this note.
    public func scriptID(storeUUID: String) -> String { "x-coredata://\(storeUUID)/ICNote/p\(pk)" }

    public func summary() -> [String: Any] {
        [
            "id": id ?? NSNull(), "pk": pk, "title": title ?? NSNull(), "folder": folder ?? NSNull(),
            "modified": isoString(modified), "created": isoString(created), "pinned": pinned,
            "downloaded": downloaded, "locked": locked, "synced": synced,
        ]
    }
}

public final class NotesStore {
    public static let defaultPath = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"

    let db: SQLiteReader
    let privacy: PrivacyFilter
    public let storeUUID: String
    private var ent: [String: Int] = [:]

    public init(path: String = NotesStore.defaultPath, privacy: PrivacyFilter) throws {
        db = try SQLiteReader(path: path)
        self.privacy = privacy
        storeUUID = try db.query("SELECT Z_UUID FROM Z_METADATA").first?.str("Z_UUID") ?? ""
        for r in try db.query("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY") {
            if let n = r.str("Z_NAME"), let e = r.int("Z_ENT") { ent[n] = e }
        }
    }

    private func e(_ name: String) -> Int { ent[name] ?? -1 }

    /// Every live note, newest first. Privacy-excluded notes are removed here,
    /// so nothing downstream can print them. Returns the hidden count too.
    public func allNotes(includeTrash: Bool = false) throws -> (notes: [NoteRow], hidden: Int) {
        let rows = try db.query("""
            SELECT n.Z_PK, n.ZIDENTIFIER, n.ZTITLE1, n.ZSNIPPET, n.ZCREATIONDATE3, n.ZMODIFICATIONDATE1,
                   n.ZISPINNED, n.ZISPASSWORDPROTECTED, n.ZNEEDSINITIALFETCHFROMCLOUD, n.ZHASCHECKLIST,
                   n.ZSERVERRECORDDATA IS NOT NULL AS SYNCED, n.ZFOLDER,
                   f.ZTITLE2 AS FOLDER, f.ZFOLDERTYPE AS FOLDERTYPE, d.ZDATA
            FROM ZICCLOUDSYNCINGOBJECT n
            LEFT JOIN ZICNOTEDATA d ON d.Z_PK = n.ZNOTEDATA
            LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER
            WHERE n.Z_ENT = ? AND IFNULL(n.ZMARKEDFORDELETION, 0) = 0
            ORDER BY n.ZMODIFICATIONDATE1 DESC
            """, [e("ICNote")])
        let paths = try folderPaths()
        var notes: [NoteRow] = []
        var hidden = 0
        for r in rows {
            let n = NoteRow(
                pk: r.int("Z_PK") ?? 0, id: r.str("ZIDENTIFIER"), title: r.str("ZTITLE1"),
                snippet: r.str("ZSNIPPET"), folder: r.str("FOLDER"),
                folderPath: r.int("ZFOLDER").flatMap { paths[$0] } ?? [], folderIsTrash: r.int("FOLDERTYPE") == 1,
                created: r.date("ZCREATIONDATE3"), modified: r.date("ZMODIFICATIONDATE1"),
                pinned: r.bool("ZISPINNED"), locked: r.bool("ZISPASSWORDPROTECTED"),
                downloaded: !r.bool("ZNEEDSINITIALFETCHFROMCLOUD") && r.data("ZDATA") != nil,
                synced: r.bool("SYNCED"), hasChecklist: r.bool("ZHASCHECKLIST"), body: r.data("ZDATA"))
            if n.folderIsTrash && !includeTrash { continue }
            if privacy.excludes(note: n) { hidden += 1; continue }
            notes.append(n)
        }
        return (notes, hidden)
    }

    /// Finds one note by ZIDENTIFIER, Z_PK, `p<pk>`, or full x-coredata ID.
    /// Throws `.excluded` for a hidden note so callers never print it.
    public func find(_ ref: String, includeTrash: Bool = false) throws -> NoteRow {
        let pk: Int? = {
            if let i = Int(ref) { return i }
            if let r = ref.range(of: "/ICNote/p") { return Int(ref[r.upperBound...]) }
            if ref.hasPrefix("p") { return Int(ref.dropFirst()) }
            return nil
        }()
        let rows = try db.query("SELECT Z_PK FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = ? AND (ZIDENTIFIER = ? OR Z_PK = ?)",
                                [e("ICNote"), ref, pk ?? -1])
        guard let wanted = rows.first?.int("Z_PK") else { throw AppleError.notFound("note \(ref)") }
        let all = try db.query("SELECT 1 FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ? AND IFNULL(ZMARKEDFORDELETION,0) = 0", [wanted])
        guard !all.isEmpty else { throw AppleError.notFound("note \(ref)") }
        let (notes, _) = try allNotes(includeTrash: true)
        if let n = notes.first(where: { $0.pk == wanted }) {
            if n.folderIsTrash && !includeTrash { throw AppleError.notFound("note \(ref) (it is in Recently Deleted)") }
            return n
        }
        throw AppleError.excluded("note \(ref)")
    }

    /// Folder pk -> its name followed by every ancestor's name. Nested folders link
    /// through ZPARENT, so an excluded parent hides everything below it.
    func folderPaths() throws -> [Int: [String]] {
        var node: [Int: (name: String, parent: Int?)] = [:]
        for r in try db.query("SELECT Z_PK, ZTITLE2, ZPARENT FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = ?", [e("ICFolder")]) {
            if let pk = r.int("Z_PK") { node[pk] = (r.str("ZTITLE2") ?? "", r.int("ZPARENT")) }
        }
        var out: [Int: [String]] = [:]
        for pk in node.keys {
            var chain: [String] = [], cur: Int? = pk, seen = Set<Int>()
            while let c = cur, let n = node[c], seen.insert(c).inserted { chain.append(n.name); cur = n.parent }
            out[pk] = chain
        }
        return out
    }

    public func folders() throws -> [[String: Any]] {
        let rows = try db.query("""
            SELECT f.Z_PK, f.ZIDENTIFIER, f.ZTITLE2, f.ZFOLDERTYPE,
              (SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT n WHERE n.Z_ENT = ? AND n.ZFOLDER = f.Z_PK
                 AND IFNULL(n.ZMARKEDFORDELETION,0) = 0) AS COUNT
            FROM ZICCLOUDSYNCINGOBJECT f WHERE f.Z_ENT = ? AND IFNULL(f.ZMARKEDFORDELETION,0) = 0
            """, [e("ICNote"), e("ICFolder")])
        let paths = try folderPaths()
        return rows.compactMap { r in
            guard let name = r.str("ZTITLE2"),
                  !(paths[r.int("Z_PK") ?? -1] ?? [name]).contains(where: privacy.excludes(folder:)) else { return nil }
            return ["pk": r.int("Z_PK") ?? 0, "id": r.str("ZIDENTIFIER") ?? NSNull(), "name": name,
                    "trash": r.int("ZFOLDERTYPE") == 1, "notes": r.int("COUNT") ?? 0]
        }
    }

    public func folderScriptID(named name: String) throws -> String {
        let rows = try db.query("""
            SELECT Z_PK FROM ZICCLOUDSYNCINGOBJECT
            WHERE Z_ENT = ? AND IFNULL(ZMARKEDFORDELETION,0) = 0 AND IFNULL(ZFOLDERTYPE,0) = 0 AND ZTITLE2 = ? COLLATE NOCASE
            """, [e("ICFolder"), name])
        guard rows.count == 1, let pk = rows[0].int("Z_PK") else {
            throw rows.isEmpty ? AppleError.notFound("folder \(name)") : AppleError.invalid("\(rows.count) folders are named \(name)")
        }
        return "x-coredata://\(storeUUID)/ICFolder/p\(pk)"
    }

    public func trashFolderScriptID() throws -> String {
        guard let pk = try db.query("SELECT Z_PK FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = ? AND ZFOLDERTYPE = 1 LIMIT 1",
                                    [e("ICFolder")]).first?.int("Z_PK") else { throw AppleError.notFound("Recently Deleted folder") }
        return "x-coredata://\(storeUUID)/ICFolder/p\(pk)"
    }

    /// Count of attachments (tables, images, hashtags, links) inside a note.
    /// Setting a body through AppleScript drops these, so append checks this first.
    public func attachmentCount(notePK: Int) throws -> Int {
        let rows = try db.query("""
            SELECT count(*) AS C FROM ZICCLOUDSYNCINGOBJECT
            WHERE IFNULL(ZMARKEDFORDELETION,0) = 0
              AND ((Z_ENT = ? AND ZNOTE = ?) OR (Z_ENT = ? AND ZNOTE1 = ?))
            """, [e("ICAttachment"), notePK, e("ICInlineAttachment"), notePK])
        return rows.first?.int("C") ?? 0
    }

    // MARK: Body decoding

    /// Plain text of a note body, or nil when the body is missing or not a protobuf.
    public func plainText(_ n: NoteRow) -> String? {
        guard let raw = n.body.flatMap(gunzip), let root = try? PB.parse(raw) else { return nil }
        return root.path(2, 3, 2)?.string
    }

    public func markdown(_ n: NoteRow) throws -> String {
        guard let raw = n.body.flatMap(gunzip), let root = try? PB.parse(raw),
              let note = root.path(2, 3) else {
            throw AppleError.invalid("note body is not in the protobuf format this tool reads")
        }
        return NoteMarkdown.render(note: note.message) { [weak self] ident, uti in
            self?.renderAttachment(identifier: ident, uti: uti, notePK: n.pk) ?? "[attachment]"
        }
    }

    /// Only attachments owned by this note resolve, so a body that names another
    /// note's attachment cannot pull in content from a hidden note.
    private func renderAttachment(identifier: String, uti: String, notePK: Int) -> String {
        guard let r = try? db.query("""
            SELECT ZTYPEUTI, ZTYPEUTI1, ZTITLE, ZURLSTRING, ZALTTEXT, ZMERGEABLEDATA1
            FROM ZICCLOUDSYNCINGOBJECT WHERE ZIDENTIFIER = ? AND (ZNOTE = ? OR ZNOTE1 = ?)
            """, [identifier, notePK, notePK]).first else { return "[attachment: \(uti)]" }
        let type = r.str("ZTYPEUTI") ?? r.str("ZTYPEUTI1") ?? uti
        switch type {
        case "com.apple.notes.inlinetextattachment.hashtag", "com.apple.notes.inlinetextattachment.mention":
            return r.str("ZALTTEXT") ?? ""
        case "com.apple.notes.inlinetextattachment.link":
            return "[\(r.str("ZALTTEXT") ?? "link")](\(r.str("ZURLSTRING") ?? ""))"
        case "com.apple.notes.table":
            if let data = r.data("ZMERGEABLEDATA1"), let grid = NoteTable.decode(data) { return NoteTable.markdown(grid) }
            return "[table]"
        case "public.url":
            let url = r.str("ZURLSTRING") ?? ""
            return "[\(r.str("ZTITLE") ?? url)](\(url))"
        default:
            return "[attachment: \(r.str("ZTITLE") ?? type)]"
        }
    }
}

// MARK: - Note protobuf -> Markdown

/// Field numbers: Note.2 text, Note.5 attribute runs.
/// Run: .1 length (UTF-16 units), .2 paragraph style, .5 font hints,
/// .7 strikethrough, .9 link, .12 attachment {.1 id, .2 uti}.
/// Paragraph style: .1 type, .4 indent, .5 checklist {.2 done}.
enum NoteMarkdown {
    struct Seg { var text: String; var style: [PBField]; var hints: UInt64; var strike: Bool; var link: String? }

    static func render(note: [PBField], attachment: (String, String) -> String) -> String {
        guard let textField = note.first(2) else { return "" }
        let utf16 = Array(textField.string.utf16)
        var segs: [Seg] = []
        var pos = 0
        for run in note.all(5) {
            let m = run.message
            let len = m.first(1)?.int ?? 0
            guard len > 0, pos < utf16.count else { continue }
            let end = len >= utf16.count - pos ? utf16.count : pos + len
            var text = String(decoding: utf16[pos..<end], as: UTF16.self)
            pos = end
            if let att = m.first(12)?.message {
                let ident = att.first(1)?.string ?? ""
                let uti = att.first(2)?.string ?? ""
                text = text.replacingOccurrences(of: "\u{FFFC}", with: attachment(ident, uti))
            }
            segs.append(Seg(text: text, style: m.first(2)?.message ?? [], hints: m.first(5)?.varint ?? 0,
                            strike: (m.first(7)?.varint ?? 0) != 0, link: m.first(9)?.string))
        }
        if pos < utf16.count { segs.append(Seg(text: String(decoding: utf16[pos...], as: UTF16.self), style: [], hints: 0, strike: false, link: nil)) }

        // Split into lines. A line takes the paragraph style of its first run.
        var lines: [(text: String, style: [PBField])] = []
        var cur = "", curStyle: [PBField]? = nil
        for s in segs {
            let parts = s.text.components(separatedBy: "\n")
            for (i, part) in parts.enumerated() {
                if i > 0 { lines.append((cur, curStyle ?? [])); cur = ""; curStyle = nil }
                if curStyle == nil && (!part.isEmpty || i < parts.count - 1) { curStyle = s.style }
                cur += inline(part, s)
            }
        }
        if !cur.isEmpty { lines.append((cur, curStyle ?? [])) }

        var out: [String] = []
        var inCode = false
        var numbers: [Int: Int] = [:]
        for (text, style) in lines {
            let type = style.first(1)?.int ?? 3
            let indent = min(style.first(4)?.int ?? 0, 10)
            let pad = String(repeating: "  ", count: indent)
            if type == 4 { if !inCode { out.append("```"); inCode = true }; out.append(text); continue }
            if inCode { out.append("```"); inCode = false }
            if type != 102 { numbers[indent] = nil }
            switch type {
            case 0: out.append("# " + text)
            case 1: out.append("## " + text)
            case 2: out.append("### " + text)
            case 100, 101: out.append(pad + "- " + text)
            case 102:
                let n = (numbers[indent] ?? 0) + 1
                numbers[indent] = n
                out.append(pad + "\(n). " + text)
            case 103:
                let done = (style.first(5)?.message.first(2)?.varint ?? 0) != 0
                out.append(pad + (done ? "- [x] " : "- [ ] ") + text)
            default: out.append(text)
            }
        }
        if inCode { out.append("```") }
        return out.joined(separator: "\n")
    }

    static func inline(_ t: String, _ s: Seg) -> String {
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return t }
        var x = t
        if s.hints & 1 != 0 { x = "**\(x)**" }
        if s.hints & 2 != 0 { x = "*\(x)*" }
        if s.strike { x = "~~\(x)~~" }
        if let l = s.link, !l.isEmpty { x = "[\(x)](\(l))" }
        return x
    }
}

// MARK: - Table attachments (ZMERGEABLEDATA1)

/// Decodes the CRDT document behind a Notes table.
/// Root.2.3 holds: .3 object entries, .4 key names, .5 type names, .6 UUIDs.
/// Entry: .6 dictionary, .10 note (cell text), .13 custom map {.1 type, .3 {.1 key, .2 value}},
/// .16 ordered set {.1 ordering {.1 array {.2 {.2 uuid}}, .2 contents dict}}.
/// Object ID: .2 integer, .4 string, .6 object index.
enum NoteTable {
    static func decode(_ blob: Data) -> [[String]]? {
        guard let raw = gunzip(blob) ?? Optional(blob), let root = try? PB.parse(raw),
              let data = root.path(2, 3)?.message else { return nil }
        let entries = data.all(3).map { $0.message }
        let keys = data.all(4).map { $0.string }
        let types = data.all(5).map { $0.string }
        let uuids = data.all(6).map { $0.bytes }

        func mapType(_ e: [PBField]) -> String? {
            guard let m = e.first(13)?.message, let t = m.first(1) else { return nil }
            let i = t.int; return i < types.count ? types[i] : nil
        }
        func mapValue(_ e: [PBField], _ key: String) -> [PBField]? {
            for me in e.first(13)?.message.all(3) ?? [] {
                let k = me.message.first(1)?.int ?? Int.max
                if k < keys.count, keys[k] == key { return me.message.first(2)?.message }
            }
            return nil
        }
        func entry(_ oid: [PBField]?) -> [PBField]? {
            guard let i = oid?.first(6)?.int, i < entries.count else { return nil }
            return entries[i]
        }
        // An NSUUID object is a custom map whose first value is an index into `uuids`.
        func uuidIndex(_ oid: [PBField]?) -> Int? {
            guard let e = entry(oid), let me = e.first(13)?.message.first(3) else { return nil }
            return me.message.first(2)?.message.first(2)?.int
        }
        func order(_ set: [PBField]) -> [Int: Int] {
            var pos: [Int: Int] = [:]
            guard let ordering = set.first(16)?.message.first(1)?.message else { return pos }
            var n = 0
            for att in ordering.first(1)?.message.all(2) ?? [] {
                if let u = att.message.first(2)?.bytes, let i = uuids.firstIndex(of: u) { pos[i] = n; n += 1 }
            }
            for el in ordering.first(2)?.message.all(1) ?? [] {
                let m = el.message
                if let k = uuidIndex(m.first(1)?.message), let v = uuidIndex(m.first(2)?.message), let p = pos[k] { pos[v] = p }
            }
            return pos
        }

        guard let table = entries.first(where: { mapType($0) == "com.apple.notes.ICTable" }),
              let rowsSet = entry(mapValue(table, "crRows")),
              let colsSet = entry(mapValue(table, "crColumns")),
              let cells = entry(mapValue(table, "cellColumns")) else { return nil }
        let rowPos = order(rowsSet), colPos = order(colsSet)
        let nRows = (rowPos.values.max() ?? -1) + 1, nCols = (colPos.values.max() ?? -1) + 1
        guard nRows > 0, nCols > 0 else { return nil }
        var grid = Array(repeating: Array(repeating: "", count: nCols), count: nRows)
        for col in cells.first(6)?.message.all(1) ?? [] {
            let cm = col.message
            guard let ci = uuidIndex(cm.first(1)?.message).flatMap({ colPos[$0] }),
                  let rowDict = entry(cm.first(2)?.message) else { continue }
            for cell in rowDict.first(6)?.message.all(1) ?? [] {
                let m = cell.message
                guard let ri = uuidIndex(m.first(1)?.message).flatMap({ rowPos[$0] }),
                      let note = entry(m.first(2)?.message)?.first(10)?.message else { continue }
                grid[ri][ci] = note.first(2)?.string ?? ""
            }
        }
        return grid
    }

    static func markdown(_ g: [[String]]) -> String {
        func row(_ r: [String]) -> String {
            "| " + r.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: " | ") + " |"
        }
        var out = [row(g[0]), "|" + String(repeating: " --- |", count: g[0].count)]
        out += g.dropFirst().map(row)
        return out.joined(separator: "\n")
    }
}

// MARK: - Write path (Notes.app scripting, one note or folder at a time)

/// Every call names one note or folder by ID. Nothing here uses `whose`
/// or enumerates notes, which is what makes plain osascript hang.
public enum NotesWriter {
    /// Runs AppleScript from stdin with arguments passed as argv, so user text
    /// is never spliced into script source.
    static func run(_ script: String, _ args: [String], timeout: TimeInterval = 15) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"] + args
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        try p.run()
        inPipe.fileHandleForWriting.write(script.data(using: .utf8)!)
        try inPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(5_000) }
        if p.isRunning { p.terminate(); throw AppleError.script("osascript timed out after \(Int(timeout))s") }
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0 else {
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if err.contains("-1743") { throw AppleError.permission("allow this app to control Notes in System Settings > Privacy & Security > Automation") }
            throw AppleError.script(err)
        }
        return out
    }

    /// Creates a note and returns Notes' x-coredata ID for it.
    public static func create(title: String, markdown: String, folderScriptID: String?) throws -> String {
        let html = "<div><h1>\(htmlEscape(title))</h1></div>" + (markdown.isEmpty ? "" : markdownToHTML(markdown))
        return try run("""
            on run argv
              tell application "Notes"
                if item 1 of argv is "" then
                  set f to default folder of default account
                else
                  set f to folder id (item 1 of argv)
                end if
                set n to make new note at f with properties {body:item 2 of argv}
                return id of n
              end tell
            end run
            """, [folderScriptID ?? "", html])
    }

    public static func append(noteScriptID: String, markdown: String) throws {
        _ = try run("""
            on run argv
              tell application "Notes"
                set n to note id (item 1 of argv)
                set body of n to (body of n) & (item 2 of argv)
              end tell
            end run
            """, [noteScriptID, markdownToHTML(markdown)])
    }

    /// Moves a note into the Recently Deleted folder. Notes keeps it there for 30 days.
    /// This uses `move`, not `delete`: Notes 4.13 holds a scripted delete in memory and
    /// only writes it to disk (and iCloud) on the next insert. A move is saved within 0.2 s.
    public static func trash(noteScriptID: String, trashFolderScriptID: String) throws {
        _ = try run("""
            on run argv
              tell application "Notes" to move note id (item 1 of argv) to folder id (item 2 of argv)
            end run
            """, [noteScriptID, trashFolderScriptID])
    }
}

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

/// Small Markdown -> Notes HTML converter: headings, bullets, numbers,
/// checkbox lines (as bullets), code blocks, bold, italic, strike, code, links.
public func markdownToHTML(_ md: String) -> String {
    func inline(_ s: String) -> String {
        var x = htmlEscape(s)
        let rules: [(String, String)] = [
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
            (#"\*\*(.+?)\*\*"#, "<b>$1</b>"),
            (#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, "<i>$1</i>"),
            (#"~~(.+?)~~"#, "<strike>$1</strike>"),
            (#"`([^`]+)`"#, "<tt>$1</tt>"),
        ]
        for (p, r) in rules { x = x.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        return x
    }
    var out = ""
    var list: String? = nil
    var code = false
    func closeList() { if let l = list { out += "</\(l)>"; list = nil } }
    for line in md.components(separatedBy: "\n") {
        if line.hasPrefix("```") { closeList(); code.toggle(); continue }
        if code { out += "<div><tt>\(htmlEscape(line))</tt></div>"; continue }
        let t = line.trimmingCharacters(in: .whitespaces)
        if let m = t.range(of: #"^(#{1,3}) "#, options: .regularExpression) {
            closeList()
            let level = t[m].filter { $0 == "#" }.count
            out += "<h\(level)>\(inline(String(t[m.upperBound...])))</h\(level)>"
        } else if let m = t.range(of: #"^[-*] (\[[ xX]\] )?"#, options: .regularExpression) {
            if list != "ul" { closeList(); out += "<ul>"; list = "ul" }
            out += "<li>\(inline(String(t[m.upperBound...])))</li>"
        } else if let m = t.range(of: #"^\d+[.)] "#, options: .regularExpression) {
            if list != "ol" { closeList(); out += "<ol>"; list = "ol" }
            out += "<li>\(inline(String(t[m.upperBound...])))</li>"
        } else {
            closeList()
            out += t.isEmpty ? "<div><br></div>" : "<div>\(inline(t))</div>"
        }
    }
    closeList()
    return out
}
