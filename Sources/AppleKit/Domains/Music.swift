import Foundation
import AppKit

// Music: read-only. Library.musicdb is AES-encrypted with an undocumented record format that
// changes between Music versions, so reads use Music's scripting dictionary instead, fetching
// each property for every track in one bulk call (never a `whose` search).

// MARK: - Domain

struct MusicSettings: DomainSettings {
    static let key = "music"
    /// Playlists hidden everywhere: the playlist itself, and its tracks in recent, top, and search.
    var excludePlaylists: [String]

    static let defaults = MusicSettings(excludePlaylists: [])
}

let musicDomain = Domain(name: "music", defaults: MusicSettings.defaults, commands: musicCommands, checks: { _ in
    let running = MusicStore.isRunning
    return [Check(domain: "music", name: "app", ok: true,
                  detail: running ? "Music is running; reads go through its scripting dictionary" : "Music is not running; commands need --launch",
                  fix: nil)]
})

// MARK: - Outputs

struct MusicTrack: Encodable {
    let id: String
    let name: String
    let artist: String
    let album: String
    let plays: Int
    let lastPlayed: Date?
    let seconds: Int
    var line: String {
        "\(name) - \(artist)  [\(album)]  \(plays) plays" + (lastPlayed.map { ", last " + String(localISO.string(from: $0).prefix(10)) } ?? "")
    }
}
struct MusicTrackList: Output {
    let tracks: [MusicTrack]
    var text: String { tracks.isEmpty ? "no tracks" : tracks.map(\.line).joined(separator: "\n") }
}

struct MusicPlaylist: Encodable { let name: String; let tracks: Int }
struct MusicPlaylistList: Output {
    let playlists: [MusicPlaylist]
    var text: String { playlists.map { "\($0.name)  (\($0.tracks) tracks)" }.joined(separator: "\n") }
}

struct MusicNow: Output {
    let state: String
    let track: MusicTrack?
    var text: String { track.map { "\(state): \($0.name) - \($0.artist)" } ?? state }
}

// MARK: - Commands

private func musicCommands(_ ctx: Context) -> [Command] {
    let launch = Param("launch", .boolean, "Open Music if it is not running")
    let limit = Param("limit", .integer, "Max (default 20)")
    return [
        Command(["music", "recent"], .read, "Recently played tracks, newest first.", [limit, launch]) { a in
            let all = try MusicStore.tracks(ctx, launch: a.bool("launch"))
            return MusicTrackList(tracks: Array(all.filter { $0.lastPlayed != nil }.sorted { $0.lastPlayed! > $1.lastPlayed! }.prefix(a.int("limit", 20))))
        },
        Command(["music", "top"], .read, "Most-played tracks.", [limit, launch]) { a in
            let all = try MusicStore.tracks(ctx, launch: a.bool("launch"))
            return MusicTrackList(tracks: Array(all.sorted { ($0.plays, $1.name) > ($1.plays, $0.name) }.prefix(a.int("limit", 20))))
        },
        Command(["music", "search"], .read, "Search track names, artists, and albums.",
                [Param("query", required: true, positional: true, "Text to find"), limit, launch]) { a in
            let q = try a.require("query")
            let hit = { (s: String) in s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            let all = try MusicStore.tracks(ctx, launch: a.bool("launch"))
            return MusicTrackList(tracks: Array(all.filter { hit($0.name) || hit($0.artist) || hit($0.album) }
                .sorted { $0.plays > $1.plays }.prefix(a.int("limit", 20))))
        },
        Command(["music", "playlists"], .read, "Your playlists with track counts.", [launch]) { a in
            let hidden = Set(try ctx.settings(MusicSettings.self).excludePlaylists.map { $0.lowercased() })
            return MusicPlaylistList(playlists: try MusicStore.playlists(launch: a.bool("launch")).filter { !hidden.contains($0.name.lowercased()) })
        },
        Command(["music", "now"], .read, "Player state and the current track.", [launch]) { a in
            try MusicStore.now(launch: a.bool("launch"))
        },
    ]
}

// MARK: - Store

enum MusicStore {
    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty }

    /// Runs JXA that prints JSON. Refuses to start Music unless asked, since that opens a window.
    private static func jxa(_ script: String, launch: Bool) throws -> Any {
        guard isRunning || launch else { throw AppleError.refused("Music is not running. Pass --launch to open it") }
        let r = try runProcess("/usr/bin/osascript", ["-l", "JavaScript", "-"], stdin: Data(script.utf8), timeout: 30, what: "Music")
        guard r.status == 0 else {
            if r.err.contains("-1743") { throw AppleError.permission("allow control of Music in System Settings > Privacy & Security > Automation") }
            throw AppleError.app("Music: \(r.err)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) else { throw AppleError.app("Music returned unreadable output") }
        return obj
    }

    /// Every library track: each property is fetched for all tracks at once, then zipped.
    /// Tracks in an excluded playlist are dropped; a lookup that fails fails the command.
    static func tracks(_ ctx: Context, launch: Bool) throws -> [MusicTrack] {
        let excluded = try ctx.settings(MusicSettings.self).excludePlaylists
        let names = String(decoding: try JSONSerialization.data(withJSONObject: excluded), as: UTF8.self)
        let obj = try jxa("""
            const m = Application("Music"); const t = m.libraryPlaylists[0].tracks;
            const want = \(names).map(s => s.toLowerCase());
            const pl = m.userPlaylists(); const pn = m.userPlaylists.name();
            let hide = [];
            pn.forEach((n, i) => { if (want.includes(n.toLowerCase())) hide = hide.concat(pl[i].tracks.persistentID()); });
            JSON.stringify({id: t.persistentID(), n: t.name(), a: t.artist(), al: t.album(), pc: t.playedCount(),
                            pd: t.playedDate().map(d => d ? d.getTime() / 1000 : null), d: t.duration(), hide: hide})
            """, launch: launch)
        guard let o = obj as? [String: Any], let ids = o["id"] as? [String] else { throw AppleError.app("Music returned no tracks") }
        func col<T>(_ k: String) -> [T?] { (o[k] as? [Any] ?? []).map { $0 as? T } }
        let n: [String?] = col("n"), a: [String?] = col("a"), al: [String?] = col("al")
        let pc: [Int?] = col("pc"), pd: [Double?] = col("pd"), d: [Double?] = col("d")
        let hide = Set(o["hide"] as? [String] ?? [])
        return ids.indices.filter { !hide.contains(ids[$0]) }.map { i in
            MusicTrack(id: ids[i], name: n[safe: i]?.flatMap { $0 } ?? "", artist: a[safe: i]?.flatMap { $0 } ?? "",
                       album: al[safe: i]?.flatMap { $0 } ?? "", plays: pc[safe: i]?.flatMap { $0 } ?? 0,
                       lastPlayed: pd[safe: i]?.flatMap { $0 }.map { Date(timeIntervalSince1970: $0) },
                       seconds: Int((d[safe: i]?.flatMap { $0 } ?? 0).rounded()))
        }
    }

    static func playlists(launch: Bool) throws -> [MusicPlaylist] {
        let obj = try jxa("""
            const p = Application("Music").userPlaylists;
            JSON.stringify({n: p.name(), c: p().map(x => x.tracks.length)})
            """, launch: launch)
        guard let o = obj as? [String: Any], let n = o["n"] as? [String], let c = o["c"] as? [Int] else { return [] }
        return zip(n, c).map { MusicPlaylist(name: $0, tracks: $1) }
    }

    static func now(launch: Bool) throws -> MusicNow {
        let obj = try jxa("""
            const m = Application("Music"); const s = m.playerState();
            let t = null;
            // A radio stream has no library track behind it, so each property is read on its own.
            const g = f => { try { return f(); } catch (e) { return null; } };
            if (s !== "stopped") { const c = m.currentTrack;
              t = {id: g(() => c.persistentID()), n: g(() => c.name()) || g(() => m.currentStreamTitle()), a: g(() => c.artist()),
                   al: g(() => c.album()), pc: g(() => c.playedCount()), d: g(() => c.duration())}; }
            JSON.stringify({s: s, t: t})
            """, launch: launch)
        guard let o = obj as? [String: Any] else { throw AppleError.app("Music returned no state") }
        let t = (o["t"] as? [String: Any]).map {
            MusicTrack(id: $0["id"] as? String ?? "", name: $0["n"] as? String ?? "", artist: $0["a"] as? String ?? "",
                       album: $0["al"] as? String ?? "", plays: $0["pc"] as? Int ?? 0, lastPlayed: nil,
                       seconds: Int((($0["d"] as? Double) ?? 0).rounded()))
        }
        return MusicNow(state: o["s"] as? String ?? "unknown", track: t)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
