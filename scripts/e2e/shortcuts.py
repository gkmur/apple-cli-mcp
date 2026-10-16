"""Shortcuts: list against Apple's shortcuts tool, actions against the store, privacy, and run (only a shortcut made for the test)."""
from common import cli, err, step, check, user_config
import copy, os, plistlib, re, sqlite3, subprocess

APP = "shortcuts"
TEST_NAME = "apple-cli e2e"   # optional: a shortcut that returns its input as text
state = {}


def listing():
    out, ms = cli("shortcuts", "list")
    s = out.get("shortcuts", [])
    check(s or out.get("hidden"), err(out) or "no shortcuts")
    apple = set(subprocess.run(["/usr/bin/shortcuts", "list"], capture_output=True, text=True, timeout=30).stdout.splitlines())
    check({x["name"] for x in s} == apple, "names differ from Apple's shortcuts list")
    state["all"] = s
    return f"{len(s)} shortcuts match Apple's shortcuts list", ms


def actions():
    db = sqlite3.connect("file:" + os.path.expanduser("~/Library/Shortcuts/Shortcuts.sqlite") + "?mode=ro", uri=True)
    ms_max = 0
    for x in state["all"]:
        r, ms = cli("shortcuts", "read", x["id"])
        ms_max = max(ms_max, ms)
        data = db.execute("""SELECT a.ZDATA FROM ZSHORTCUTACTIONS a JOIN ZSHORTCUT s ON s.Z_PK = a.ZSHORTCUT
            WHERE s.ZWORKFLOWID = ?""", (x["id"],)).fetchone()
        want = [a.get("WFWorkflowActionIdentifier", "unknown").removeprefix("is.workflow.actions.") for a in plistlib.loads(data[0])] if data else []
        check(r.get("steps") == want, f"steps differ for {x['id']}")
        check(len(want) == x["actions"], f"action count differs for {x['id']}")
    return f"actions of all {len(state['all'])} shortcuts match the store", ms_max


def privacy():
    x = state["all"][0]
    cfg = copy.deepcopy(user_config()); cfg.setdefault("shortcuts", {})["excludeNamePatterns"] = ["^" + re.escape(x["name"]) + "$"]
    out, ms = cli("shortcuts", "list", config=cfg)
    check(all(s["id"] != x["id"] for s in out.get("shortcuts", [])), "excluded shortcut listed")
    for cmd in ("read", "run"):
        r, _ = cli("shortcuts", cmd, x["name"], config=cfg)
        check((r.get("error") or {}).get("code") == "hidden", f"{cmd} of an excluded shortcut not refused")
    return "excluded shortcut gone from list; read and run refused before running", ms


def run_test():
    if not any(x["name"] == TEST_NAME for x in state["all"]):
        return f"skipped: no shortcut named '{TEST_NAME}' (make one that returns its input to test run)", 0
    r, ms = cli("shortcuts", "run", TEST_NAME, "--input", "ping-e2e")
    check(r.get("output") == "ping-e2e", f"run returned {r}")
    return "run passed input through and returned the output", ms


def run():
    if step(APP, "list matches Apple's tool", listing):
        step(APP, "actions match the store", actions)
        step(APP, "privacy: exclude name", privacy)
        step(APP, "run", run_test)
