import sqlite3, sys, collections
def decode(b):
    # NSArchiver typedstream: header "\x04\x0bstreamtyped", then class chain NSMutableAttributedString/NSAttributedString,
    # then NSMutableString/NSString, then '+' (0x2B, C string type) and a length-prefixed UTF-8 payload.
    if not b.startswith(b"\x04\x0bstreamtyped"): return None, "no-header"
    i = b.find(b"NSString")
    if i < 0: return None, "no-NSString"
    j = b.find(b"\x2b", i + 8)   # '+' marks the string value
    if j < 0 or j > i + 20: return None, "no-plus"
    k = j + 1; n = b[k]
    if n < 0x80: ln, k = n, k + 1
    elif n == 0x81: ln, k = int.from_bytes(b[k+1:k+3], "little"), k + 3
    elif n == 0x82: ln, k = int.from_bytes(b[k+1:k+5], "little"), k + 5
    else: return None, f"len-marker-{n:#x}"
    if k + ln > len(b): return None, "overrun"
    try: return b[k:k+ln].decode("utf-8"), "ok"
    except UnicodeDecodeError: return None, "utf8"
c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
st = collections.Counter(); eq = ne = 0; lens = collections.Counter()
for text, ab in c.execute("select text, attributedBody from message where attributedBody is not null"):
    s, why = decode(ab); st[why] += 1
    if s is not None and text is not None:
        if s == text: eq += 1
        else: ne += 1
    if s is not None: lens["<128" if len(s.encode()) < 128 else "<65536" if len(s.encode()) < 65536 else "big"] += 1
print("decode status", dict(st)); print("matches text column", eq, "mismatches", ne); print("utf8 length buckets", dict(lens))
# field-only messages: what decodes
only = [decode(ab)[1] for (ab,) in c.execute("select attributedBody from message where text is null and attributedBody is not null")]
print("attributedBody-only messages", collections.Counter(only))
kinds = collections.Counter()
for text, ab, edited, assoc in c.execute("select text, attributedBody, date_edited>0, associated_message_type from message where attributedBody is not null and text is not null"):
    s, _ = decode(ab)
    if s == text: continue
    if edited: kinds["edited (text holds an older version)"] += 1
    elif s.replace("￼", "") == text.replace("￼", ""): kinds["differs only by U+FFFC attachment marks"] += 1
    elif s.strip() == text.strip(): kinds["whitespace"] += 1
    elif assoc: kinds[f"reaction type {assoc}"] += 1
    elif text in s or s in text: kinds["one contains the other"] += 1
    else: kinds["other"] += 1
print("mismatch kinds", dict(kinds))
