"""Voice Memos (read-only): list against the database, transcripts against an independent atom parser, search, privacy."""
from common import cli, err, step, check, user_config
import copy, json, os, re, sqlite3, struct, urllib.parse

APP = "voicememos"
DIR = os.path.expanduser("~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings")
state = {}


def py_transcript(path):
    """Scans for the tsrp atom by bytes (not by walking boxes, as the CLI does)."""
    b = open(path, "rb").read()
    i = b.find(b"tsrp", b.find(b"moov"))
    if i < 4:
        return None
    size = struct.unpack(">I", b[i - 4:i])[0]
    try:
        j = json.loads(b[i + 4:i - 4 + size])
    except ValueError:
        return None
    return "".join(x for x in j["attributedString"]["runs"] if isinstance(x, str)).strip()


def listing():
    out, ms = cli("voicememos", "list", "--limit", "1000")
    r = out.get("recordings", [])
    check(r or out.get("hidden"), err(out) or "no recordings")
    db = sqlite3.connect("file:" + urllib.parse.quote(DIR + "/CloudRecordings.db") + "?mode=ro", uri=True)
    n = db.execute("SELECT COUNT(*) FROM ZCLOUDRECORDING WHERE ZEVICTIONDATE IS NULL").fetchone()[0]
    check(len(r) + out.get("hidden", 0) == n, f"{len(r)} listed + {out.get('hidden', 0)} hidden != {n} in the database")
    d = [x["date"] for x in r]
    check(d == sorted(d, reverse=True), "not newest first")
    state["recs"] = r
    return f"{len(r)} recordings ({out.get('hidden', 0)} hidden) match the database, newest first", ms


def transcripts():
    compared = 0
    ms_max = 0
    for x in state["recs"]:
        if not x.get("audioPath"):
            continue
        want = py_transcript(x["audioPath"])
        check(bool(want) == x["hasTranscript"], f"hasTranscript disagrees for {x['id']}")
        if not want:
            continue
        r, ms = cli("voicememos", "read", x["id"])
        ms_max = max(ms_max, ms)
        check(r.get("transcript") == want, f"transcript differs for {x['id']}")
        check(re.sub(r"\s+", "", "".join(s["text"] for s in r["segments"])) == re.sub(r"\s+", "", want), "segments do not add up to the transcript")
        starts = [s["start"] for s in r["segments"]]
        check(starts == sorted(starts), "segment times out of order")
        compared += 1
        state.setdefault("with_transcript", x)
        state.setdefault("word", max(re.findall(r"[A-Za-z]{6,}", want) or [""], key=len))
    if compared == 0:
        return "no transcripts on this Mac to compare", 0
    return f"{compared} transcripts match an independent parser", ms_max


def search():
    if not state.get("word"):
        return "no transcript to search", 0
    out, ms = cli("voicememos", "search", state["word"])
    check(any(x["id"] == state["with_transcript"]["id"] for x in out.get("recordings", [])), "search missed a transcript word")
    return "search finds a recording by a word in its transcript", ms


def privacy():
    x = state.get("with_transcript") or state["recs"][0]
    cfg = copy.deepcopy(user_config()); cfg.setdefault("voicememos", {})["excludeTitlePatterns"] = ["^" + re.escape(x["title"]) + "$"]
    out, ms = cli("voicememos", "list", "--limit", "1000", config=cfg)
    check(all(r["title"] != x["title"] for r in out.get("recordings", [])), "excluded title listed")
    r, _ = cli("voicememos", "read", x["id"], config=cfg)
    check((r.get("error") or {}).get("code") == "hidden", "read of an excluded recording not hidden")
    if state.get("word"):
        s, _ = cli("voicememos", "search", state["word"], config=cfg)
        check(all(r["id"] != x["id"] for r in s.get("recordings", [])), "excluded recording found by search")
    return "excluded recording gone from list, read, and search", ms


def run():
    if step(APP, "list matches database", listing):
        step(APP, "transcripts match", transcripts)
        step(APP, "search transcripts", search)
        step(APP, "privacy: exclude title", privacy)
