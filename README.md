# apple-cli

Fast Apple Notes, Reminders, Contacts, and Messages (read-only) for agents. One Swift binary is both the CLI and an MCP server. Design: [docs/architecture.md](docs/architecture.md).

- Notes and Reminders reads go straight to the apps' SQLite stores, opened read-only (a locked file is copied first), 15-250 ms. Contacts reads go through the Contacts framework so linked cards merge correctly, 0.2-0.5 s. Messages reads `chat.db` directly and decodes `attributedBody`, 0.5-0.6 s with contact names (about 30 ms with `--no-names`).
- Writes go through official routes only. Reminders use EventKit. Contacts use the Contacts framework. Notes uses AppleScript scoped to one note or folder ID, never a `whose` search. 0.1-0.8 s warm.
- Nothing ever writes to the databases, so iCloud sync stays intact.

## Install

```bash
swift build -c release && rm -f ~/.local/bin/apple-cli && cp .build/release/apple-cli ~/.local/bin/
```

Remove the old file before copying. Copying over a running or cached binary in place makes macOS kill the new one (exit 137).

## Commands

Add `--json` to any command.

```
apple-cli notes list [--folder NAME] [--limit N]
apple-cli notes folders
apple-cli notes search <query> [--limit N]
apple-cli notes read <id>
apple-cli notes create <title> [--body MARKDOWN] [--folder NAME]
apple-cli notes append <id> <markdown> [--force]
apple-cli notes trash <id>                      CLI only
apple-cli reminders list [--list NAME] [--completed] [--limit N]
apple-cli reminders due-today
apple-cli reminders add <title> [--at WHEN] [--list NAME] [--notes TEXT] [--priority N]
apple-cli reminders complete <id>
apple-cli reminders delete <id>                 CLI only
apple-cli contacts list [--group NAME] [--limit N]
apple-cli contacts search <name, email, or phone>
apple-cli contacts read <id>
apple-cli contacts groups
apple-cli contacts duplicates
apple-cli contacts create [--first] [--last] [--org] [--email work=a@b.com,…] [--phone mobile=+1…] [--birthday YYYY-MM-DD] [--group NAME]
apple-cli contacts update <id> [--first …] [--add-email …] [--remove-email …] [--add-phone …] [--remove-phone …]
apple-cli contacts delete <id>                  CLI only
apple-cli messages chats [--limit N] [--no-names]
apple-cli messages read <chat> [--limit N | --all] [--since WHEN] [--before WHEN]
apple-cli messages search <query> [--chat …] [--from name|phone|email|me] [--since WHEN]
apple-cli messages unread [--since WHEN]
apple-cli messages stats
apple-cli doctor                                permissions, store files, schema, speed per app
apple-cli mcp                                   MCP server on stdio
```

`--at` takes `YYYY-MM-DD [HH:MM]`, `today|tomorrow [HH:MM]`, or `+30m`, `+2h`, `+1d`. With no `--at`, the reminder is set for tomorrow at the default time. Every reminder gets a due date and an alarm at that moment, so it always pings.

The MCP server exposes the same commands as tools (`notes_search`, `contacts_read`, `doctor`, ...), with read-only hints. Commands marked CLI only are destructive and are never MCP tools. Errors come back as `{"error": {"code", "message"}}`, with codes `not_found`, `hidden`, `refused`, `permission`, `schema_changed`, `timeout`, `invalid`, `app_error`, and `database`.

## Behavior to know

- `notes append` refuses a note with a checklist, table, image, hashtag, or link, unless you pass `--force`. Notes rewrites the whole body on a scripted append and drops those.
- Checkbox lines in Markdown become plain bullets when written. Notes scripting cannot create checklists.
- A note Notes has not downloaded from iCloud yet lists with no title, and `read` says so. Open it once in Notes to fetch it.
- If Apple changes a database layout in an OS update, reads fail with `schema_changed` instead of returning wrong data. Run `apple-cli doctor`.
- A contact's `synced` is true once iCloud's CardDAV server has accepted the card, and null for linked people.
- `messages read` takes a chat ID, a group name, a contact name, a phone number, or an email. `--since` and `--before` take `YYYY-MM-DD [HH:MM]`, `today`, `yesterday`, or `7d`/`12h`/`30m` ago.
- Messages is read-only. Reactions fold into the message they react to. Attachments come back with their file path.

## Privacy

`~/.config/apple-cli/config.json` is created on first run. Notes whose title matches `excludeTitlePatterns`, notes in `excludeFolders`, notes in `excludeNoteIDs`, and every password-protected note are dropped before any command sees them. They never print, search skips them, and `read` or `append` on one fails with "hidden by privacy config". The defaults hide credential-looking titles plus journal and therapy notes.

`reminders` has `defaultList` (`Reminders`), `defaultTime` (`09:00`), and `excludeLists`. `contacts` has `excludeNamePatterns`, `excludeGroups`, and `excludeContactIDs`. `messages` has `excludeChats` (chat ID or group name), `excludeHandles` (phone or email), `excludeNamePatterns`, and `maskOneTimeCodes` (on by default, so verification-code texts read as `[one-time code hidden]` and stay out of search). A contact hidden in `contacts` is hidden in Messages too. If a privacy rule needs Contacts and Contacts cannot be read, Messages commands fail instead of showing unfiltered chats. Each app's section is optional, and missing keys fall back to the defaults.

## Test

```bash
python3 scripts/e2e/run.py
```

## Add an app

2. Add `Sources/AppleKit/Domains/<App>.swift` with a settings struct, a `Domain`, and its commands. Mark each command `.read`, `.write`, or `.destructive`.
3. Add it to `allDomains` in `Core/Interface.swift`.
4. Add `scripts/e2e/<app>.py` and register it in `run.py`.
