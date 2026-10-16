"""Notes: create, read, search, append, iCloud sync, trash."""
from common import TOKEN, SYNC_TIMEOUT, cli, err, step, check, poll
import time

APP = "notes"
state = {}


def create():
    out, ms = cli("notes", "create", f"apple-cli {TOKEN}", "--body", f"Body line with **{TOKEN}**\n\n- item one\n- item two")
    check(not err(out), err(out))
    check(out.get("id"), f"no stable id returned: {out}")
    state["id"] = out["id"]
    return f"id {out['id']}", ms


def read():
    out, ms = cli("notes", "read", state["id"])
    check(TOKEN in out.get("markdown", ""), "token missing from body")
    check("- item two" in out["markdown"], "list did not round-trip")
    return f"{len(out['markdown'])} chars of Markdown, list intact", ms


def search():
    out, ms = cli("notes", "search", TOKEN)
    ids = [r["id"] for r in out.get("results", [])]
    check(state["id"] in ids, f"search returned {ids}")
    return f"found in {len(ids)} result(s)", ms


def append():
    out, ms = cli("notes", "append", state["id"], f"Appended {TOKEN}-tail")
    check(out.get("appended"), err(out))
    back, _ = cli("notes", "read", state["id"])
    check(f"{TOKEN}-tail" in back.get("markdown", ""), "appended text not read back")
    return "appended text read back", ms


def synced():
    t = time.time()
    hit = poll(lambda: next((n for n in cli("notes", "list", "--limit", "50")[0].get("notes", [])
                             if n["id"] == state["id"] and n["synced"]), None), SYNC_TIMEOUT)
    check(hit, f"no iCloud server record after {SYNC_TIMEOUT}s")
    return f"iCloud server record present after {time.time() - t:.1f}s", None


def trash():
    out, ms = cli("notes", "trash", state["id"])
    check(out.get("trashed"), err(out))
    gone = poll(lambda: all(n["id"] != state["id"] for n in cli("notes", "list", "--limit", "500")[0].get("notes", [])), 10)
    check(gone, "note still listed after trash")
    return "moved to Recently Deleted, gone from list", ms


def run():
    if step(APP, "create", create):
        step(APP, "read (fast path)", read)
        step(APP, "search (fast path)", search)
        step(APP, "append", append)
        step(APP, "reached iCloud", synced)
        step(APP, "trash", trash)
