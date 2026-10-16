"""Calendar: add to the personal iCloud calendar, read back through agenda and search,
wait for the CalDAV server to accept it (ETag), privacy, then delete."""
from common import TOKEN, SYNC_TIMEOUT, cli, err, step, check, poll, user_config
import copy, os, sqlite3, time, datetime

APP = "calendar"
state = {}
DB = os.path.expanduser("~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb")
WHEN = (datetime.date.today() + datetime.timedelta(days=2)).isoformat()


def add():
    out, ms = cli("calendar", "add", f"apple-cli {TOKEN}", "--start", f"{WHEN} 03:00", "--duration", "30m",
                  "--location", "e2e", "--alert", "10m")
    check(not err(out), err(out))
    e = out["event"]
    state["id"] = e["id"]  # record first, so delete still runs if a check below fails
    check(e["source"] == "iCloud" and e["calendar"] == "Personal (iCloud)", f"landed in {e['calendar']} [{e['source']}]")
    check(e["alerts"] == [10], f"alerts {e['alerts']}")
    state["id"] = e["id"]
    return f"added to {e['calendar']} via its iCloud source", ms


def read():
    out, ms = cli("calendar", "agenda", "--from", WHEN, "--to", WHEN + " 23:59")
    check(any(e["id"] == state["id"] for e in out.get("events", [])), "event not in agenda")
    s, _ = cli("calendar", "search", TOKEN)
    check(any(e["id"] == state["id"] for e in s.get("events", [])), "event not found by search")
    return "found by agenda and search", ms


def synced():
    t = time.time()
    db = lambda: sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    def etag():
        r = db().execute("SELECT external_mod_tag FROM CalendarItem WHERE summary = ?", (f"apple-cli {TOKEN}",)).fetchone()
        return r and r[0]
    check(poll(etag, SYNC_TIMEOUT), f"no CalDAV ETag after {SYNC_TIMEOUT}s")
    return f"iCloud (CalDAV) accepted the event after {time.time() - t:.1f}s", None


def privacy():
    out, ms = cli("calendar", "add", "Therapy e2e check", "--start", f"{WHEN} 04:00")
    check((out.get("error") or {}).get("code") == "refused", f"privacy-matching title was not refused: {out}")
    cfg = copy.deepcopy(user_config()); cfg.setdefault("calendar", {})["excludeCalendars"] = ["Personal (iCloud)"]
    a, _ = cli("calendar", "agenda", "--from", WHEN, "--to", WHEN + " 23:59", config=cfg)
    check(all(e["id"] != state["id"] for e in a.get("events", [])), "excluded calendar's event still shown")
    return "privacy title refused; excluded calendar hidden", ms


def delete():
    out, ms = cli("calendar", "delete", state["id"])
    check(out.get("event", {}).get("deleted"), err(out))
    a, _ = cli("calendar", "agenda", "--from", WHEN, "--to", WHEN + " 23:59")
    check(all(e["id"] != state["id"] for e in a.get("events", [])), "event still listed after delete")
    return "gone from agenda", ms


def run():
    step(APP, "add (personal iCloud by source)", add)
    if "id" in state:
        step(APP, "read (agenda, search)", read)
        step(APP, "reached iCloud", synced)
        step(APP, "privacy", privacy)
        step(APP, "delete", delete)
