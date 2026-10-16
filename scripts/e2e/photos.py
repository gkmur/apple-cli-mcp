"""Photos: counts match Photos.app, ordering, privacy (Hidden and Recently Deleted never appear), albums,
and, when PhotoKit access is already granted, one small download. Delete is never tested: it needs a
person to confirm Apple's dialog."""
from common import cli, err, step, check, user_config
import copy, os, sqlite3, subprocess, tempfile, shutil

APP = "photos"
state = {}
DB = os.path.expanduser("~/Pictures/Photos.photoslibrary/database/Photos.sqlite")


def stats():
    out, ms = cli("photos", "stats")
    check(not err(out), err(out))
    p = subprocess.run(["osascript", "-e", 'tell application "Photos" to count media items'], capture_output=True, text=True, timeout=120)
    app = int(p.stdout.strip())
    check(out["items"] == app, f"apple-cli counts {out['items']}, Photos.app counts {app}")
    check(out["photos"] + out["videos"] <= out["items"], "photos + videos exceed items")
    return f"{out['items']} items, equal to Photos.app's own count", ms


def ordering():
    top, ms = cli("photos", "top", "--limit", "20")
    b = [x["bytes"] for x in top["items"]]
    check(b == sorted(b, reverse=True), "top not largest first")
    v, _ = cli("photos", "videos", "--limit", "20")
    check(all(x["kind"] == "video" and x.get("duration") is not None for x in v["items"]), "videos list has non-videos or no durations")
    l, _ = cli("photos", "list", "--limit", "50")
    d = [x["date"] for x in l["items"]]
    check(d == sorted(d, reverse=True), "list not newest first")
    s, _ = cli("photos", "storage")
    st, _ = cli("photos", "stats")
    check(s["total"] == st["bytes"], "storage total differs from stats bytes")
    return "top, videos, list ordered; storage total equals stats", ms


def privacy():
    db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    hidden = [r[0] for r in db.execute("SELECT ZUUID FROM ZASSET WHERE ZHIDDEN = 1 AND ZTRASHEDSTATE = 0 LIMIT 3")]
    trashed = [r[0] for r in db.execute("SELECT ZUUID FROM ZASSET WHERE ZTRASHEDSTATE = 1 LIMIT 3")]
    out, ms = cli("photos", "list", "--limit", "100000")
    seen = {x["id"] for x in out["items"]}
    check(not (seen & set(hidden + trashed)), "a Hidden or Recently Deleted item appeared in list")
    for i in (hidden + trashed)[:2]:
        r, _ = cli("photos", "download", i, "--to", tempfile.gettempdir())
        check((r.get("error") or {}).get("code") == "not_found", f"download of a hidden item returned {r.get('error')}")
    albums, _ = cli("photos", "albums")
    a = next((x for x in albums["albums"] if x["items"] > 0), None)
    check(a, "no album with items")
    cfg = copy.deepcopy(user_config()); cfg.setdefault("photos", {})["excludeAlbums"] = [a["name"]]
    inside, _ = cli("photos", "list", "--album", a["name"], "--limit", "5")
    ex, _ = cli("photos", "list", "--limit", "100000", config=cfg)
    check(not ({x["id"] for x in inside["items"]} & {x["id"] for x in ex["items"]}), "excluded album's items still listed")
    return f"{len(hidden)} hidden and {len(trashed)} deleted samples never shown; excluding an album removes its items", ms


def download():
    st, _ = cli("doctor")
    pk = next(c for c in st["checks"] if c["domain"] == "photos" and c["name"] == "photokit")
    if "full access granted" not in pk["detail"]:
        return "skipped: PhotoKit access not granted yet (would prompt you); run `apple-cli photos download` once to grant it", None
    small = cli("photos", "list", "--kind", "photo", "--limit", "200")[0]["items"]
    item = min((x for x in small if x.get("bytes")), key=lambda x: x["bytes"])
    d = tempfile.mkdtemp(prefix="apple-cli-e2e-")
    try:
        out, ms = cli("photos", "download", item["id"], "--to", d)
        check(out.get("saved"), err(out) or f"nothing saved: {out}")
        check(os.path.getsize(os.path.join(d, out["saved"][0])) > 0, "downloaded file is empty")
        return f"downloaded one {item['bytes']} byte original", ms
    finally:
        shutil.rmtree(d, ignore_errors=True)


def run():
    if step(APP, "stats match Photos.app", stats):
        step(APP, "ordering and totals", ordering)
        step(APP, "privacy: hidden, deleted, excluded album", privacy)
        step(APP, "download one original", download)
