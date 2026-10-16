import Foundation

// The contract every app plugs into. See docs/architecture.md.

// MARK: - Errors with stable codes

public enum AppleError: Error, CustomStringConvertible {
    case database(String)
    case notFound(String)
    case invalid(String)
    case hidden(String)
    case refused(String)
    case app(String)
    case permission(String)
    case schemaChanged(String)
    case timeout(String)

    /// Agents branch on this, never on the message text.
    public var code: String {
        switch self {
        case .database: return "database"
        case .notFound: return "not_found"
        case .invalid: return "invalid"
        case .hidden: return "hidden"
        case .refused: return "refused"
        case .app: return "app_error"
        case .permission: return "permission"
        case .schemaChanged: return "schema_changed"
        case .timeout: return "timeout"
        }
    }

    public var description: String {
        switch self {
        case .database(let s): return "database error: \(s)"
        case .notFound(let s): return "not found: \(s)"
        case .invalid(let s): return "invalid input: \(s)"
        case .hidden(let s): return "hidden by privacy config: \(s)"
        case .refused(let s): return "refused: \(s)"
        case .app(let s): return "app error: \(s)"
        case .permission(let s): return "permission needed: \(s)"
        case .schemaChanged(let s): return "Apple changed the database layout (\(s)). Run `apple-cli doctor` and re-check this app's reader."
        case .timeout(let s): return "timed out: \(s)"
        }
    }

    static func wrap(_ e: Error) -> AppleError { (e as? AppleError) ?? .app("\(e)") }

    /// Rebuilds an error the mini sent back. Its message already carries the code's prefix, which is stripped.
    static func remote(code: String, message: String) -> AppleError {
        let makers: [(String) -> AppleError] = [AppleError.database, AppleError.notFound, AppleError.invalid, AppleError.hidden, AppleError.refused,
                                                AppleError.app, AppleError.permission, AppleError.schemaChanged, AppleError.timeout]
        guard let make = makers.first(where: { $0("").code == code }) else { return .app(message) }
        let prefix = make("").description
        return make(message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message)
    }
}

// MARK: - Commands

public enum Effect: String, Encodable {
    case read, write
    /// Never exposed over MCP. CLI only.
    case destructive
}

/// Every command returns a typed value. JSON comes from Encodable, human text from `text`.
/// Optional fields that are nil are left out of the JSON.
public protocol Output: Encodable {
    var text: String { get }
}

public struct Param {
    public enum Kind: String { case string, integer, boolean }
    let name: String
    let kind: Kind
    let required: Bool
    let positional: Bool
    let help: String
    init(_ name: String, _ kind: Kind = .string, required: Bool = false, positional: Bool = false, _ help: String) {
        self.name = name; self.kind = kind; self.required = required; self.positional = positional; self.help = help
    }
    init(_ name: String, _ help: String) { self.init(name, .string, help) }
}

public struct Command {
    public let path: [String]            // ["notes", "search"], or ["doctor"]
    public let help: String
    public let params: [Param]
    public let effect: Effect
    let run: (Args) async throws -> any Output

    init(_ path: [String], _ effect: Effect, _ help: String, _ params: [Param] = [], run: @escaping (Args) async throws -> any Output) {
        self.path = path; self.effect = effect; self.help = help; self.params = params; self.run = run
    }
    public var toolName: String { path.joined(separator: "_").replacingOccurrences(of: "-", with: "_") }
}

/// Typed access to parsed arguments from either the CLI or MCP.
public struct Args {
    let raw: [String: Any]
    /// True when the call came over MCP (an agent), so commands can apply tighter limits.
    var viaMCP = false
    func string(_ k: String) -> String? { (raw[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    func require(_ k: String) throws -> String {
        guard let v = string(k) else { throw AppleError.invalid("missing \(k)") }
        return v
    }
    func int(_ k: String, _ d: Int) -> Int {
        if let v = raw[k] as? Int { return v }
        if let v = raw[k] as? NSNumber { return v.intValue }
        if let v = raw[k] as? String, let n = Int(v) { return n }
        return d
    }
    func intIfPresent(_ k: String) -> Int? { raw[k] == nil ? nil : int(k, 0) }
    func bool(_ k: String) -> Bool {
        if let v = raw[k] as? Bool { return v }
        if let v = raw[k] as? NSNumber { return v.boolValue }
        if let v = raw[k] as? String { return v == "true" || v == "1" }
        return false
    }
    /// Comma-separated list, empty entries dropped.
    func list(_ k: String) -> [String] {
        (string(k) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Domains

public struct Check: Encodable {
    public let domain: String
    public let name: String
    public let ok: Bool
    public let detail: String
    public let fix: String?
}

public struct Domain {
    public let name: String
    /// Default settings for this domain's section of config.json, if it has one.
    let defaults: (any Encodable)?
    let commands: (Context) -> [Command]
    let checks: (Context) async -> [Check]
}

/// Settings for one domain. Missing fields in config.json fall back to `defaults`.
protocol DomainSettings: Codable {
    static var key: String { get }
    static var defaults: Self { get }
}

// MARK: - Context and config

public final class Context {
    public static var configPath: String {
        ProcessInfo.processInfo.environment["APPLE_CLI_CONFIG"] ?? NSHomeDirectory() + "/.config/apple-cli/config.json"
    }

    let domains: [Domain]
    private var file: [String: Any]?

    init(domains: [Domain]) { self.domains = domains }

    /// The whole config file. Written with every domain's defaults on first run, never rewritten after.
    func configFile() throws -> [String: Any] {
        if let file { return file }
        let p = Self.configPath
        if !FileManager.default.fileExists(atPath: p) {
            var all: [String: Any] = [:]
            for d in domains { if let def = d.defaults { all[d.name] = try jsonObject(def) } }
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: URL(fileURLWithPath: p))
            file = all
            return all
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: p))) as? [String: Any] else {
            throw AppleError.invalid("config \(p) is not a JSON object")
        }
        file = obj
        return obj
    }

    /// One domain's settings: its defaults, overlaid with whatever keys the file sets.
    func settings<T: DomainSettings>(_ type: T.Type) throws -> T {
        var merged = (try jsonObject(T.defaults) as? [String: Any]) ?? [:]
        if let section = try configFile()[T.key] as? [String: Any] {
            merged.merge(section) { _, user in user }
        }
        do {
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: merged))
        } catch {
            throw AppleError.invalid("config section \"\(T.key)\" in \(Self.configPath): \(error)")
        }
    }
}

// MARK: - Privacy

/// Decides which items may never be printed. The same rules serve every domain:
/// title patterns, container names (folder, list, group, chat), and item IDs.
public struct PrivacyFilter {
    let patterns: [NSRegularExpression]
    let containers: Set<String>
    let ids: Set<String>

    init(titlePatterns: [String], containers: [String], ids: [String]) throws {
        patterns = try titlePatterns.map {
            do { return try NSRegularExpression(pattern: $0) } catch { throw AppleError.invalid("bad exclude pattern \($0)") }
        }
        self.containers = Set(containers.map { $0.lowercased() })
        self.ids = Set(ids)
    }

    func hidesContainer(_ name: String) -> Bool { containers.contains(name.lowercased()) }

    func hidesTitle(_ t: String) -> Bool {
        patterns.contains { $0.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil }
    }

    func hides(title: String?, containers names: [String], id: String?, locked: Bool = false) -> Bool {
        if locked { return true }
        if let id, ids.contains(id) { return true }
        if names.contains(where: hidesContainer) { return true }
        if let title, hidesTitle(title) { return true }
        return false
    }
}

// MARK: - Helpers

/// Runs blocking framework work with a deadline so a stuck Apple daemon cannot hang the CLI.
func withDeadline<T>(_ seconds: Double, _ what: String, _ work: @escaping () throws -> T) throws -> T {
    var result: Result<T, Error>?
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        result = Result { try work() }
        done.signal()
    }
    guard done.wait(timeout: .now() + seconds) == .success, let r = result else {
        throw AppleError.timeout("\(what) took longer than \(Int(seconds))s")
    }
    return try r.get()
}

func waitFor<T>(_ seconds: Double, _ probe: () throws -> T?) rethrows -> T? {
    let end = Date().addingTimeInterval(seconds)
    repeat {
        if let v = try probe() { return v }
        usleep(150_000)
    } while Date() < end
    return nil
}

let localISO: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func jsonEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    e.dateEncodingStrategy = .custom { d, enc in
        var c = enc.singleValueContainer()
        try c.encode(localISO.string(from: d))
    }
    return e
}

func jsonObject(_ v: any Encodable) throws -> Any {
    try JSONSerialization.jsonObject(with: jsonEncoder().encode(v))
}

func jsonString(_ v: any Encodable) -> String {
    (try? jsonEncoder().encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
}

// MARK: - Running as its own app

/// macOS gives a process the privacy permissions of the app that launched it (Claude, Terminal, sshd).
/// So the same command could read Messages from one launcher and fail from another, and a launcher
/// without a Photos usage string got no prompt at all. `OwnApp.relaunch` reruns every command in a
/// child that disclaims its launcher, so every grant belongs to apple-cli's own signed identity
/// (~/Applications/AppleCLI.app) and works the same from any launcher.
enum OwnApp {
    /// Set in the child, so it runs the command itself rather than spawning again.
    static let marker = "APPLE_CLI_OWN_APP"
    static var active: Bool { ProcessInfo.processInfo.environment[marker] != nil }

    /// Reruns this invocation as its own app, sharing stdin, stdout, and stderr, and returns its exit code.
    /// Nil when this macOS cannot disclaim, so the caller runs the command in this process instead.
    static func relaunch(_ argv: [String]) -> Int32? {
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard !active, let exe = executable,
              let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil } // RTLD_DEFAULT
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr); defer { posix_spawnattr_destroy(&attr) }
        guard unsafeBitCast(sym, to: Disclaim.self)(&attr, 1) == 0 else { return nil }
        // The child starts with default signal handling and nothing blocked, whatever this process inherited.
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        // Only plain settings cross over. Loader variables (DYLD_*) would let a caller run its own code under AppleCLI's grants.
        let keep: Set<String> = ["HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "TZ", "TERM"]
        let env = ProcessInfo.processInfo.environment
            .filter { keep.contains($0.key) || ($0.key.hasPrefix("APPLE_CLI_") && $0.key != marker) }
            .merging([marker: "1"]) { $1 }.map { "\($0)=\($1)" }
        let cArgs = ([exe] + argv.dropFirst()).map { strdup($0) } + [nil]
        let cEnv = env.map { strdup($0) } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }

        var pid: pid_t = 0
        guard posix_spawn(&pid, exe, nil, &attr, cArgs, cEnv) == 0 else { return nil }
        // The child gets Ctrl-C from the terminal itself. A plain kill of this process is passed on.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { kill(pid, sig) }
            src.resume()
            relaySources.append(src)
        }
        var st: Int32 = 0
        while waitpid(pid, &st, 0) == -1 && errno == EINTR {}
        let sig = st & 0x7f
        return sig == 0 ? (st >> 8) & 0xff : 128 + sig
    }
    nonisolated(unsafe) private static var relaySources: [DispatchSourceSignal] = []

    /// In the child: exit when the parent does, so a stopped launchd job or a killed client never leaves
    /// a server holding its port.
    static func exitWithParent() {
        guard active else { return }
        let src = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .global())
        src.setEventHandler { exit(0) }
        src.resume()
        parentWatch.append(src)
        if getppid() == 1 { exit(0) }  // the parent died before the watch started
    }
    nonisolated(unsafe) private static var parentWatch: [DispatchSourceProcess] = []

    /// This binary's real path. ~/.local/bin/apple-cli is a symlink into the app bundle.
    static var executable: String? { Bundle.main.executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }
    /// The AppleCLI.app folder, or the bare binary when it runs outside a bundle.
    static var bundlePath: String? {
        executable.map { $0.hasSuffix(".app/Contents/MacOS/apple-cli") ? String($0.dropLast("/Contents/MacOS/apple-cli".count)) : $0 }
    }
}

// MARK: - Drafts, audit log, and send limit

/// Anything that leaves the Mac (a text, an email) is drafted first and sent by draft ID, so what was
/// shown is exactly what goes out. Drafts are files in ~/.config/apple-cli/drafts (mode 600), so a
/// CLI call can send what an earlier call drafted. Each expires after an hour and sends at most once.
struct Draft: Codable {
    let id: String
    let kind: String              // "message" or "mail"
    let created: Date
    /// What the sender sees: recipients, subject, text.
    let summary: String
    /// Everything the sender needs, resolved at draft time (chat ID, handles, account, body).
    let payload: [String: [String]]

    static let ttl: TimeInterval = 3600
    static var dir: String { (Context.configPath as NSString).deletingLastPathComponent + "/drafts" }

    static func save(kind: String, summary: String, payload: [String: [String]]) throws -> Draft {
        let d = Draft(id: "d_" + UUID().uuidString.prefix(8).lowercased(), kind: kind, created: Date(), summary: summary, payload: payload)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = dir + "/\(d.id).json"
        guard FileManager.default.createFile(atPath: path, contents: try JSONEncoder().encode(d), attributes: [.posixPermissions: 0o600]) else {
            throw AppleError.app("could not write the draft to \(path)")
        }
        return d
    }

    /// Loads and removes a draft in one step, so two sends of the same ID cannot both go out.
    static func take(_ id: String, kind: String) throws -> Draft {
        guard id.range(of: #"^d_[0-9a-f]{8}$"#, options: .regularExpression) != nil else { throw AppleError.invalid("draft ID looks like d_1a2b3c4d") }
        let path = dir + "/\(id).json", claimed = path + ".sending"
        // A draft of the other kind is left alone, so sending an email ID as a text cannot destroy the email.
        if let peek = try? JSONDecoder().decode(Draft.self, from: Data(contentsOf: URL(fileURLWithPath: path))), peek.kind != kind {
            throw AppleError.invalid("\(id) is a \(peek.kind) draft")
        }
        guard rename(path, claimed) == 0 else { throw AppleError.notFound("draft \(id) (already sent, expired, or never made)") }
        defer { unlink(claimed) }
        let d = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: URL(fileURLWithPath: claimed)))
        guard d.kind == kind else { throw AppleError.invalid("\(id) is a \(d.kind) draft") }
        guard Date().timeIntervalSince(d.created) < ttl else { throw AppleError.refused("draft \(id) expired; draft it again") }
        return d
    }

    /// Puts a taken draft back, for a send that failed before anything left the Mac, so the approved
    /// draft can be sent again without redrafting.
    static func restore(_ d: Draft) {
        let path = dir + "/\(d.id).json"
        if let data = try? JSONEncoder().encode(d) { FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) }
    }
}

struct DraftOutput: Output {
    let draftId: String
    let summary: String
    let expires: Date
    let sendWith: String
    var text: String { "\(summary)\n\ndraft \(draftId), expires \(localISO.string(from: expires)). Send with: \(sendWith)" }
    init(_ d: Draft, sendWith: String) {
        draftId = d.id; summary = d.summary; expires = d.created.addingTimeInterval(Draft.ttl); self.sendWith = sendWith
    }
}

/// One JSON line per write, in ~/Library/Logs/apple-cli/audit.log: time, command, target, and outcome.
/// Never message text or email bodies.
enum Audit {
    static let path = NSHomeDirectory() + "/Library/Logs/apple-cli/audit.log"

    static func write(_ command: String, _ fields: [String: Any]) {
        var line = fields
        line["time"] = localISO.string(from: Date()); line["command"] = command
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        h.seekToEndOfFile(); h.write(data + Data("\n".utf8)); try? h.close()
    }

    /// Send times only, one per line, kept apart from the audit log so other writes cannot push sends out of view.
    static let sendLog = NSHomeDirectory() + "/Library/Logs/apple-cli/sends.log"

    /// Runs one send under an exclusive lock: count the last hour, refuse past the limit (config
    /// `send.sendsPerHour`, default 30), send, and record it. Parallel sends wait their turn.
    static func withSendSlot<T>(_ ctx: Context, _ send: () throws -> T) throws -> T {
        let limit = (try? ctx.settings(SendSettings.self).sendsPerHour) ?? SendSettings.defaults.sendsPerHour
        try FileManager.default.createDirectory(atPath: (sendLog as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = open(sendLog + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw AppleError.refused("cannot open the send lock, so the send limit cannot be checked") }
        defer { flock(fd, LOCK_UN); close(fd) }
        flock(fd, LOCK_EX)
        let cutoff = Date().addingTimeInterval(-3600).timeIntervalSince1970
        var recent: [Double] = []
        if FileManager.default.fileExists(atPath: sendLog) {
            guard let text = try? String(contentsOfFile: sendLog, encoding: .utf8) else { throw AppleError.refused("cannot read \(sendLog), so the send limit cannot be checked") }
            recent = text.split(separator: "\n").compactMap { Double($0) }.filter { $0 > cutoff }
        }
        if recent.count >= limit { throw AppleError.refused("\(recent.count) sends in the last hour, at the limit of \(limit) (config send.sendsPerHour)") }
        // Recorded before sending, so a send that hangs or crashes still counts.
        recent.append(Date().timeIntervalSince1970)
        FileManager.default.createFile(atPath: sendLog, contents: Data(recent.map { String($0) }.joined(separator: "\n").utf8), attributes: [.posixPermissions: 0o600])
        return try send()
    }
}

struct SendSettings: DomainSettings {
    static let key = "send"
    /// Texts plus emails per rolling hour. A runaway agent stops here.
    var sendsPerHour: Int
    static let defaults = SendSettings(sendsPerHour: 30)
}

/// What a write did, for writes with nothing richer to return.
struct Done: Output {
    let id: String
    let action: String
    var detail: String? = nil
    var text: String { "\(action): \(id)" + (detail.map { " (\($0))" } ?? "") }
}
