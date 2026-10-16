# apple-cli

Fast Apple Notes and Reminders for agents. One Swift binary is both the CLI and an MCP server.

- Reads go straight to the apps' SQLite stores, opened read-only (a locked file is copied first). 15-250 ms.
- Writes go through official routes only. Reminders use EventKit. Notes uses AppleScript scoped to one note or folder ID, never a `whose` search. 0.1-0.35 s warm.
- Nothing ever writes to the databases, so iCloud sync stays intact.

## Install

```bash
swift build -c release && cp .build/release/apple-cli ~/.local/bin/
```

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
apple-cli mcp                                   MCP server on stdio
```

`--at` takes `YYYY-MM-DD [HH:MM]`, `today|tomorrow [HH:MM]`, or `+30m`, `+2h`, `+1d`. With no `--at`, the reminder is set for tomorrow at the default time. Every reminder gets a due date and an alarm at that moment, so it always pings.

The MCP server exposes the same commands as tools (`notes_search`, `reminders_add`, ...). The two delete commands stay CLI only.

## Behavior to know

- `notes append` refuses a note with a checklist, table, image, hashtag, or link, unless you pass `--force`. Notes rewrites the whole body on a scripted append and drops those.
- Checkbox lines in Markdown become plain bullets when written. Notes scripting cannot create checklists.
- A note Notes has not downloaded from iCloud yet lists with no title, and `read` says so. Open it once in Notes to fetch it.

## Privacy

`~/.config/apple-cli/config.json` is created on first run. Notes whose title matches `excludeTitlePatterns`, notes in `excludeFolders`, notes in `excludeNoteIDs`, and every password-protected note are dropped before any command sees them. They never print, search skips them, and `read` or `append` on one fails with "hidden by privacy config". The defaults hide credential-looking titles plus journal and therapy notes.

`reminders.defaultList` (`Reminders`) and `reminders.defaultTime` (`09:00`) are set there too.

## Test

