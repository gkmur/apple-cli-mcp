import Foundation
import Network

// One registry drives the CLI, `--json`, and the MCP server, so they cannot drift.

/// Every app apple-cli knows. Adding an app = one folder under Domains/ plus one line here.
let allDomains: [Domain] = [notesDomain, remindersDomain, contactsDomain, messagesDomain, photosDomain, calendarDomain, safariDomain, mailDomain, voiceMemosDomain, shortcutsDomain, callsDomain, musicDomain, acrossDomain]

public let version = "0.13.0"

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
        // A child process or MCP client that goes away must surface as a write error, not kill apple-cli.
        signal(SIGPIPE, SIG_IGN)
        if let code = OwnApp.relaunch(argv) { return code }
        OwnApp.exitWithParent()
        let reg = Registry()
        var args = Array(argv.dropFirst())
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" }

        if args.first == "mcp" { await MCPServer(registry: reg).serve(); return 0 }
        if args.first == "serve" {
            do { try await HTTPServer.start(Array(args.dropFirst()), registry: reg) } catch {
                FileHandle.standardError.write(Data("error: \(AppleError.wrap(error).description)\n".utf8)); return 1
            }
        }
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
        var s = "apple-cli \(version): fast Apple app access for agents\n\nUsage: apple-cli <app> <command> [args] [--json]\n       apple-cli mcp   (MCP server on stdio)\n"
            + "       apple-cli serve --host <ip> [--port 7790] [--token-file …] [--writes]   (MCP server over HTTP, bearer token, read-only unless --writes)\n\n"
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
    /// Destructive commands are never tools. Without writes (the HTTP default), only reads are.
    var tools: [Command] { registry.commands.filter { allowWrites ? $0.effect != .destructive : $0.effect == .read } }
    let allowWrites: Bool
    init(registry: Registry, allowWrites: Bool = true) { self.registry = registry; self.allowWrites = allowWrites }

    /// stdio transport: one JSON-RPC message per line.
    func serve() async {
        while let line = readLine(strippingNewline: true) {
            guard let reply = await handle(Data(line.utf8)) else { continue }
            print(String(decoding: reply, as: UTF8.self))
            fflush(stdout)
        }
    }

    /// Answers one JSON-RPC message. Nil for notifications and anything unparseable, which get no reply.
    func handle(_ body: Data) async -> Data? {
        guard let msg = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = msg["method"] as? String, let id = msg["id"] else { return nil }
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
        return try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes])
    }

    func schema(_ c: Command) -> [String: Any] {
        var props: [String: Any] = [:]
        for p in c.params { props[p.name] = ["type": p.kind.rawValue, "description": p.help] }
        return ["name": c.toolName, "description": c.help,
                // Writes can remove data (contacts_update drops emails, notes_append rewrites the body), so every write is flagged.
                "annotations": ["readOnlyHint": c.effect == .read, "destructiveHint": c.effect != .read, "openWorldHint": false],
                "inputSchema": ["type": "object", "properties": props, "required": c.params.filter(\.required).map(\.name)]]
    }
}

// MARK: - MCP over HTTP (streamable HTTP transport, JSON responses only)

/// One endpoint, POST /mcp, behind a bearer token read from a mode-600 file. Read-only unless
/// started with --writes. Requests are answered one at a time, in arrival order.
enum HTTPServer {
    static let maxBody = 1 << 20

    static func start(_ argv: [String], registry: Registry) async throws -> Never {
        var opts: [String: String] = [:], writes = false, k = 0
        while k < argv.count {
            let a = argv[k]
            if a == "--writes" { writes = true } else if ["--host", "--port", "--token-file"].contains(a), k + 1 < argv.count {
                opts[String(a.dropFirst(2))] = argv[k + 1]; k += 1
            } else { throw AppleError.invalid("unknown serve argument \(a)") }
            k += 1
        }
        guard let host = opts["host"] else { throw AppleError.invalid("serve needs --host (the address to listen on, e.g. this Mac's Tailscale IP)") }
        guard let port = NWEndpoint.Port(opts["port"] ?? "7790") else { throw AppleError.invalid("bad --port") }
        let token = try readToken(opts["token-file"] ?? NSHomeDirectory() + "/.config/apple-cli/server-token")

        let mode = writes ? "reads and writes" : "read-only"
        let mcp = MCPServer(registry: registry, allowWrites: writes)
        let (queue, feed) = AsyncStream.makeStream(of: (Data, NWConnection).self)
        Task {
            for await (body, conn) in queue {
                let t = Date()
                if let reply = await mcp.handle(body) { respond(conn, 200, reply) } else { respond(conn, 202, Data()) }
                log("\(describe(body)) \(Int(Date().timeIntervalSince(t) * 1000)) ms")
            }
        }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { conn in
            // Connections without a valid token yet have their own small cap and 2 seconds to send headers,
            // so they cannot use up the slots of clients that have authenticated.
            let ip: String = { if case .hostPort(let h, _) = conn.endpoint { return "\(h)" }; return "?" }()
            guard openUnauthed < maxUnauthed, unauthedByIP[ip, default: 0] < maxUnauthedPerIP else { return conn.cancel() }
            openUnauthed += 1; unauthedByIP[ip, default: 0] += 1
            let slot = Slot()
            let leaveUnauthed = { openUnauthed -= 1; unauthedByIP[ip, default: 1] -= 1; if unauthedByIP[ip] == 0 { unauthedByIP[ip] = nil } }
            conn.stateUpdateHandler = { st in
                switch st {
                case .cancelled, .failed:
                    guard !slot.released else { return }
                    slot.released = true
                    if slot.authed { openAuthed -= 1 } else { leaveUnauthed() }
                default: break
                }
            }
            conn.start(queue: io)
            io.asyncAfter(deadline: .now() + headDeadline) { if !slot.authed { conn.cancel() } }
            readHead(conn, Data()) { head, rest in
                guard let head else { return respond(conn, 400, Data("bad request".utf8)) }
                guard head.path == "/mcp" else { return respond(conn, 404, Data()) }
                guard head.method == "POST" else { return respond(conn, 405, Data(), extra: ["Allow": "POST"]) }
                // Browsers send Origin; MCP clients do not. Refusing it blocks DNS-rebinding pages.
                guard head.headers["origin"] == nil else { return respond(conn, 403, Data()) }
                // The token is checked before any body is read.
                guard let auth = head.headers["authorization"], equalTimingSafe(auth, "Bearer " + token) else {
                    log("refused: bad or missing token from \(conn.endpoint)")
                    return respond(conn, 401, Data())
                }
                guard openAuthed < maxAuthed else { return respond(conn, 503, Data()) }
                leaveUnauthed(); openAuthed += 1; slot.authed = true
                guard let length = Int(head.headers["content-length"] ?? "0"), length >= 0, length <= maxBody else {
                    return respond(conn, 400, Data("bad content-length".utf8))
                }
                // Reading the body must finish within the deadline. Answering it can take longer.
                io.asyncAfter(deadline: .now() + bodyDeadline) { if !slot.readDone { conn.cancel() } }
                readBody(conn, rest, length: length) { body in
                    guard let body else { return respond(conn, 400, Data("bad request".utf8)) }
                    slot.readDone = true
                    feed.yield((body, conn))
                }
            }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: log("apple-cli \(version) serving MCP on http://\(host):\(port)/mcp, \(mode)")
            case .failed(let e): log("listener failed: \(e)"); exit(1)
            default: break
            }
        }
        listener.start(queue: io)
        while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }

    /// The token file must be private to this user, so a copy in a world-readable place is refused.
    static func readToken(_ path: String) throws -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue else { throw AppleError.notFound("token file \(path)") }
        guard mode & 0o077 == 0 else { throw AppleError.refused("\(path) is readable by other users; chmod 600 it") }
        let token = (try String(contentsOfFile: path, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 32 else { throw AppleError.invalid("the token in \(path) is under 32 characters") }
        return token
    }

    /// All connection work runs on this one queue, so the open-connection count needs no lock.
    static let io = DispatchQueue(label: "apple-cli.http")
    static let maxUnauthed = 32, maxUnauthedPerIP = 4, maxAuthed = 16, headDeadline = 2.0, bodyDeadline = 10.0, maxHead = 16384
    nonisolated(unsafe) static var openUnauthed = 0, openAuthed = 0
    nonisolated(unsafe) static var unauthedByIP: [String: Int] = [:]
    final class Slot: @unchecked Sendable { var released = false; var authed = false; var readDone = false }  // only touched on io

    struct Head { let method: String; let path: String; let headers: [String: String] }

    /// Reads up to the blank line after the headers. Hands back the parsed head (nil if malformed or over
    /// maxHead) and any body bytes that arrived with it.
    static func readHead(_ conn: NWConnection, _ buf: Data, _ done: @escaping (Head?, Data) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { chunk, _, isComplete, error in
            var buf = buf
            if let chunk { buf.append(chunk) }
            guard error == nil else { return done(nil, Data()) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                guard end.lowerBound <= maxHead else { return done(nil, Data()) }
                return done(parseHead(buf[..<end.lowerBound]), Data(buf[end.upperBound...]))
            }
            guard buf.count <= maxHead, !isComplete else { return done(nil, Data()) }
            readHead(conn, buf, done)
        }
    }

    static func parseHead(_ data: Data) -> Head? {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2, first[1].hasPrefix("/") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Head(method: String(first[0]), path: String(first[1].prefix { $0 != "?" }), headers: headers)
    }

    /// Reads until `length` body bytes have arrived. Nil if the client closes early.
    static func readBody(_ conn: NWConnection, _ buf: Data, length: Int, _ done: @escaping (Data?) -> Void) {
        if buf.count >= length { return done(Data(buf.prefix(length))) }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { chunk, _, isComplete, error in
            var buf = buf
            if let chunk { buf.append(chunk) }
            guard error == nil, buf.count >= length || !isComplete else { return done(nil) }
            readBody(conn, buf, length: length, done)
        }
    }

    static func respond(_ conn: NWConnection, _ status: Int, _ body: Data, extra: [String: String] = [:]) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 503: "Service Unavailable"][status] ?? ""
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty && status == 200 { head += "Content-Type: application/json\r\n" }
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        conn.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    static func equalTimingSafe(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) { diff |= Int((i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)) }
        return diff == 0
    }

    /// Method and tool name for the log. Never the arguments, which can hold message text or names.
    static func describe(_ body: Data) -> String {
        let msg = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let method = msg?["method"] as? String ?? "?"
        let tool = (msg?["params"] as? [String: Any])?["name"] as? String
        return tool.map { "\(method) \($0)" } ?? method
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(Data("\(localISO.string(from: Date())) \(s)\n".utf8))
    }
}
