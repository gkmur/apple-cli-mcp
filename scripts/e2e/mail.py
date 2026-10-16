"""Mail (read-only): counts and order against the index, bodies against Python's own MIME parser, search, privacy."""
from common import cli, err, step, check, user_config
import copy, email, email.policy, glob, html, os, re, sqlite3

APP = "mail"
DB = os.path.expanduser("~/Library/Mail/V10/MailData/Envelope Index")
state = {}


def db():
    return sqlite3.connect("file:" + DB.replace(" ", "%20") + "?mode=ro", uri=True)


def norm(s):
    return re.sub(r"\s+", " ", s or "").strip().lower()


def listing():
    out, ms = cli("mail", "list", "--limit", "200")
    m = out.get("messages", [])
    check(m, err(out) or "no messages")
    d = [x["date"] for x in m]
    check(d == sorted(d, reverse=True), "list not newest first")
    newest = db().execute("SELECT MAX(date_received) FROM messages WHERE deleted = 0").fetchone()[0]
    check(out.get("indexedThrough"), "no indexedThrough")
    state["msgs"] = m
    mb, _ = cli("mail", "mailboxes")
    total = db().execute("SELECT SUM(total_count) FROM mailboxes WHERE total_count > 0").fetchone()[0]
    check(sum(x["messages"] for x in mb.get("mailboxes", [])) == total, "mailbox totals differ from the index")
    return f"{len(m)} messages newest first; {len(mb['mailboxes'])} mailboxes match the index; newest {newest}", ms


def python_plain(path):
    raw = open(path, "rb").read()
    n = int(raw.split(b"\n", 1)[0])
    msg = email.message_from_bytes(raw.split(b"\n", 1)[1][:n], policy=email.policy.default)
    part = msg.get_body(preferencelist=("plain",))
    if part is None:
        return None
    try:
        t = part.get_content()
    except Exception:
        return None
    return None if re.search(r"(?i)<(html|body|div|table|p|br)\b", t) else t


def bodies():
    """Our plain-text body must contain Python's text/plain body (whitespace-normalized)."""
    root = os.path.expanduser("~/Library/Mail/V10")
    compared = agree = 0
    ms_total = 0
    for x in state["msgs"][:60]:
        hits = glob.glob(f"{root}/*/**/{x['id']}.emlx", recursive=True) + glob.glob(f"{root}/*/**/{x['id']}.partial.emlx", recursive=True)
        if not hits:
            continue
        want = python_plain(hits[0])
        if not want or len(norm(want)) < 20:
            continue
        r, ms = cli("mail", "read", x["id"], "--max-chars", "200000")
        ms_total = max(ms_total, ms)
        if r.get("body") == "[one-time code hidden]":
            continue
        compared += 1
        got = norm(r.get("body"))
        agree += norm(want)[:200] in got
        if compared >= 20:
            break
    check(compared >= 5, f"only {compared} plain-text messages to compare")
    check(agree == compared, f"body differs from Python's parser on {compared - agree} of {compared}")
    return f"{agree}/{compared} bodies match Python's MIME parser", ms_total


def search():
    pick = next((x for x in state["msgs"] if len(x["subject"]) > 12 and x.get("preview") != "[one-time code hidden]"), None)
    check(pick, "no subject to search")
    word = max(re.findall(r"[A-Za-z]{5,}", pick["subject"]) or [pick["subject"][:8]], key=len)
    out, ms = cli("mail", "search", word, "--limit", "500")
    check(any(x["id"] == pick["id"] for x in out.get("messages", [])), "search missed a message whose subject has the word")
    return f"search found the message by a subject word ({len(out['messages'])} hits)", ms


def privacy():
    top = next(x for x in state["msgs"] if x.get("fromAddress"))
    cfg = copy.deepcopy(user_config()); cfg.setdefault("mail", {})["excludeAddresses"] = [top["fromAddress"]]
    out, ms = cli("mail", "list", "--limit", "200", config=cfg)
    check(all((x.get("fromAddress") or "").lower() != top["fromAddress"].lower() for x in out.get("messages", [])), "excluded sender listed")
    r, _ = cli("mail", "read", top["id"], config=cfg)
    check((r.get("error") or {}).get("code") == "hidden", "read of an excluded sender's message not hidden")
    dom = top["fromAddress"].split("@")[-1]
    cfg["mail"]["excludeAddresses"] = [dom]
    s, _ = cli("mail", "search", dom, "--limit", "500", config=cfg)
    check(all(not (x.get("fromAddress") or "").lower().endswith(dom.lower()) for x in s.get("messages", [])), "excluded domain in search")

    cfg = copy.deepcopy(user_config()); cfg.setdefault("mail", {})["excludeSubjectPatterns"] = [re.escape(top["subject"])]
    out, _ = cli("mail", "list", "--limit", "200", config=cfg)
    check(all(x["id"] != top["id"] for x in out.get("messages", [])), "excluded subject listed")

    box = top["mailbox"]
    cfg = copy.deepcopy(user_config()); cfg.setdefault("mail", {})["excludeMailboxes"] = [box]
    out, _ = cli("mail", "list", "--limit", "200", config=cfg)
    check(all(x["mailbox"] != box for x in out.get("messages", [])), "excluded mailbox listed")
    mb, _ = cli("mail", "list", "--mailbox", box, config=cfg)
    check((mb.get("error") or {}).get("code") == "hidden", "listing an excluded mailbox not refused")
    return "sender, domain, subject, and mailbox exclusions hide everywhere", ms


def codes():
    rows = db().execute("""SELECT m.ROWID, s.subject FROM messages m JOIN subjects s ON s.ROWID = m.subject
        WHERE m.deleted = 0 AND (s.subject LIKE '%verification code%' OR s.subject LIKE '%password reset%'
        OR s.subject LIKE '%reset your password%' OR s.subject LIKE '%security code%') ORDER BY m.date_received DESC LIMIT 5""").fetchall()
    if not rows:
        return "no one-time code emails in the index to check", 0
    rid, subj = rows[0]
    r, ms = cli("mail", "read", str(rid))
    if (r.get("error") or {}).get("code") == "hidden":
        return "newest code email is hidden by privacy config", ms
    check(r.get("body") in (None, "[one-time code hidden]") and r.get("preview") == "[one-time code hidden]" and r.get("subject") == "[one-time code hidden]", "one-time code email readable")
    word = max(re.findall(r"[A-Za-z]{5,}", subj), key=len)
    s, _ = cli("mail", "search", word, "--limit", "500")
    check(all(x["id"] != str(rid) for x in s.get("messages", [])), "one-time code email in search")
    return f"{len(rows)} code emails found; newest masked on read and left out of search", ms


def run():
    if step(APP, "list and mailboxes", listing):
        step(APP, "bodies match Python's parser", bodies)
        step(APP, "search by subject", search)
        step(APP, "privacy: sender, domain, subject, mailbox", privacy)
    step(APP, "one-time codes masked", codes)
