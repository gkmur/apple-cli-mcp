"""Safari (read-only): history order, domains, visited, bookmarks and iCloud tabs counts, privacy."""
from common import cli, err, step, check, user_config
import copy, os, plistlib, re, sqlite3

APP = "safari"
state = {}


def history():
    out, ms = cli("safari", "history", "--since", "30d", "--limit", "500")
    v = out.get("visits", [])
    check(v, err(out) or "no visits in 30 days")
    t = [x["time"] for x in v]
    check(t == sorted(t, reverse=True), "history not newest first")
    return f"{len(v)} visits in 30 days, newest first", ms


def domains():
    out, ms = cli("safari", "domains", "--since", "30d")
    d = out.get("domains", [])
    check(d, "no domains")
    c = [x["visits"] for x in d]
    check(c == sorted(c, reverse=True), "domains not ranked by visits")
    state["top"] = d[0]["domain"]
    vis, _ = cli("safari", "visited", state["top"])
    check(vis.get("visited") and vis["visits"] >= d[0]["visits"], "visited disagrees with domains")
    return f"{len(d)} domains ranked; visited agrees for the top one", ms


def counts():
    b, ms = cli("safari", "bookmarks")
    root = plistlib.load(open(os.path.expanduser("~/Library/Safari/Bookmarks.plist"), "rb"))
    def leaves(n):
        return (1 if n.get("WebBookmarkType") == "WebBookmarkTypeLeaf" else 0) + sum(leaves(c) for c in n.get("Children", []))
    check(len(b.get("bookmarks", [])) == leaves(root), "bookmark count differs from Bookmarks.plist")
    t, _ = cli("safari", "tabs")
    db = sqlite3.connect("file:" + os.path.expanduser("~/Library/Containers/com.apple.Safari/Data/Library/Safari/CloudTabs.db") + "?mode=ro", uri=True)
    check(len(t.get("tabs", [])) == db.execute("SELECT COUNT(*) FROM cloud_tabs").fetchone()[0], "tab count differs from CloudTabs.db")
    return f"{len(b['bookmarks'])} bookmarks and {len(t['tabs'])} iCloud tabs match the files", ms


def privacy():
    cfg = copy.deepcopy(user_config()); cfg.setdefault("safari", {})["excludeDomains"] = [state["top"]]
    h, ms = cli("safari", "history", "--since", "30d", "--limit", "5000", config=cfg)
    check(all(not (x["domain"] == state["top"] or x["domain"].endswith("." + state["top"])) for x in h.get("visits", [])), "excluded domain in history")
    d, _ = cli("safari", "domains", "--since", "30d", "--limit", "500", config=cfg)
    check(all(x["domain"] != state["top"] for x in d.get("domains", [])), "excluded domain ranked")
    v, _ = cli("safari", "visited", state["top"], config=cfg)
    check((v.get("error") or {}).get("code") == "hidden", f"visited on excluded domain returned {v}")
    return "excluded domain gone from history, domains, visited", ms


def privacy_title():
    h, _ = cli("safari", "history", "--since", "30d", "--limit", "500")
    pick = next((x for x in h.get("visits", []) if x.get("title") and len(x["title"]) > 8), None)
    check(pick, "no titled visit to test with")
    before, _ = cli("safari", "visited", pick["url"])
    check(before.get("visited"), "picked page not visited before exclusion")
    cfg = copy.deepcopy(user_config()); cfg.setdefault("safari", {})["excludePatterns"] = [re.escape(pick["title"])]
    after, ms = cli("safari", "visited", pick["url"], config=cfg)
    check(not after.get("visited"), "page with an excluded title still counted by visited")
    d, _ = cli("safari", "domains", "--since", "30d", "--limit", "500", config=cfg)
    d0, _ = cli("safari", "domains", "--since", "30d", "--limit", "500")
    n = lambda out: sum(x["visits"] for x in out.get("domains", []))
    check(n(d) < n(d0), "domains still counts visits to the page with an excluded title")
    return "page with an excluded title gone from visited and domains", ms


def run():
    step(APP, "history", history)
    if step(APP, "domains and visited", domains):
        step(APP, "privacy: exclude domain", privacy)
    step(APP, "privacy: exclude title", privacy_title)
    step(APP, "bookmarks and tabs match files", counts)
