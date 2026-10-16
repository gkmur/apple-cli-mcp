import Foundation

/// User settings in ~/.config/apple-cli/config.json. Written with defaults on first run.
public struct Config: Codable {
    public struct NotesPrivacy: Codable {
        /// Regexes matched against note titles. A match hides the note everywhere.
        public var excludeTitlePatterns: [String]
        /// Folder names whose notes are hidden everywhere.
        public var excludeFolders: [String]
        /// Note IDs (ZIDENTIFIER) hidden everywhere.
        public var excludeNoteIDs: [String]
    }
    public struct Reminders: Codable {
        public var defaultList: String
        /// Time used when `add` gets a date with no time, or no date at all (then: tomorrow).
        public var defaultTime: String
    }
    public var notes: NotesPrivacy
    public var reminders: Reminders

    public static let defaults = Config(
        notes: NotesPrivacy(
            excludeTitlePatterns: [
                #"(?i)\b(passwords?|passcodes?|pw|pwd|logins?|credentials?|api[ _-]?keys?|tokens?|secrets?|ssn|pins?|2fa|mfa|otp|backup codes?|recovery (codes?|keys?)|seed( phrase)?|wi-?fi)\b"#,
                #"(?i)journal|diary"#,
                #"(?i)therap(y|ist)|counsel(l?ing|or)"#,
            ],
            excludeFolders: [],
            excludeNoteIDs: []),
        reminders: Reminders(defaultList: "Reminders", defaultTime: "09:00"))

    public static var path: String {
        ProcessInfo.processInfo.environment["APPLE_CLI_CONFIG"] ?? NSHomeDirectory() + "/.config/apple-cli/config.json"
    }

    public static func load() throws -> Config {
        let p = path
        if !FileManager.default.fileExists(atPath: p) {
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(defaults).write(to: URL(fileURLWithPath: p))
            return defaults
        }
        do {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: p)))
        } catch {
            throw AppleError.invalid("config \(p) does not parse: \(error)")
        }
    }
}

/// Decides which notes may never be printed. Locked notes are always hidden.
public struct PrivacyFilter {
    let patterns: [NSRegularExpression]
    let folders: Set<String>
    let ids: Set<String>

    public init(_ c: Config.NotesPrivacy) throws {
        patterns = try c.excludeTitlePatterns.map {
            do { return try NSRegularExpression(pattern: $0) } catch { throw AppleError.invalid("bad exclude pattern \($0)") }
        }
        folders = Set(c.excludeFolders.map { $0.lowercased() })
        ids = Set(c.excludeNoteIDs)
    }

    public func excludes(folder: String) -> Bool { folders.contains(folder.lowercased()) }

    public func excludes(title: String) -> Bool {
        patterns.contains { $0.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil }
    }

    public func excludes(note n: NoteRow) -> Bool {
        if n.locked { return true }
        if let id = n.id, ids.contains(id) { return true }
        // Check the joined folder name too, so an unresolved path never fails open.
        if let f = n.folder, excludes(folder: f) { return true }
        if n.folderPath.contains(where: excludes(folder:)) { return true }
        if let t = n.title, excludes(title: t) { return true }
        return false
    }
}
