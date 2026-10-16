import Foundation

// One command table drives both the CLI and the MCP server, so they cannot drift.

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
    public let path: [String]            // ["notes", "search"]
    public let help: String
    public let params: [Param]
    public let mcp: Bool                 // false = CLI only (deletes stay out of agent reach)
    let run: ([String: Any]) async throws -> [String: Any]
    let human: ([String: Any]) -> String
    public var toolName: String { path.joined(separator: "_").replacingOccurrences(of: "-", with: "_") }
}

final class Context {
    lazy var config: Result<Config, Error> = Result { try Config.load() }
    func cfg() throws -> Config { try config.get() }
    func notes() throws -> NotesStore { try NotesStore(privacy: try PrivacyFilter(cfg().notes)) }
}

private func s(_ a: [String: Any], _ k: String) -> String? { a[k] as? String }
private func i(_ a: [String: Any], _ k: String, _ d: Int) -> Int {
    if let v = a[k] as? Int { return v }
    if let v = a[k] as? NSNumber { return v.intValue }
    if let v = a[k] as? String, let n = Int(v) { return n }
    return d
}
private func b(_ a: [String: Any], _ k: String) -> Bool {
    if let v = a[k] as? Bool { return v }
    if let v = a[k] as? NSNumber { return v.boolValue }
    if let v = a[k] as? String { return v == "true" || v == "1" }
    return false
}

private func waitFor<T>(_ seconds: Double, _ probe: () throws -> T?) rethrows -> T? {
    let end = Date().addingTimeInterval(seconds)
    repeat {
        if let v = try probe() { return v }
        usleep(150_000)
    } while Date() < end
    return nil
}

private func noteLine(_ n: [String: Any]) -> String {
    let title = (n["title"] as? String) ?? (n["downloaded"] as? Bool == false ? "(not downloaded from iCloud yet)" : "(untitled)")
    let mod = ((n["modified"] as? String) ?? "").prefix(10)
    return "\(n["id"] as? String ?? "?")  \(mod)  [\(n["folder"] as? String ?? "-")]  \(title)"
}

private func reminderLine(_ r: [String: Any]) -> String {
    var line = (r["completed"] as? Bool == true ? "[x] " : "[ ] ") + (r["title"] as? String ?? "")
    if let d = r["due"] as? String { line += "  due \(d)" }
    if r["overdue"] as? Bool == true { line += " (overdue)" }
    if r["flagged"] as? Bool == true { line += "  flagged" }
    line += "  [\(r["list"] as? String ?? "")]  \(r["id"] as? String ?? "")"
    return line
}

private func hiddenNote(_ r: [String: Any]) -> String {
    let h = r["hidden"] as? Int ?? 0
    return h > 0 ? "\n\(h) note(s) hidden by privacy config" : ""
}

public func buildCommands() -> [Command] {
    let ctx = Context()
    return [
        Command(path: ["notes", "list"], help: "List notes, newest first.",
                params: [Param("folder", "Only notes in this folder"), Param("limit", .integer, "Max notes (default 50)")],
                mcp: true,
                run: { a in
                    let store = try ctx.notes()
                    let (notes, hidden) = try store.allNotes()
                    let f = s(a, "folder")?.lowercased()
                    let rows = notes.filter { f == nil || $0.folder?.lowercased() == f }.prefix(i(a, "limit", 50))
                    return ["notes": rows.map { $0.summary() }, "hidden": hidden]
                },
                human: { r in ((r["notes"] as? [[String: Any]]) ?? []).map(noteLine).joined(separator: "\n") + hiddenNote(r) }),

        Command(path: ["notes", "folders"], help: "List note folders with counts.", params: [], mcp: true,
                run: { _ in ["folders": try ctx.notes().folders()] },
                human: { r in ((r["folders"] as? [[String: Any]]) ?? []).map { "\($0["name"]!)  (\($0["notes"]!))" }.joined(separator: "\n") }),

        Command(path: ["notes", "search"], help: "Search note titles and bodies (case-insensitive).",
                params: [Param("query", required: true, positional: true, "Text to find"), Param("limit", .integer, "Max results (default 20)")],
                mcp: true,
                run: { a in
                    let q = s(a, "query") ?? ""
                    guard !q.isEmpty else { throw AppleError.invalid("empty query") }
                    let store = try ctx.notes()
                    let (notes, hidden) = try store.allNotes()
                    var out: [[String: Any]] = []
                    for n in notes {
                        let text = store.plainText(n) ?? ""
                        let hay = (n.title ?? "") + "\n" + text
                        guard let r = hay.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                        let lo = hay.index(r.lowerBound, offsetBy: -60, limitedBy: hay.startIndex) ?? hay.startIndex
                        let hi = hay.index(r.upperBound, offsetBy: 80, limitedBy: hay.endIndex) ?? hay.endIndex
                        var m = n.summary()
                        m["match"] = hay[lo..<hi].replacingOccurrences(of: "\n", with: " ")
                        out.append(m)
                        if out.count >= i(a, "limit", 20) { break }
                    }
                    return ["results": out, "hidden": hidden]
                },
                human: { r in ((r["results"] as? [[String: Any]]) ?? []).map { noteLine($0) + "\n    …\($0["match"] as? String ?? "")…" }.joined(separator: "\n") + hiddenNote(r) }),

        Command(path: ["notes", "read"], help: "Read one note as Markdown.",
                params: [Param("id", required: true, positional: true, "Note ID from list/search")], mcp: true,
                run: { a in
                    let store = try ctx.notes()
                    let n = try store.find(s(a, "id") ?? "")
                    guard n.downloaded else { throw AppleError.notFound("body of note \(s(a, "id")!). Notes has not downloaded it from iCloud yet. Open it in Notes once.") }
                    var m = n.summary()
                    m["markdown"] = try store.markdown(n)
                    return m
                },
                human: { r in r["markdown"] as? String ?? "" }),

        Command(path: ["notes", "create"], help: "Create a note through Notes.app. Body is Markdown.",
                params: [Param("title", required: true, positional: true, "Note title"),
                         Param("body", "Markdown body"), Param("folder", "Folder name (default: Notes default folder)")],
                mcp: true,
                run: { a in
                    let store = try ctx.notes()
                    let folderID = try s(a, "folder").map { try store.folderScriptID(named: $0) }
                    let scriptID = try NotesWriter.create(title: s(a, "title") ?? "", markdown: s(a, "body") ?? "", folderScriptID: folderID)
                    // Notes saves asynchronously; wait briefly for the row so we can return its stable ID.
                    let row = try waitFor(3) { try? ctx.notes().find(scriptID) }
                    var m: [String: Any] = row?.summary() ?? [:]
                    m["scriptId"] = scriptID
                    return m
                },
                human: { r in "created \(r["id"] as? String ?? r["scriptId"] as? String ?? "")" }),

        Command(path: ["notes", "append"], help: "Append Markdown to a note. Refuses notes with checklists or attachments unless --force, because Notes rewrites the body and drops them.",
                params: [Param("id", required: true, positional: true, "Note ID"), Param("text", required: true, positional: true, "Markdown to append"),
                         Param("force", .boolean, "Append even if checklists, tables, or attachments would be lost")],
                mcp: true,
                run: { a in
                    let store = try ctx.notes()
                    let n = try store.find(s(a, "id") ?? "")
                    guard n.downloaded else { throw AppleError.refused("note body is not downloaded from iCloud yet") }
                    let atts = try store.attachmentCount(notePK: n.pk)
                    if (n.hasChecklist || atts > 0) && !b(a, "force") {
                        throw AppleError.refused("note has \(n.hasChecklist ? "a checklist" : "")\(n.hasChecklist && atts > 0 ? " and " : "")\(atts > 0 ? "\(atts) attachment(s)" : ""). Appending through Notes.app would lose that content. Pass force to accept the loss.")
                    }
                    try NotesWriter.append(noteScriptID: n.scriptID(storeUUID: store.storeUUID), markdown: s(a, "text") ?? "")
                    return ["id": n.id ?? NSNull(), "appended": true]
                },
                human: { r in "appended to \(r["id"] as? String ?? "")" }),

        Command(path: ["notes", "trash"], help: "Move a note to Recently Deleted.",
                params: [Param("id", required: true, positional: true, "Note ID")], mcp: false,
                run: { a in
                    let store = try ctx.notes()
                    let n = try store.find(s(a, "id") ?? "")
                    try NotesWriter.trash(noteScriptID: n.scriptID(storeUUID: store.storeUUID), trashFolderScriptID: try store.trashFolderScriptID())
                    return ["id": n.id ?? NSNull(), "trashed": true]
                },
                human: { r in "moved \(r["id"] as? String ?? "") to Recently Deleted" }),

        Command(path: ["reminders", "list"], help: "List open reminders (all lists, or one).",
                params: [Param("list", "List name"), Param("completed", .boolean, "Include completed"), Param("limit", .integer, "Max (default 100)")],
                mcp: true,
                run: { a in
                    let l = s(a, "list")?.lowercased()
                    let rows = try RemindersStore().all(includeCompleted: b(a, "completed"))
                        .filter { l == nil || $0.list.lowercased() == l }.prefix(i(a, "limit", 100))
                    return ["reminders": rows.map { $0.json() }]
                },
                human: { r in ((r["reminders"] as? [[String: Any]]) ?? []).map(reminderLine).joined(separator: "\n") }),

        Command(path: ["reminders", "due-today"], help: "Open reminders due today, plus overdue ones.", params: [], mcp: true,
                run: { _ in
                    ["reminders": try RemindersStore().dueToday().map { r, overdue in var j = r.json(); j["overdue"] = overdue; return j }]
                },
                human: { r in ((r["reminders"] as? [[String: Any]]) ?? []).map(reminderLine).joined(separator: "\n") }),

        Command(path: ["reminders", "add"], help: "Add a reminder with a remind-me date (due date plus alarm).",
                params: [Param("title", required: true, positional: true, "Reminder title"),
                         Param("at", "When: YYYY-MM-DD [HH:MM], today|tomorrow [HH:MM], +30m/+2h/+1d (default: tomorrow at the default time)"),
                         Param("list", "List name (default from config: Reminders)"), Param("notes", "Notes text"),
                         Param("priority", .integer, "0 none, 1 high, 5 medium, 9 low")],
                mcp: true,
                run: { a in
                    let c = try ctx.cfg().reminders
                    let at = try parseWhen(s(a, "at"), defaultTime: c.defaultTime)
                    let w = try await RemindersWriter()
                    let r = try w.add(title: s(a, "title") ?? "", list: s(a, "list") ?? c.defaultList, at: at,
                                      notes: s(a, "notes"), priority: a["priority"] == nil ? nil : i(a, "priority", 0))
                    let ek = r.calendarItemIdentifier
                    let row = try waitFor(3) { try RemindersStore().find(ek) }
                    var m: [String: Any] = row?.json() ?? ["title": r.title ?? "", "list": r.calendar.title]
                    m["id"] = row?.id ?? ek
                    m["remindAt"] = isoString(at)
                    return m
                },
                human: { r in "added \(r["title"] as? String ?? "") for \(r["remindAt"] as? String ?? "") [\(r["list"] as? String ?? "")]  \(r["id"] as? String ?? "")" }),

        Command(path: ["reminders", "complete"], help: "Mark a reminder done.",
                params: [Param("id", required: true, positional: true, "Reminder ID")], mcp: true,
                run: { a in
                    let r = try await RemindersWriter().complete(s(a, "id") ?? "")
                    return ["id": s(a, "id")!, "title": r.title ?? "", "completed": true]
                },
                human: { r in "completed \(r["title"] as? String ?? "")" }),

        Command(path: ["reminders", "delete"], help: "Delete a reminder (it goes to Recently Deleted in Reminders).",
                params: [Param("id", required: true, positional: true, "Reminder ID")], mcp: false,
                run: { a in
                    try await RemindersWriter().delete(s(a, "id") ?? "")
                    return ["id": s(a, "id")!, "deleted": true]
                },
                human: { r in "deleted \(r["id"] as? String ?? "")" }),
    ]
}

// MARK: - CLI

public enum CLI {
    public static func main(_ argv: [String]) async -> Int32 {
        let commands = buildCommands()
        var args = Array(argv.dropFirst())
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" }

        if args.first == "mcp" { await MCPServer(commands: commands.filter(\.mcp)).serve(); return 0 }
        guard args.count >= 2, let cmd = commands.first(where: { $0.path == Array(args.prefix(2)) }) else {
            print(usage(commands)); return args.isEmpty || args.first == "help" || args.first == "--help" ? 0 : 2
        }
        do {
            let input = try parse(Array(args.dropFirst(2)), cmd)
            let result = try await cmd.run(input)
            print(json ? jsonString(result) : cmd.human(result))
            return 0
        } catch {
            let msg = (error as? AppleError)?.description ?? "\(error)"
            if json { print(jsonString(["error": msg])) } else { FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!) }
            return 1
        }
    }

    static func parse(_ args: [String], _ cmd: Command) throws -> [String: Any] {
        var out: [String: Any] = [:]
        var positionals: [String] = []
        var k = 0
        while k < args.count {
            let a = args[k]
            if a.hasPrefix("--") {
                var name = String(a.dropFirst(2)), value: String? = nil
                if let eq = name.firstIndex(of: "=") { value = String(name[name.index(after: eq)...]); name = String(name[..<eq]) }
                guard let p = cmd.params.first(where: { $0.name == name }) else { throw AppleError.invalid("unknown flag --\(name)") }
                if p.kind == .boolean { out[name] = value.map { $0 != "false" } ?? true }
                else {
                    if value == nil { k += 1; guard k < args.count else { throw AppleError.invalid("--\(name) needs a value") }; value = args[k] }
                    out[name] = value
                }
            } else { positionals.append(a) }
            k += 1
        }
        let pos = cmd.params.filter(\.positional)
        for (idx, p) in pos.enumerated() where idx < positionals.count {
            // The last positional soaks up extra words, so `notes search two words` works unquoted.
            out[p.name] = idx == pos.count - 1 ? positionals[idx...].joined(separator: " ") : positionals[idx]
        }
        for p in cmd.params where p.required && out[p.name] == nil { throw AppleError.invalid("missing \(p.name)") }
        return out
    }

    static func usage(_ cmds: [Command]) -> String {
        var s = "apple-cli: fast Apple Notes and Reminders for agents\n\nUsage: apple-cli <group> <command> [args] [--json]\n       apple-cli mcp   (MCP server on stdio)\n\n"
        for c in cmds {
            let args = c.params.map { $0.positional ? "<\($0.name)>" : "[--\($0.name)\($0.kind == .boolean ? "" : " …")]" }.joined(separator: " ")
            s += "  \(c.path.joined(separator: " ")) \(args)\n      \(c.help)\n"
        }
        return s + "\nConfig: \(Config.path)"
    }
}

func jsonString(_ v: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
    return String(decoding: d, as: UTF8.self)
}

// MARK: - MCP (JSON-RPC 2.0 over newline-delimited stdio)

final class MCPServer {
    let commands: [Command]
    init(commands: [Command]) { self.commands = commands }

    func serve() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = msg["method"] as? String else { continue }
            let id = msg["id"]
            guard id != nil else { continue } // notifications need no reply
            let params = msg["params"] as? [String: Any] ?? [:]
            var result: [String: Any]?
            var error: [String: Any]?
            switch method {
            case "initialize":
                result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                          "capabilities": ["tools": [:]],
                          "serverInfo": ["name": "apple-cli", "version": "0.1.0"]]
            case "ping": result = [:]
            case "tools/list": result = ["tools": commands.map(schema)]
            case "tools/call":
                let name = params["name"] as? String ?? ""
                if let cmd = commands.first(where: { $0.toolName == name }) {
                    do {
                        let input = params["arguments"] as? [String: Any] ?? [:]
                        for p in cmd.params where p.required && input[p.name] == nil { throw AppleError.invalid("missing \(p.name)") }
                        result = ["content": [["type": "text", "text": jsonString(try await cmd.run(input))]], "isError": false]
                    } catch {
                        result = ["content": [["type": "text", "text": (error as? AppleError)?.description ?? "\(error)"]], "isError": true]
                    }
                } else { error = ["code": -32602, "message": "unknown tool \(name)"] }
            default: error = ["code": -32601, "message": "method not found: \(method)"]
            }
            var reply: [String: Any] = ["jsonrpc": "2.0", "id": id!]
            if let result { reply["result"] = result } else { reply["error"] = error! }
            print(jsonString(reply))
            fflush(stdout)
        }
    }

    func schema(_ c: Command) -> [String: Any] {
        var props: [String: Any] = [:]
        for p in c.params { props[p.name] = ["type": p.kind.rawValue, "description": p.help] }
        return ["name": c.toolName, "description": c.help,
                "inputSchema": ["type": "object", "properties": props,
                                "required": c.params.filter(\.required).map(\.name)]]
    }
}
