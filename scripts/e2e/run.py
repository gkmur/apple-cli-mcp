#!/usr/bin/env python3
"""End-to-end test: real apps, real iCloud.

Each app module creates a test item through the official write path, reads it back
through the fast read path, waits until iCloud has accepted it, then removes it.
The MCP check runs last. Writes reports/e2e-<timestamp>.md and exits 0 only if
every step passed.

Usage: python3 scripts/e2e/run.py [--app notes|reminders|contacts ...]
"""
import argparse, datetime, json, os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
from common import BIN, ROOT, TOKEN, step, check
import notes, reminders, contacts, messages, photos

APPS = {"notes": notes, "reminders": reminders, "contacts": contacts, "messages": messages, "photos": photos}


def mcp():
    msgs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "doctor", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "reminders_due_today", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "contacts_delete", "arguments": {"id": "x"}}},
    ]
    t = time.perf_counter()
    p = subprocess.run([BIN, "mcp"], input="\n".join(json.dumps(m) for m in msgs) + "\n", capture_output=True, text=True, timeout=60)
    ms = (time.perf_counter() - t) * 1000
    replies = {r["id"]: r for r in map(json.loads, p.stdout.splitlines())}
    tools = {x["name"]: x for x in replies[2]["result"]["tools"]}
    for bad in ("notes_trash", "reminders_delete", "contacts_delete"):
        check(bad not in tools, f"destructive tool {bad} is exposed")
    check(tools["notes_list"]["annotations"]["readOnlyHint"] and not tools["notes_create"]["annotations"]["readOnlyHint"], "readOnlyHint wrong")
    check(replies[3]["result"]["structuredContent"]["ok"], "doctor over MCP reports a failure")
    check(not replies[4]["result"]["isError"], "reminders_due_today errored")
    check(replies[5].get("error"), "calling a destructive tool did not error")
    return f"{len(tools)} tools, no destructive tools, annotations set, doctor ok", ms


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", action="append", choices=list(APPS), help="Run only these apps (repeatable)")
    apps = ap.parse_args().app or list(APPS)
    started = datetime.datetime.now().astimezone()
    print(f"apple-cli e2e  token {TOKEN}  apps {', '.join(apps)}")
    for a in apps:
        APPS[a].run()
    step("mcp", "server", mcp)

    passed = all(s[2] for s in common.steps)
    os.makedirs(os.path.join(ROOT, "reports"), exist_ok=True)
    path = os.path.join(ROOT, "reports", f"e2e-{started:%Y-%m-%d-%H%M}.md")
    version = subprocess.run([BIN, "--version"], capture_output=True, text=True).stdout.strip()
    with open(path, "w") as f:
        f.write("# apple-cli end-to-end report\n\n")
        f.write(f"- Run: {started:%Y-%m-%d %H:%M %Z}\n- Version: {version}\n- Apps: {', '.join(apps)}\n")
        f.write(f"- Result: **{'PASS' if passed else 'FAIL'}** ({sum(s[2] for s in common.steps)}/{len(common.steps)} steps)\n")
        f.write(f"- Test token: `{TOKEN}`\n\n")
        f.write("| App | Step | Result | Command time | Step time | Detail |\n|---|---|---|---|---|---|\n")
        for app, name, ok, cmd_ms, total, detail in common.steps:
            c = f"{cmd_ms:.0f} ms" if cmd_ms is not None else "-"
            f.write(f"| {app} | {name} | {'pass' if ok else '**fail**'} | {c} | {total:.0f} ms | {str(detail).replace('|', '/')} |\n")
        f.write("\n\"Reached iCloud\" means the server confirmed the item: a CloudKit server record for notes "
                "(`ZSERVERRECORDDATA`) and reminders (`ZCKSERVERRECORDDATA`), and a CardDAV ETag "
                "(`ZEXTERNALMODIFICATIONTAG`) for contacts.\n")
    print(f"\n{'PASS' if passed else 'FAIL'}  report: {path}")
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
