"""Messages (read-only): chats, read, search, attributedBody-only text, unread, stats, privacy.

No message is sent. Details in the report hold counts and IDs only, never message text."""
from common import cli, err, step, check, user_config
import copy, os, re, sqlite3, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "docs", "evidence"))

APP = "messages"
state = {}
DB = os.path.expanduser("~/Library/Messages/chat.db")


def decode(b):
    """Independent Python decoder (docs/evidence/attributedbody_check.py), used to cross-check the Swift one."""
    if not b or not b.startswith(b"\x04\x0bstreamtyped"):
        return None
    i = b.find(b"NSString"); j = b.find(b"\x2b", i + 8)
    if i < 0 or j < 0:
        return None
    k = j + 1; n = b[k]
    if n < 0x80: ln, k = n, k + 1
    elif n == 0x81: ln, k = int.from_bytes(b[k+1:k+3], "little"), k + 3
    elif n == 0x82: ln, k = int.from_bytes(b[k+1:k+5], "little"), k + 5
    else: return None
    return b[k:k+ln].decode("utf-8", "replace")


OTP = re.compile(r"(?i)code\D{0,25}\b\d{4,8}\b|\b\d{4,8}\b\D{0,30}\b(is your|code)\b")


def chats():
    out, ms = cli("messages", "chats", "--limit", "200")
    check(not err(out), err(out))
    c = out["chats"]
    check(c, "no chats")
    named = [x for x in c if any(p and not re.fullmatch(r"[+\d\s()@.\w-]*@?[\w.]*", p) or any(ch.isalpha() for ch in p) and "@" not in p for p in x["participants"])]
    check(named, "no participant resolved to a contact name")
    state["top"] = c[0]["id"]
    state["chat_ids"] = [x["id"] for x in c[:15]]
    state["one_to_one"] = next((x for x in c if not x["group"]), None)
    return f"{len(c)} chats, {len(named)} with contact names, {out['hidden']} hidden", ms


def read():
    out, ms = cli("messages", "read", state["top"], "--limit", "40")
    m = out.get("messages", [])
    check(m, err(out) or "no messages")
    dates = [x["date"] for x in m if x.get("date")]
    check(dates == sorted(dates), "messages not in time order")
    # The search word comes from the first recent chat that has one (a chat of short texts may not).
    for cid in state["chat_ids"]:
        msgs = m if cid == state["top"] else cli("messages", "read", cid, "--limit", "40")[0].get("messages", [])
        words = [w for x in msgs if x.get("text") and x["text"] != "[one-time code hidden]" and not OTP.search(x["text"])
                 for w in re.findall(r"[A-Za-z]{7,}", x["text"])]
        if words:
            state["word"], state["word_chat"] = words[-1], cid
            break
    check(state.get("word"), "no searchable word in the 15 most recent chats")
    return f"{len(m)} messages in time order", ms


def search():
    out, ms = cli("messages", "search", state["word"], "--chat", state["word_chat"], "--limit", "50")
    r = out.get("results", [])
    check(r and all(state["word"].lower() in (x.get("text") or "").lower() for x in r), err(out) or "search missed or returned non-matches")
    dates = [x["date"] for x in r]
    check(dates == sorted(dates, reverse=True), "results not newest first")
    return f"{len(r)} hit(s) for a word taken from the chat, newest first", ms


def body_only():
    # Find a message that has no plain text, only attributedBody, in a chat the CLI shows.
    visible = {c["id"] for c in cli("messages", "chats", "--limit", "1000")[0]["chats"]}
    db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    rows = db.execute("""SELECT m.guid, c.guid FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID
                         JOIN chat c ON c.ROWID = j.chat_id
                         WHERE m.text IS NULL AND m.attributedBody IS NOT NULL AND m.associated_message_type = 0
                           AND m.item_type = 0 ORDER BY m.date DESC""").fetchall()
    # Pick one whose text, decoded independently here, has real words (not only an attachment mark).
    db_rows = {g: ab for g, ab in db.execute("""SELECT guid, attributedBody FROM message
                                                WHERE text IS NULL AND attributedBody IS NOT NULL""")}
    target = next(((g, c) for g, c in rows if c in visible
                   and re.search(r"\w", (decode(db_rows.get(g, b"")) or "").replace("\ufffc", ""))), None)
    check(target, "no attributedBody-only message with text in a visible chat")
    out, ms = cli("messages", "read", target[1], "--all")
    hit = next((x for x in out.get("messages", []) if x["id"] == target[0]), None)
    check(hit and hit.get("text"), "attributedBody-only message came back with no text")
    want = decode(db_rows[target[0]]).replace("\ufffc", "").strip()
    check(hit["text"] in (want, "[one-time code hidden]"), "Swift and Python decoders disagree")
    doc, _ = cli("doctor")
    dec = next(c for c in doc["checks"] if c["domain"] == "messages" and c["name"] == "decoder")
    check(dec["ok"], dec["detail"])
    return f"message {target[0][:12]}… decoded; doctor: {dec['detail']}", ms


def otp():
    out, ms = cli("messages", "search", "code", "--limit", "500")
    leaked = [x["id"] for x in out.get("results", []) if OTP.search(x.get("text") or "")]
    check(not leaked, f"{len(leaked)} one-time-code-like messages returned")
    return f"{len(out.get('results', []))} results for 'code', none look like a one-time code", ms


def unread_stats():
    u, ms = cli("messages", "unread")
    check(not err(u), err(u))
    s, _ = cli("messages", "stats")
    check(s.get("messages", 0) > 0 and s["sent"] + s["received"] == s["messages"], "stats do not add up")
    return f"{sum(len(c['messages']) for c in u['chats'])} unread in {len(u['chats'])} chats; {s['messages']} messages in stats", ms


def hide_chat():
    cfg = copy.deepcopy(user_config())
    cfg.setdefault("messages", {})["excludeChats"] = [state["top"]]
    c, ms = cli("messages", "chats", "--limit", "1000", config=cfg)
    check(all(x["id"] != state["top"] for x in c["chats"]), "excluded chat still listed")
    r, _ = cli("messages", "read", state["top"], config=cfg)
    check((r.get("error") or {}).get("code") == "not_found", f"read of excluded chat returned {r.get('error')}")
    s, _ = cli("messages", "search", state["word"], "--limit", "500", config=cfg)
    check(all(x["chatId"] != state["top"] for x in s.get("results", [])), "search returned messages from the excluded chat")
    return "excluded chat gone from chats, read (not_found), and search", ms


def hide_handle():
    o2o = state["one_to_one"]
    check(o2o, "no one-to-one chat to test with")
    out, _ = cli("messages", "chats", "--limit", "1000", "--no-names")
    raw = next(x for x in out["chats"] if x["id"] == o2o["id"])["participants"][0]
    cfg = copy.deepcopy(user_config())
    cfg.setdefault("messages", {})["excludeHandles"] = [raw]
    c, ms = cli("messages", "chats", "--limit", "1000", config=cfg)
    check(all(x["id"] != o2o["id"] for x in c["chats"]), "chat with excluded handle still listed")
    return "chat with an excluded phone or email is hidden", ms


def hide_group_sender():
    # Excluding someone who sent messages in a group must hide the whole group,
    # whether or not they are still a participant.
    visible = {c["id"] for c in cli("messages", "chats", "--limit", "1000")[0]["chats"] if c["group"]}
    db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    row = next(((c, h) for c, h in db.execute("""SELECT DISTINCT c.guid, h.id FROM chat c
                  JOIN chat_message_join j ON j.chat_id = c.ROWID JOIN message m ON m.ROWID = j.message_id
                  JOIN handle h ON h.ROWID = m.handle_id WHERE c.style = 43""") if c in visible), None)
    check(row, "no group chat with an incoming sender to test with")
    cfg = copy.deepcopy(user_config())
    cfg.setdefault("messages", {})["excludeHandles"] = [row[1]]
    c, ms = cli("messages", "chats", "--limit", "1000", config=cfg)
    check(all(x["id"] != row[0] for x in c["chats"]), "group with an excluded sender still listed")
    s, _ = cli("messages", "search", "the", "--limit", "500", config=cfg)
    check(all(x["chatId"] != row[0] for x in s.get("results", [])), "search returned messages from that group")
    return "excluding a group sender hides the group from chats and search", ms


def hide_contact():
    # A contact hidden in Contacts settings must vanish from Messages too.
    out, _ = cli("messages", "chats", "--limit", "1000", "--no-names")
    named, _ = cli("messages", "chats", "--limit", "1000")
    names = {x["id"]: x for x in named["chats"]}
    for x in out["chats"]:
        if x["group"] or not x["participants"]:
            continue
        handle = x["participants"][0]
        if names.get(x["id"], {}).get("name") in (None, handle):
            continue  # not a saved contact
        hits, _ = cli("contacts", "search", handle)
        if not hits.get("contacts"):
            continue
        cfg = copy.deepcopy(user_config())
        cfg.setdefault("contacts", {})["excludeContactIDs"] = [hits["contacts"][0]["id"]]
        c, ms = cli("messages", "chats", "--limit", "1000", config=cfg)
        check(all(y["id"] != x["id"] for y in c["chats"]), "chat with a hidden contact still listed")
        return "hiding a contact in Contacts settings hides their chat in Messages", ms
    raise AssertionError("no one-to-one chat with a saved contact to test with")


def run():
    if step(APP, "chats", chats):
        if step(APP, "read", read):
            step(APP, "search", search)
            step(APP, "privacy: exclude chat", hide_chat)
        step(APP, "attributedBody-only text", body_only)
        step(APP, "one-time codes masked", otp)
        step(APP, "unread and stats", unread_stats)
        step(APP, "privacy: exclude handle", hide_handle)
        step(APP, "privacy: hidden contact", hide_contact)
        step(APP, "privacy: group sender", hide_group_sender)
