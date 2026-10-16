"""Calls (read-only): recent and missed counts against the database, calls with one number, privacy."""
from common import cli, err, step, check, user_config
import copy, os, re, sqlite3, time, urllib.parse

APP = "calls"
DB = os.path.expanduser("~/Library/Application Support/CallHistoryDB/CallHistory.storedata")
EPOCH = 978307200
state = {}


def db():
    return sqlite3.connect("file:" + urllib.parse.quote(DB) + "?mode=ro", uri=True)


def digits10(h):
    d = re.sub(r"\D", "", h or "")
    return d[-10:] if len(d) >= 7 else None


def recent():
    out, ms = cli("calls", "recent", "--since", "30d", "--limit", "100000", "--no-names")
    c = out.get("calls", [])
    check(c, err(out) or "no calls in 30 days")
    since = time.time() - 30 * 86400 - EPOCH
    # The CLI parses "30d" a moment before this query runs; allow one call of drift at the edge.
    n = db().execute("SELECT COUNT(*) FROM ZCALLRECORD WHERE ZDATE >= ?", (since,)).fetchone()[0]
    check(abs(len(c) + out.get("hidden", 0) - n) <= 1, f"{len(c)} + {out.get('hidden', 0)} hidden != {n} in the database")
    d = [x["date"] for x in c]
    check(d == sorted(d, reverse=True), "not newest first")
    m, _ = cli("calls", "missed", "--since", "30d", "--limit", "100000", "--no-names")
    nm = db().execute("SELECT COUNT(*) FROM ZCALLRECORD WHERE ZDATE >= ? AND ZORIGINATED = 0 AND ZANSWERED = 0", (since,)).fetchone()[0]
    check(abs(len(m.get("calls", [])) + m.get("hidden", 0) - nm) <= 1, "missed count differs from the database")
    check(all(x["direction"] == "missed" for x in m["calls"]), "missed list has answered calls")
    state["calls"] = c
    return f"{len(c)} calls and {len(m['calls'])} missed in 30 days match the database", ms


def with_number():
    pick = next((x["handle"] for x in state["calls"] if digits10(x.get("handle"))), None)
    check(pick, "no phone number to test with")
    state["number"] = pick
    out, ms = cli("calls", "with", pick, "--limit", "100000")
    want = sum(1 for (a,) in db().execute("SELECT ZADDRESS FROM ZCALLRECORD") if digits10(a) == digits10(pick))
    check(len(out.get("calls", [])) == want, f"{len(out.get('calls', []))} calls with the number, database has {want}")
    return f"all {want} calls with one number found", ms


def privacy():
    cfg = copy.deepcopy(user_config()); cfg.setdefault("calls", {})["excludeHandles"] = [state["number"]]
    out, ms = cli("calls", "recent", "--since", "30d", "--limit", "100000", config=cfg)
    check(all(digits10(x.get("handle")) != digits10(state["number"]) for x in out.get("calls", [])), "excluded number listed")
    check(out.get("hidden", 0) >= 1, "hidden count not reported")
    w, _ = cli("calls", "with", state["number"], config=cfg)
    check((w.get("error") or {}).get("code") == "hidden", "calls with an excluded number not refused")
    return "excluded number gone from recent; calls with it refused", ms


def group_privacy():
    """A group call must hide when any participant, not only the first, is excluded."""
    row = db().execute("""SELECT c.ZUNIQUE_ID, h.ZVALUE FROM ZCALLRECORD c
        JOIN Z_2REMOTEPARTICIPANTHANDLES j ON j.Z_2REMOTEPARTICIPANTCALLS = c.Z_PK
        JOIN ZHANDLE h ON h.Z_PK = j.Z_4REMOTEPARTICIPANTHANDLES
        WHERE h.ZVALUE != c.ZADDRESS ORDER BY c.ZDATE DESC LIMIT 1""").fetchone()
    if not row:
        return "no group calls with extra participants to check", 0
    cid, other = row
    base, _ = cli("calls", "recent", "--since", "3650d", "--limit", "100000", "--no-names")
    if not any(x["id"] == cid for x in base.get("calls", [])):
        return "newest group call already hidden by config", 0
    cfg = copy.deepcopy(user_config()); cfg.setdefault("calls", {})["excludeHandles"] = [other]
    out, ms = cli("calls", "recent", "--since", "3650d", "--limit", "100000", "--no-names", config=cfg)
    check(all(x["id"] != cid for x in out.get("calls", [])), "group call shown although a participant is excluded")
    return "group call hidden when a non-primary participant is excluded", ms


def run():
    if step(APP, "recent and missed match database", recent):
        if step(APP, "calls with one number", with_number):
            step(APP, "privacy: exclude number", privacy)
    step(APP, "privacy: group call participant", group_privacy)
