# apple-cli architecture

Status: built in v0.2.0 (2026-10-15). Notes, Reminders, and Contacts run on this foundation. The notes in this file match the code; section 8 lists where the build differed from the proposal.

## 1. Requirements

**What it does**
- One binary that you own gives agents fast access to Apple apps on this Mac. Each app is a **domain**. Notes and Reminders exist today. Next come Contacts (replacing `icloud-pp-cli contacts`), Safari history (replacing `safari-history-pp-cli`), Calendar, and Messages.
- Every domain is reachable three ways from one definition: the CLI, the CLI with `--json`, and the MCP server.
- Reads are fast. Writes go only through an official Apple path, so iCloud and other sync stays intact.

**Targets**

| Need | Target |
|---|---|
| Read latency | p95 under 0.5 s, warm |
| Write latency | p95 under 1 s, warm. A cold app launch is allowed once |
| Hangs | None. Every external call has a timeout |
| Correctness | Never return wrong data silently. If Apple changes a schema, fail loudly and say what broke |
| Privacy | Hidden items never reach stdout, JSON, or MCP, whatever the command |
| Safety | Destructive verbs are CLI only, never MCP tools |

**Constraints**
- One user, one Mac, macOS 27. This is a single-process CLI, so there's no server, queue, or cache layer to scale.
- Apple ships no schema docs. Stores change with OS updates.
- Each access path needs its own macOS permission (Full Disk Access, Contacts, Reminders, Calendars, Automation).
- Code stays in Swift with no third-party dependencies. You own all of it.

## 2. High-level design

```
            CLI (argv)            MCP (JSON-RPC stdio)
                 \                   /
                  v                 v
            +-----------------------------+
            |  Registry: [Domain]         |  one command table
            |  dispatch, arg parse,       |  -> CLI help, MCP tools/list,
            |  output, errors, policy     |     input + output schemas
            +-------------+---------------+
                          |
     +----------+---------+----------+-----------+
     v          v                    v           v
  Notes     Reminders            Contacts     (Safari, Calendar, Messages ...)
  domain     domain               domain        one folder each
     |          |                    |
  read: SQLite  read: SQLite      read: Contacts framework
  write: AppleScript  write: EventKit   write: Contacts framework
     |          |                    |
     +----------+---------+----------+
                          v
            Core: SQLiteReader, Protobuf, Gzip, Osascript runner,
                  Config (per-domain sections), Privacy, Doctor,
                  Timeouts, Errors
```

### The domain contract

Each app is one folder under `Sources/AppleKit/Domains/<App>/` that provides a single value:

```swift
public struct Domain {
    let name: String                         // "contacts"
    let commands: (Context) -> [Command]     // verbs for this app
    let checks: (Context) -> [Check]         // used by `apple-cli doctor`
}
```

Adding an app means adding one folder and one line in the registry list. Nothing in core changes.

### Commands

`Command` keeps today's shape, with three additions.
- **`effect`** is `.read`, `.write` or `.destructive`. The registry derives the MCP policy from it: destructive commands are never exposed, and the MCP `readOnlyHint` / `destructiveHint` annotations come from the same field. Today that rule is a hand-set `mcp: Bool`.
- **Typed output.** Each command returns an `Encodable` value, not `[String: Any]`. JSON output is then stable, and an MCP `outputSchema` is generated from one sample. Human output is a `render` function on the same type.
- **Stable error codes.** Errors carry a code (`not_found`, `hidden`, `refused`, `permission`, `schema_changed`, `timeout`, `invalid`) plus a message. Agents branch on the code, never on the text.

## 3. Deep dive

### Read backends: pick per domain, by evidence

| Domain | Read path | Why |
|---|---|---|
| Notes | SQLite plus protobuf | AppleScript enumeration hangs. Bodies only exist as protobuf |
| Reminders | SQLite | EventKit is fast too, but it hides flagged, tags, and subtask links |
| Contacts | **Contacts framework** | 0.06 s name search, 0.35 s full list. It merges linked cards correctly (534 cards become 530 people). The SQLite files are 5 per-account stores with placeholder rows, so merging by hand would be fragile |
| Safari history | SQLite | No framework exists |
| Calendar | To decide in its teardown | EventKit date-range queries are fast, so SQLite may only be needed for search |
| Messages | SQLite | No framework exists |

The rule is to use the **fastest correct official path**, and drop to SQLite only when the official path hangs, is slow, or hides needed data. Each choice was made from a teardown of that app's storage.

### Schema guard (correctness over OS updates)

Each SQLite domain declares the columns it reads:

```swift
let expected = ["ZICCLOUDSYNCINGOBJECT": ["ZTITLE1", "ZFOLDER", ...]]
```

On open, `SQLiteReader` checks those columns against `pragma table_info` (under 1 ms). A missing column throws `schema_changed` with the table and column names. `doctor` runs the same check for every domain. This turns a silent wrong answer after a macOS update into a clear error.

### Config: per-domain sections that cannot break each other

Today `Config` is one Codable struct. Adding a `contacts` key would make every existing `config.json` fail to decode and break the whole CLI. The new design:
- The file is a JSON object keyed by domain name.
- Each domain defines a settings struct with defaults.
- `ctx.settings(ContactsSettings.self)` decodes that one section, with defaults filling any missing fields.
- On first run, the file is written with every domain's defaults. Later, missing sections are filled in memory and never rewritten over your edits.

### Privacy: one filter, many domains

`Privacy` becomes generic. Each domain maps its items to a `Sensitive` value with `title`, `container` (folder, list, group, or chat), `id`, and `locked`. The same rules (title regex, container names, IDs) apply everywhere, configured per domain. Filtering runs inside the domain's read function before results return. No command can print a hidden item, because hidden items never leave that function. Defaults:
- Notes: as today (credential, journal, and therapy titles, plus locked notes).
- Contacts: no defaults. You can exclude groups or contact IDs. Contact notes are never read, because Apple restricts that field to apps with a special entitlement.
- Messages: an exclude list of chats or handles before any read.

### Write paths

All writes go through `Writers/`.

| Domain | Write path | Sync confirmation |
|---|---|---|
| Notes | `osascript` from stdin, args as argv, 15 s timeout, single ID only | `ZSERVERRECORDDATA` set |
| Reminders | EventKit | `ZCKSERVERRECORDDATA` set |
| Contacts | `CNSaveRequest` | CardDAV ETag (`ZEXTERNALMODIFICATIONTAG`) set on the new card |

Every writer returns the new item's stable ID, so a read can follow immediately.

### Permissions and `doctor`

`apple-cli doctor [--json]` reports, per domain:
- whether each needed permission is granted, with the exact System Settings path if not;
- whether each store file is present and readable;
- the schema guard result;
- read latency.

This becomes the first thing an agent runs when a command fails.

### Testing

The single `scripts/e2e.py` becomes a runner with one module per domain (`scripts/e2e/notes.py`, `contacts.py`, ...). Each module runs create, read back, wait for sync, and clean up. The runner writes one report per run, and `--domain contacts` runs one. No unit tests, as per your rules.

## 4. Scale and reliability

- **Load** is one person, so there's no horizontal scaling. The real limit is per-call latency. Measured warm: SQLite reads 15–35 ms, Contacts reads 60–350 ms, EventKit writes 100–200 ms, AppleScript writes 210–330 ms.
- **Contention.** The apps own their stores and hold write locks. A read uses `mode=ro` with a 250 ms busy timeout, then falls back to reading a copy of the files.
- **Hangs.** Every subprocess and framework call has a deadline. `osascript` gets 15 s, and the framework calls run under a watchdog.
- **Observability.** `APPLE_CLI_DEBUG=1` prints per-step timings to stderr. `doctor` is the health check. An optional JSONL log of command, duration and error code (no content) under `~/.local/state/apple-cli/` would show which commands agents actually use.

## 5. Trade-offs

| Decision | Gain | Cost |
|---|---|---|
| Swift, no dependencies | One binary, native frameworks, millisecond startup, fully owned | More hand-written code (JSON-RPC, arg parsing) than a library would need |
| One binary for every domain | One install, one MCP server, shared privacy and doctor | A crash in one domain's code affects all of them. The schema guard and per-command errors limit the damage |
| Framework reads for Contacts | Correct merging, official, survives schema changes | 0.06–0.35 s instead of about 30 ms |
| SQLite reads for Notes and Reminders | Fast, and has data the official APIs hide | Undocumented schemas. The schema guard and teardown docs carry the risk |
| Typed `Encodable` outputs | Stable JSON contract, MCP output schemas | Each domain defines output structs (roughly 30 lines each) |
| Destructive verbs CLI only | Agents can't delete over MCP | You or a script must run deletes |

## 6. Revisit later

- **A second binary per domain** if one domain's framework adds too much launch time. Measure with `APPLE_CLI_DEBUG` first.
- **A long-running MCP process cache.** If agents call `contacts search` in tight loops, keep the `CNContactStore` warm in the MCP process (the CLI stays stateless).
- **Write queue or offline retry.** Only needed if a sync check starts timing out regularly.
- **Calendar and Messages read backends**, decided in their teardowns.
- **Signing and notarizing** the binary if macOS starts to re-prompt for permissions after rebuilds. Today they're tied to the parent app.

## 7. Migration from v0.1

1. Move each domain into `Domains/<App>/` and introduce `Domain`, `effect`, and error codes. No behavior changes, and the e2e test must pass unchanged.
2. Add per-domain config sections with in-memory defaults. Existing `config.json` files keep working.
3. Add typed outputs, the schema guard, and `doctor`.
4. Add the Contacts domain on the new foundation, then uninstall `icloud-pp-cli` once its e2e passes.

## 8. Where the build differed from the proposal

- **MCP output.** Tool results carry the typed output as `structuredContent` next to the JSON text. No `outputSchema` is published yet, because generating one from a single sample would be guesswork. Revisit if an agent client needs it.
- **Usage log.** The optional JSONL usage log is not built. `APPLE_CLI_DEBUG=1` per-command timing is.
- **Contacts read speed.** A full list of 530 people takes about 0.47 s. That's Apple's framework doing one pass, after cutting the fields fetched and caching label names (which made it 1.07 s, then 0.47 s). Search uses Apple's indexed name, email, and phone lookups first (about 0.23 s for the whole command) and scans everyone only when those find nothing.
- **Contacts sync state.** `synced` is null for linked people. The framework gives a merged person an ID that no account file stores (5 of 530 here).
- **Reminders privacy.** Reminders gained `excludeLists`, which removes those lists from every read and refuses writes to them.
