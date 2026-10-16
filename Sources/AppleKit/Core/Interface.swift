import Foundation

// One registry drives the CLI, `--json`, and the MCP server, so they cannot drift.

/// Every app apple-cli knows. Adding an app = one folder under Domains/ plus one line here.
let allDomains: [Domain] = [notesDomain, remindersDomain, contactsDomain, messagesDomain, photosDomain, calendarDomain]

public let version = "0.5.0"

final class Registry {
    let context: Context
    let commands: [Command]

    init() {
        let ctx = Context(domains: allDomains)
        context = ctx
        var cmds = allDomains.flatMap { $0.commands(ctx) }
        cmds.append(Command(["doctor"], .read, "Check permissions, store files, database layout, and read speed for every app.") { _ in
            var checks: [Check] = []
            for d in allDomains { checks += await d.checks(ctx) }
            return DoctorReport(checks: checks)
        })
        commands = cmds
    }

    func find(_ words: [String]) -> (Command, Int)? {
        if words.count >= 2, let c = commands.first(where: { $0.path == Array(words.prefix(2)) }) { return (c, 2) }
        if let w = words.first, let c = commands.first(where: { $0.path == [w] }) { return (c, 1) }
        return nil
    }

    /// Runs a command, timing it to stderr when APPLE_CLI_DEBUG is set.
    func run(_ c: Command, _ args: Args) async throws -> any Output {
        let t = Date()
        defer {
            if ProcessInfo.processInfo.environment["APPLE_CLI_DEBUG"] != nil {
                FileHandle.standardError.write(Data("[apple-cli] \(c.path.joined(separator: " ")) \(Int(Date().timeIntervalSince(t) * 1000)) ms\n".utf8))
            }
        }
        for p in c.params where p.required && args.raw[p.name] == nil { throw AppleError.invalid("missing \(p.name)") }
        return try await c.run(args)
    }
}

struct DoctorReport: Output {
    let checks: [Check]
    var ok: Bool { checks.allSatisfy(\.ok) }
    enum CodingKeys: String, CodingKey { case checks, ok }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(checks, forKey: .checks); try c.encode(ok, forKey: .ok)
    }
    var text: String {
        checks.map { "\($0.ok ? "ok  " : "FAIL") \($0.domain) \($0.name): \($0.detail)" + ($0.fix.map { "\n       fix: \($0)" } ?? "") }
            .joined(separator: "\n")
    }
}

struct ErrorOutput: Encodable {
    struct Body: Encodable { let code: String; let message: String }
    let error: Body
    init(_ e: AppleError) { error = Body(code: e.code, message: e.description) }
}

// MARK: - CLI

public enum CLI {
    public static func main(_ argv: [String]) async -> Int32 {
        let reg = Registry()
        var args = Array(argv.dropFirst())
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" }

        if args.first == "mcp" { await MCPServer(registry: reg).serve(); return 0 }
        if args.first == "--version" { print(version); return 0 }
        guard let (cmd, used) = reg.find(args) else {
            print(usage(reg.commands)); return args.isEmpty || args.first == "help" || args.first == "--help" ? 0 : 2
        }
        do {
            let out = try await reg.run(cmd, Args(raw: try parse(Array(args.dropFirst(used)), cmd)))
            print(json ? jsonString(out) : out.text)
            if let d = out as? DoctorReport, !d.ok { return 1 }
            return 0
        } catch {
            let e = AppleError.wrap(error)
            if json { print(jsonString(ErrorOutput(e))) } else { FileHandle.standardError.write(Data("error: \(e.description)\n".utf8)) }
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
        if positionals.count > 0 && pos.isEmpty { throw AppleError.invalid("unexpected argument \(positionals[0])") }
        for (idx, p) in pos.enumerated() where idx < positionals.count {
            // The last positional soaks up extra words, so `notes search two words` works unquoted.
            out[p.name] = idx == pos.count - 1 ? positionals[idx...].joined(separator: " ") : positionals[idx]
        }
        return out
    }

    static func usage(_ cmds: [Command]) -> String {
        var s = "apple-cli \(version): fast Apple app access for agents\n\nUsage: apple-cli <app> <command> [args] [--json]\n       apple-cli mcp   (MCP server on stdio)\n\n"
        for c in cmds {
            let args = c.params.map { $0.positional ? "<\($0.name)>" : "[--\($0.name)\($0.kind == .boolean ? "" : " …")]" }.joined(separator: " ")
            let tag = c.effect == .destructive ? "  (CLI only)" : ""
            s += "  \(c.path.joined(separator: " ")) \(args)\(tag)\n      \(c.help)\n"
        }
        return s + "\nConfig: \(Context.configPath)"
    }
}

// MARK: - MCP (JSON-RPC 2.0 over newline-delimited stdio)

final class MCPServer {
    let registry: Registry
    /// Destructive commands are never tools.
    var tools: [Command] { registry.commands.filter { $0.effect != .destructive } }
    init(registry: Registry) { self.registry = registry }

    func serve() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = msg["method"] as? String, let id = msg["id"] else { continue } // notifications need no reply
            let params = msg["params"] as? [String: Any] ?? [:]
            var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
            switch method {
            case "initialize":
                reply["result"] = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                                   "capabilities": ["tools": [:]],
                                   "serverInfo": ["name": "apple-cli", "version": version]]
            case "ping": reply["result"] = [:]
            case "tools/list": reply["result"] = ["tools": tools.map(schema)]
            case "tools/call":
                let name = params["name"] as? String ?? ""
                if let cmd = tools.first(where: { $0.toolName == name }) {
                    do {
                        let out = try await registry.run(cmd, Args(raw: params["arguments"] as? [String: Any] ?? [:], viaMCP: true))
                        reply["result"] = ["content": [["type": "text", "text": jsonString(out)]],
                                           "structuredContent": (try? jsonObject(out)) ?? [:], "isError": false]
                    } catch {
                        let e = AppleError.wrap(error)
                        reply["result"] = ["content": [["type": "text", "text": jsonString(ErrorOutput(e))]], "isError": true]
                    }
                } else { reply["error"] = ["code": -32602, "message": "unknown tool \(name)"] }
            default: reply["error"] = ["code": -32601, "message": "method not found: \(method)"]
            }
            if let d = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) {
                print(String(decoding: d, as: UTF8.self))
                fflush(stdout)
            }
        }
    }

    func schema(_ c: Command) -> [String: Any] {
        var props: [String: Any] = [:]
        for p in c.params { props[p.name] = ["type": p.kind.rawValue, "description": p.help] }
        return ["name": c.toolName, "description": c.help,
                "annotations": ["readOnlyHint": c.effect == .read, "destructiveHint": false, "openWorldHint": false],
                "inputSchema": ["type": "object", "properties": props, "required": c.params.filter(\.required).map(\.name)]]
    }
}
