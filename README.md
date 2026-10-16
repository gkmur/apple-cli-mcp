# apple-cli

Fast access for agents to Apple Notes, Reminders, Contacts, Calendar, Photos, Messages, Mail, Safari, Voice Memos, Shortcuts, call history, and Music. One Swift binary is both the CLI and an MCP server. Design: [docs/architecture.md](docs/architecture.md).

- Notes and Reminders reads go straight to the apps' SQLite stores, opened read-only (a locked file is copied first), 15-250 ms. Contacts reads go through the Contacts framework so linked cards merge correctly, 0.2-0.5 s. Messages reads `chat.db` directly and decodes `attributedBody`, 0.5-0.6 s with contact names (about 30 ms with `--no-names`).
- Calendar uses EventKit for reads and writes. Photos reads `Photos.sqlite` read-only and downloads or deletes through PhotoKit. Mail, Safari, Voice Memos, Shortcuts, and call history read their stores directly, under 0.5 s for normal queries (`mail search --body` scans message files, about 2.5 s for 90 days).
- Writes go through official routes only. Reminders use EventKit. Contacts use the Contacts framework. Notes uses AppleScript scoped to one note or folder ID, never a `whose` search. 0.1-0.8 s warm.
- Nothing ever writes to the databases, so iCloud sync stays intact.

## Install

```bash
Support/install.sh
```

This builds apple-cli, wraps it in `~/Applications/AppleCLI.app`, signs it with your Apple Development certificate, and links `~/.local/bin/apple-cli` to it.

Every command runs as AppleCLI, whatever launched it (Claude, Terminal, launchd, SSH). So macOS permissions belong to AppleCLI, and one set of grants works everywhere on that Mac. After the first install:

```bash
apple-cli permissions --request
```

This shows each prompt not yet answered (Contacts, Calendars, Reminders, Photos, control of Notes and Music). It also opens the Full Disk Access pane with AppleCLI.app selected in Finder; drag it into the list and switch it on. Run it from a logged-in session, because prompts cannot show over SSH. The grants are tied to the signing certificate, so rebuilds keep them.

### On an always-on Mac

```bash
apple-cli serve --host <tailscale-ip> --token-file ~/.config/apple-cli/server-token --writes
```

Run this on a Mac that stays awake (I use a Mac mini), as a launchd job. It listens on the Tailscale address only, port 7790, and needs the bearer token in the token file (mode 600). With `--writes`, agents on your tailnet can draft and send texts and email, and edit your apps; deletes stay CLI only. Without it the server is read-only. The log records method and tool names only.

The first run needs a logged-in session on that Mac: allow AppleCLI through the firewall, answer the permission prompts, and give it Full Disk Access.

### From claude.ai and cloud sessions

`--access-port 7791 --access-team TEAM --access-aud TAG` adds a second listener on `127.0.0.1:7791` for a Cloudflare tunnel, with a Cloudflare Access app in front. apple-cli checks Access's signed header, `Cf-Access-Jwt-Assertion`, against the team's keys and that app's audience tag, so a request that skipped Access is refused.

- **claude.ai**: add the tunnel's `/mcp` URL as a custom connector. Access handles the login and gives claude.ai a token that refreshes for 2 weeks. You get reads and writes, sends included.
- **Cloud sessions and scripts**: send an Access service token as headers `CF-Access-Client-Id` and `CF-Access-Client-Secret`. They get reads, drafts, and edits. `mail_send` and `messages_send` are not offered.
- Deletes stay with the local CLI token.
- Leave out `--access-port` and this listener never starts.

### Routing: one Mac does the work

On a laptop, set `remote.url` in `~/.config/apple-cli/config.json` to the always-on Mac. Every command of Mail, Messages, Reminders, Calendar, Contacts, and Notes then runs there (`remote.apps` changes the list), reads and writes alike, and prints `(ran on the mini)`. Whole apps move together because IDs differ between Macs: an event, contact, or email ID from one Mac names nothing, or something else, on the other.

- Music, Photos, Safari, Voice Memos, call history, Shortcuts, `person`, `today`, `search`, `permissions`, and `doctor` run locally.
- Deletes of routed apps run remotely too. The router uses the CLI token (`~/.config/apple-cli/remote-token`), which can delete; the agent token cannot.
- A text with a file from this Mac is drafted and sent here. Email with attachments from this Mac needs `--local`. Saved mail attachments land on the remote Mac.
- If the remote Mac is unreachable, routed commands fail with a clear error and run nowhere. `--local` (or `APPLE_CLI_LOCAL=1`) runs one on this Mac's copy.
- Both Macs must run the same version; the router refuses otherwise.
- Notes and Mail only refresh their local copies while open, so reopen them in the background on a schedule on the remote Mac.

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
apple-cli reminders move <id> --at WHEN
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
apple-cli photos stats | storage [--by …] | top | videos | albums
apple-cli photos list [--album …] [--since …] [--kind …]
apple-cli photos download <ids> [--to …]
apple-cli photos delete <ids>                   CLI only
apple-cli calendar calendars | today
apple-cli calendar agenda [--days N] [--from …] [--to …]
apple-cli calendar search <query> [--since …] [--until …]
apple-cli calendar add <title> [--start …] [--end … | --duration …] [--all-day] [--location …] [--alert …] [--calendar …]
apple-cli calendar delete <id> [--all | --start WHEN]  CLI only
apple-cli safari history | search <query> | domains | visited <url or domain> | bookmarks | tabs
apple-cli mail mailboxes
apple-cli mail list [--mailbox …] [--account …] [--since …] [--unread] [--flagged]
apple-cli mail search <query> [--from …] [--mailbox …] [--since …] [--body]
apple-cli mail unread [--since …]
apple-cli mail read <id> [--max-chars N]
apple-cli voicememos list | read <id> | search <query>
apple-cli shortcuts list | read <name or id>
apple-cli shortcuts run <name or id> [--input TEXT]   CLI only
apple-cli calls recent | missed [--since …] [--no-names]
apple-cli calls with <name, phone, or email>
apple-cli music recent | top | search <query> | playlists | now   [--launch]
apple-cli notes move <id> --folder NAME | rename <id> --title T | new-folder <name>
apple-cli reminders update <id> [--title --notes --priority --list] | uncomplete <id>
apple-cli calendar update <id> [--title --start --end --duration --location --notes --alert --calendar] [--all]
apple-cli contacts group <id> [--add GROUP] [--remove GROUP] | new-group <name>
apple-cli messages draft <to> --text T [--file PATH] [--sms]      then: messages send <draft-id>
apple-cli mail draft --to A,B --body T [--subject --cc --bcc --from --attach P,Q --reply-to ID --reply-all --forward ID]
apple-cli mail send <draft-id> [--save-only]
apple-cli mail modify <ids> --action archive|trash|move|read|unread|flag|unflag [--mailbox PATH]
apple-cli mail attachments <id> --to FOLDER
apple-cli photos organize <ids> --action add-to-album|remove-from-album|favorite|unfavorite [--album NAME]
apple-cli music play [query] [--playlist NAME] | control pause|resume|next|previous|volume [--level N] | add-to-playlist <query> --playlist NAME
apple-cli safari read-later <url> [--title T]
apple-cli person <name, contact ID, phone, or email> [--limit N]
                                                contact card, texts, mail from them, calls, shared events, last contact
apple-cli today                                 calendar, reminders due, unread texts, missed calls, unread mail
apple-cli search <query> [--apps messages,mail,notes,safari,voicememos] [--limit N]
                                                one search across apps, newest first
apple-cli photos access [--request]             whether AppleCLI has Photos full access
apple-cli permissions [--request]               every macOS permission AppleCLI holds
apple-cli doctor                                permissions, store files, schema, speed per app
apple-cli mcp                                   MCP server on stdio
apple-cli serve --host IP [--port 7790] [--token-file PATH] [--writes] [--access-port 7791 --access-team TEAM --access-aud TAG]
                                                MCP server over HTTP, bearer token, read-only by default
```

`--at` takes `YYYY-MM-DD [HH:MM]`, `today|tomorrow [HH:MM]`, or `+30m`, `+2h`, `+1d`. With no `--at`, the reminder is set for tomorrow at the default time. Every reminder gets a due date and an alarm at that moment, so it always pings.

The MCP server exposes the same commands as tools (`notes_search`, `contacts_read`, `doctor`, ...), with read-only hints. Commands marked CLI only are destructive and are never MCP tools. Errors come back as `{"error": {"code", "message"}}`, with codes `not_found`, `hidden`, `refused`, `permission`, `schema_changed`, `timeout`, `invalid`, `app_error`, and `database`.

## Sending

Texts and email go out in two steps. `messages draft` and `mail draft` resolve the recipient and save a draft (`d_1a2b3c4d`) that shows exactly what will be sent. `messages send <id>` or `mail send <id>` sends that draft unchanged. A draft sends once and expires after an hour. Agents must show the draft to you and wait for your yes before sending; the draft ID makes sure what you approved is what leaves.

- A text goes to an existing chat (a group, or anyone you have texted) or starts a new one with a phone or email, over iMessage or `--sms`. `send` then watches `chat.db` and reports `delivered`, `sent`, `sending`, or `failed`.
- Email goes through Mail.app from any account set up in Mail.app. Replies and forwards keep threading. `send` confirms the copy in a Sent mailbox. A reply or forward of a message masked as a one-time code, or one whose body Mail has not downloaded, is refused.
- At most 30 sends an hour (`send.sendsPerHour` in config), counted in `~/Library/Logs/apple-cli/sends.log` under a lock.
- Every write, send included, adds a line to `~/Library/Logs/apple-cli/audit.log`: time, command, recipient, status. Never message text.
- Over MCP, attachments must already be in `~/Downloads/apple-cli`, so an agent cannot mail out arbitrary files.
- Safari has no supported way to add bookmarks, so only the Reading List is writable. Voice Memos and call history have no write routes.

## Behavior to know

- `notes append` refuses a note with a checklist, table, image, hashtag, or link, unless you pass `--force`. Notes rewrites the whole body on a scripted append and drops those.
- Checkbox lines in Markdown become plain bullets when written. Notes scripting cannot create checklists.
- A note Notes has not downloaded from iCloud yet lists with no title, and `read` says so. Open it once in Notes to fetch it.
- `notes trash` moves the note into Recently Deleted. A scripted `delete` stays unsaved until Notes' next insert.
- If Apple changes a database layout in an OS update, reads fail with `schema_changed` instead of returning wrong data. Run `apple-cli doctor`.
- A contact's `synced` is true once iCloud's CardDAV server has accepted the card, and null for linked people.
- `messages read` takes a chat ID, a group name, a contact name, a phone number, or an email. `--since` and `--before` take `YYYY-MM-DD [HH:MM]`, `today`, `yesterday`, or `7d`/`12h`/`30m` ago.
- Messages is read-only. Reactions fold into the message they react to. Attachments come back with their file path.
- `calendar add` defaults to the one writable calendar whose source is iCloud. `--alert` replaces the calendar's default alerts.
- Mail's index only updates while Mail.app runs, so every Mail listing reports `indexedThrough`, plus a `warning` once it is over a day old. Bodies come from Mail's `.emlx` files; `bodyAvailable` is false when Mail has not downloaded one.
- `shortcuts read` lists action identifiers only, never parameters, which can hold URLs and tokens.
- Voice Memos transcripts come from inside each `.m4a`, split into timed sentences.
- `person`, `today`, and `search` read each app separately. If one app fails (a missing permission, say), the rest still come back and the failure is listed under `errors`.
- `person` matches calendar attendees by full name or email, so a first name alone never pulls in someone else's meetings.
- Music reads go through Music's scripting dictionary in bulk (about 0.3 s for the whole library). Commands refuse while Music is closed unless you pass `--launch`, since scripting opens it.

## Privacy

`~/.config/apple-cli/config.json` is created on first run. Notes whose title matches `excludeTitlePatterns`, notes in `excludeFolders`, notes in `excludeNoteIDs`, and every password-protected note are dropped before any command sees them. They never print, search skips them, and `read` or `append` on one fails with "hidden by privacy config". The defaults hide credential-looking titles plus journal and therapy notes.

`reminders` has `defaultList` (`Reminders`), `defaultTime` (`09:00`), and `excludeLists`. `contacts` has `excludeNamePatterns`, `excludeGroups`, and `excludeContactIDs`. `messages` has `excludeChats` (chat ID or group name), `excludeHandles` (phone or email), `excludeNamePatterns`, and `maskOneTimeCodes` (on by default, so verification-code texts read as `[one-time code hidden]` and stay out of search). A contact hidden in `contacts` is hidden in Messages too. If a privacy rule needs Contacts and Contacts cannot be read, Messages commands fail instead of showing unfiltered chats. `calendar` has `excludeCalendars` and `excludeTitlePatterns`. `photos` has `includeHidden` and `excludeAlbums`. `safari` has `excludeDomains` and `excludePatterns`. `mail` has `excludeMailboxes`, `excludeAddresses` (address or domain), `excludeSubjectPatterns`, and `maskOneTimeCodes` (also masks sign-in and password-reset emails). `voicememos` has `excludeTitlePatterns` and `excludeIDs`. `shortcuts` has `excludeNamePatterns`. `calls` has `excludeHandles` and `excludeNamePatterns`. A contact hidden in `contacts` is hidden in Mail and call history too. Each app's section is optional, and missing keys fall back to the defaults.

## Test

```bash
python3 scripts/e2e/run.py
```

For each app, it creates a test item through the write path, reads it back, waits for iCloud to accept it, then removes it. It finishes by checking the MCP server. `--app contacts` runs one app. Writes `reports/e2e-<timestamp>.md`.

## Add an app

1. Map the app's storage first: where it lives, its schema, and which official API (if any) reads and writes it.
2. Add `Sources/AppleKit/Domains/<App>.swift` with a settings struct, a `Domain`, and its commands. Mark each command `.read`, `.write`, or `.destructive`.
3. Add it to `allDomains` in `Core/Interface.swift`.
4. Add `scripts/e2e/<app>.py` and register it in `run.py`.
