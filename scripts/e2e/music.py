"""Music (read-only): counts and play data against AppleScript's own answers, and the no-launch guard."""
from common import cli, err, step, check, user_config
import copy
import json, subprocess

APP = "music"
state = {}


def running():
    return subprocess.run(["pgrep", "-x", "Music"], capture_output=True).returncode == 0


def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=60).stdout.strip()


def guard():
    """Without --launch, a command must refuse instead of opening Music."""
    state["was_running"] = running()
    if state["was_running"]:
        return "skipped: Music already running, so the no-launch guard cannot be checked", 0
    out, ms = cli("music", "top")
    check((out.get("error") or {}).get("code") == "refused", f"top without --launch returned {out}")
    check(not running(), "Music opened without --launch")
    return "refuses to open Music without --launch", ms


def top():
    out, ms = cli("music", "top", "--limit", "100000", "--launch")
    t = out.get("tracks", [])
    check(t, err(out) or "no tracks")
    n = int(osa('tell application "Music" to count tracks of library playlist 1'))
    check(len(t) == n, f"{len(t)} tracks, AppleScript counts {n}")
    first = t[0]
    pc = int(osa(f'tell application "Music" to get played count of (first track of library playlist 1 whose persistent ID is "{first["id"]}")'))
    check(pc == first["plays"], "top track play count differs from AppleScript")
    check([x["plays"] for x in t] == sorted((x["plays"] for x in t), reverse=True), "top not ranked by plays")
    state["top"] = first
    return f"{len(t)} tracks match AppleScript; top play count agrees", ms


def recent_and_search():
    r, ms = cli("music", "recent", "--limit", "50")
    d = [x["lastPlayed"] for x in r.get("tracks", [])]
    check(d and d == sorted(d, reverse=True), "recent not newest first")
    s, _ = cli("music", "search", state["top"]["name"], "--limit", "500")
    check(any(x["id"] == state["top"]["id"] for x in s.get("tracks", [])), "search missed the top track by name")
    p, _ = cli("music", "playlists")
    n = int(osa('tell application "Music" to count user playlists'))
    check(len(p.get("playlists", [])) == n, "playlist count differs from AppleScript")
    return f"recent newest first; search finds by name; {n} playlists match", ms


def privacy():
    p, _ = cli("music", "playlists")
    pick = next((x for x in p.get("playlists", []) if 0 < x["tracks"] < 500), None)
    if not pick:
        return "no small playlist to test with", 0
    ids = set(json.loads(subprocess.run(["osascript", "-l", "JavaScript", "-e",
        f'JSON.stringify(Application("Music").userPlaylists.byName({json.dumps(pick["name"])}).tracks.persistentID())'],
        capture_output=True, text=True, timeout=60).stdout))
    cfg = copy.deepcopy(user_config()); cfg.setdefault("music", {})["excludePlaylists"] = [pick["name"]]
    out, ms = cli("music", "top", "--limit", "100000", config=cfg)
    check(out.get("tracks") and not ids & {x["id"] for x in out["tracks"]}, "tracks of an excluded playlist still listed")
    pl, _ = cli("music", "playlists", config=cfg)
    check(all(x["name"] != pick["name"] for x in pl.get("playlists", [])), "excluded playlist listed")
    return f"excluded playlist and its {len(ids)} tracks hidden", ms


def close_music():
    """Music was closed before the test, so it must be closed after."""
    import time
    osa('tell application "Music" to quit')
    end = time.time() + 15
    while running() and time.time() < end:
        time.sleep(0.25)
    check(not running(), "Music still open after quit (a dialog may be blocking it)")
    return "Music closed again, as it was before the test", 0


def run():
    step(APP, "no-launch guard", guard)
    if step(APP, "top matches AppleScript", top):
        step(APP, "recent, search, playlists", recent_and_search)
        step(APP, "privacy: exclude playlist", privacy)
    if not state.get("was_running"):
        step(APP, "clean end state", close_music)
