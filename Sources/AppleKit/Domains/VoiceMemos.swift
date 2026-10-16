import Foundation

// Voice Memos: read-only. Recordings come from CloudRecordings.db (Core Data, synced by
// CloudKit); transcripts live inside each .m4a as a `tsrp` atom holding JSON.

// MARK: - Domain

struct VoiceMemosSettings: DomainSettings {
    static let key = "voicememos"
    /// Regexes matched against recording titles. Matches never print, and their transcripts are never read.
    var excludeTitlePatterns: [String]
    var excludeIDs: [String]

    static let defaults = VoiceMemosSettings(excludeTitlePatterns: [#"(?i)\b(therapy|therapist|journal)\b"#], excludeIDs: [])
}

let voiceMemosDomain = Domain(name: "voicememos", defaults: VoiceMemosSettings.defaults, commands: voiceMemosCommands, checks: { ctx in
    let t = Date()
    do {
        let all = try VoiceMemosStore(ctx).recordings()
        return [Check(domain: "voicememos", name: "store", ok: true,
                      detail: "\(all.count) recordings readable, schema matches, \(Int(Date().timeIntervalSince(t) * 1000)) ms", fix: nil)]
    } catch {
        let e = AppleError.wrap(error)
        return [Check(domain: "voicememos", name: "store", ok: false, detail: e.description,
                      fix: e.code == "permission" ? "System Settings > Privacy & Security > Full Disk Access" : nil)]
    }
})

// MARK: - Outputs

struct Recording: Encodable {
    let id: String
    let title: String
    let date: Date?
    let seconds: Double
    /// Nil when the audio is still only in iCloud.
    let audioPath: String?
    let hasTranscript: Bool
    var line: String {
        let when = date.map { String(localISO.string(from: $0).prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? ""
        return "\(when)  \(title)  \(Int(seconds.rounded()))s\(hasTranscript ? "  (transcript)" : "")\(audioPath == nil ? "  (in iCloud only)" : "")  id \(id)"
    }
}
struct RecordingList: Output {
    let recordings: [Recording]
    let hidden: Int
    var text: String { (recordings.isEmpty ? "no recordings" : recordings.map(\.line).joined(separator: "\n")) + (hidden > 0 ? "\n(\(hidden) hidden)" : "") }
}

struct TranscriptSegment: Encodable { let start: Double; let text: String }
struct RecordingDetail: Output {
    let recording: Recording
    let transcript: String?
    let segments: [TranscriptSegment]?
    var text: String {
        var out = [recording.line, ""]
        if let segments, !segments.isEmpty {
            out += segments.map { String(format: "[%d:%02d] ", Int($0.start) / 60, Int($0.start) % 60) + $0.text }
        } else {
            out.append(transcript ?? "(no transcript)")
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Commands

private func voiceMemosCommands(_ ctx: Context) -> [Command] {
    [
        Command(["voicememos", "list"], .read, "Recordings, newest first, with length and whether a transcript exists.",
                [Param("limit", .integer, "Max (default 50)")]) { a in
            let s = try VoiceMemosStore(ctx)
            let all = try s.recordings()
            return RecordingList(recordings: Array(all.prefix(a.int("limit", 50))), hidden: s.hiddenCount)
        },
        Command(["voicememos", "read"], .read, "One recording with its transcript, split into timed sentences.",
                [Param("id", required: true, positional: true, "Recording ID from list")]) { a in
            try VoiceMemosStore(ctx).read(try a.require("id"))
        },
        Command(["voicememos", "search"], .read, "Search recording titles and transcripts, newest first.",
                [Param("query", required: true, positional: true, "Text to find"), Param("limit", .integer, "Max (default 20)")]) { a in
            let s = try VoiceMemosStore(ctx)
            return RecordingList(recordings: try s.search(try a.require("query"), limit: a.int("limit", 20)), hidden: 0)
        },
    ]
}

// MARK: - Store

final class VoiceMemosStore {
    static let dir = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
    static let schema: [String: [String]] = [
        "ZCLOUDRECORDING": ["ZUNIQUEID", "ZENCRYPTEDTITLE", "ZCUSTOMLABEL", "ZDATE", "ZDURATION", "ZPATH", "ZEVICTIONDATE"],
    ]

    let db: SQLiteReader
    let privacy: PrivacyFilter
    private(set) var hiddenCount = 0

    init(_ ctx: Context) throws {
        let s = try ctx.settings(VoiceMemosSettings.self)
        privacy = try PrivacyFilter(titlePatterns: s.excludeTitlePatterns, containers: [], ids: s.excludeIDs)
        db = try SQLiteReader(path: Self.dir + "/CloudRecordings.db")
        try db.require(Self.schema)
    }

    /// Visible recordings, newest first. Recordings in Recently Deleted (eviction date set) are left out.
    func recordings() throws -> [Recording] {
        var out: [Recording] = []
        hiddenCount = 0
        for r in try db.query("""
            SELECT ZUNIQUEID, ZENCRYPTEDTITLE, ZCUSTOMLABEL, ZDATE, ZDURATION, ZPATH FROM ZCLOUDRECORDING
            WHERE ZEVICTIONDATE IS NULL ORDER BY ZDATE DESC
            """) {
            guard let id = r.str("ZUNIQUEID") else { continue }
            let title = r.str("ZENCRYPTEDTITLE").flatMap { $0.isEmpty ? nil : $0 } ?? r.str("ZCUSTOMLABEL") ?? "New Recording"
            if privacy.hides(title: title, containers: [], id: id) { hiddenCount += 1; continue }
            let path = r.str("ZPATH").map { Self.dir + "/" + $0 }.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            out.append(Recording(id: id, title: title, date: r.date("ZDATE"), seconds: (r["ZDURATION"] as? Double) ?? 0,
                                 audioPath: path, hasTranscript: path.map(Self.hasTranscript) ?? false))
        }
        return out
    }

    func read(_ id: String) throws -> RecordingDetail {
        guard let rec = try recordings().first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            if try !db.query("SELECT 1 FROM ZCLOUDRECORDING WHERE ZUNIQUEID = ? COLLATE NOCASE", [id]).isEmpty { throw AppleError.hidden("recording \(id)") }
            throw AppleError.notFound("recording \(id)")
        }
        let t = rec.audioPath.flatMap(Self.transcript)
        return RecordingDetail(recording: rec, transcript: t?.text, segments: t?.segments)
    }

    func search(_ q: String, limit: Int) throws -> [Recording] {
        var out: [Recording] = []
        for rec in try recordings() {
            let hit = rec.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || (rec.audioPath.flatMap(Self.transcript)?.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
            if hit { out.append(rec) }
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: Transcripts

    /// Finds the payload of the `tsrp` box by walking MP4 boxes. Voice Memos puts it in the
    /// audio track's user data (`moov/trak/udta/tsrp`); `moov/udta/tsrp` is checked too.
    static func tsrpPayload(_ path: String) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        func box(at off: UInt64) -> (size: UInt64, type: String, header: UInt64)? {
            try? fh.seek(toOffset: off)
            guard let h = try? fh.read(upToCount: 16), h.count >= 8 else { return nil }
            var size = UInt64(h[0]) << 24 | UInt64(h[1]) << 16 | UInt64(h[2]) << 8 | UInt64(h[3])
            let type = String(decoding: h[4..<8], as: UTF8.self)
            var header: UInt64 = 8
            if size == 1, h.count >= 16 { size = h[8..<16].reduce(0) { $0 << 8 | UInt64($1) }; header = 16 }
            if size == 0 { size = (try? fh.seekToEnd()).map { $0 - off } ?? 0 }
            return size >= header ? (size, type, header) : nil
        }
        func find(_ path: [String], from start: UInt64, to end: UInt64) -> Data? {
            var off = start
            while off + 8 <= end, let b = box(at: off) {
                if b.type == path[0] {
                    if path.count == 1 {
                        try? fh.seek(toOffset: off + b.header)
                        let n = Int(b.size - b.header)
                        return n > 0 && n < 50_000_000 ? try? fh.read(upToCount: n) : nil
                    }
                    if let d = find(Array(path.dropFirst()), from: off + b.header, to: off + b.size) { return d }
                }
                off += b.size
            }
            return nil
        }
        let end = (try? fh.seekToEnd()) ?? 0
        return find(["moov", "trak", "udta", "tsrp"], from: 0, to: end) ?? find(["moov", "udta", "tsrp"], from: 0, to: end)
    }

    static func hasTranscript(_ path: String) -> Bool { tsrpPayload(path) != nil }

    /// The transcript is an attributed string as JSON: `runs` alternates text and an index into
    /// `attributeTable`, whose entries carry each word's `timeRange` in seconds.
    static func transcript(_ path: String) -> (text: String, segments: [TranscriptSegment])? {
        guard let d = tsrpPayload(path),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let a = j["attributedString"] as? [String: Any], let runs = a["runs"] as? [Any] else { return nil }
        let table = a["attributeTable"] as? [[String: Any]] ?? []
        var text = "", segments: [TranscriptSegment] = [], current = "", start: Double?
        var i = 0
        while i < runs.count {
            guard let s = runs[i] as? String else { i += 1; continue }
            let idx = i + 1 < runs.count ? runs[i + 1] as? Int : nil
            let t = idx.flatMap { $0 < table.count ? (table[$0]["timeRange"] as? [Double])?.first : nil }
            text += s
            if start == nil, !s.trimmingCharacters(in: .whitespaces).isEmpty { start = t }
            current += s
            if s.trimmingCharacters(in: .whitespaces).last.map({ ".?!".contains($0) }) == true {
                segments.append(TranscriptSegment(start: start ?? 0, text: current.trimmingCharacters(in: .whitespaces)))
                current = ""; start = nil
            }
            i += 2
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            segments.append(TranscriptSegment(start: start ?? 0, text: current.trimmingCharacters(in: .whitespaces)))
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), segments)
    }
}
