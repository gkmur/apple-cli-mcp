"""Reminders: add with remind-me date, read, iCloud sync, complete, delete."""
from common import TOKEN, SYNC_TIMEOUT, cli, err, step, check, poll
import time

APP = "reminders"
state = {}


def add():
    out, ms = cli("reminders", "add", f"apple-cli {TOKEN}", "--at", "+2h", "--notes", "end-to-end test")
    check(not err(out), err(out))
    check(out.get("list") == "Reminders", f"landed in list {out.get('list')}")
    check(out.get("alarms"), "no remind-me alarm on the reminder")
    state["id"] = out["id"]
    return f"id {out['id']}, list Reminders, alarm {out['alarms'][0]}", ms


def read():
    out, ms = cli("reminders", "list", "--list", "Reminders")
    hit = [r for r in out.get("reminders", []) if r["id"] == state["id"]]
    check(hit, "reminder not in fast read path")
    check(hit[0].get("due") and hit[0].get("alarms"), "due date or alarm missing on read")
    return f"due {hit[0]['due']}", ms


def synced():
    t = time.time()
    hit = poll(lambda: next((r for r in cli("reminders", "list")[0].get("reminders", [])
                             if r["id"] == state["id"] and r["synced"]), None), SYNC_TIMEOUT)
    check(hit, f"no iCloud server record after {SYNC_TIMEOUT}s")
    return f"iCloud server record present after {time.time() - t:.1f}s", None


def complete():
    out, ms = cli("reminders", "complete", state["id"])
    check(out.get("completed"), err(out))
    back = [r for r in cli("reminders", "list", "--completed", "--limit", "10000")[0]["reminders"] if r["id"] == state["id"]]
    check(back and back[0]["completed"], "completion not visible in read path")
    return "completed, visible in read path", ms


def delete():
    out, ms = cli("reminders", "delete", state["id"])
    check(out.get("deleted"), err(out))
    gone = poll(lambda: all(r["id"] != state["id"] for r in cli("reminders", "list", "--completed", "--limit", "10000")[0]["reminders"]), 10)
    check(gone, "reminder still listed after delete")
    return "gone from read path", ms


def run():
    if step(APP, "add", add):
        step(APP, "read (fast path)", read)
        step(APP, "reached iCloud", synced)
        step(APP, "complete", complete)
        step(APP, "delete", delete)
