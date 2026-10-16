"""Contacts: create, search by name and email, read, update, CardDAV sync, delete."""
from common import TOKEN, SYNC_TIMEOUT, cli, err, step, check, poll
import time

APP = "contacts"
state = {}
EMAIL = f"{TOKEN}@example.com"


def create():
    out, ms = cli("contacts", "create", "--first", "Applecli", "--last", TOKEN, "--email", f"work={EMAIL}",
                  "--phone", "mobile=+1 555 010 4477", "--birthday", "1990-04-12")
    check(not err(out), err(out))
    check(out.get("created") and out.get("id"), f"no id returned: {out}")
    state["id"] = out["id"]
    return f"id {out['id']}", ms


def search_name():
    out, ms = cli("contacts", "search", TOKEN)
    ids = [c["id"] for c in out.get("contacts", [])]
    check(state["id"] in ids, f"name search returned {ids}")
    return f"found by name in {len(ids)} result(s)", ms


def search_email():
    out, ms = cli("contacts", "search", EMAIL)
    ids = [c["id"] for c in out.get("contacts", [])]
    check(state["id"] in ids, f"email search returned {ids}")
    return "found by email", ms


def read():
    out, ms = cli("contacts", "read", state["id"])
    check(out.get("familyName") == TOKEN, f"family name {out.get('familyName')}")
    check(any(e["value"] == EMAIL and e["label"] == "work" for e in out.get("emails", [])), f"emails {out.get('emails')}")
    check(out.get("phones") and out["phones"][0]["label"] == "mobile", f"phones {out.get('phones')}")
    check(out.get("birthday") == "1990-04-12", f"birthday {out.get('birthday')}")
    return "name, labeled email, labeled phone, birthday round-trip", ms


def update():
    out, ms = cli("contacts", "update", state["id"], "--org", f"Org {TOKEN}", "--add-phone", "home=+1 555 010 9911")
    check(out.get("updated"), err(out))
    back, _ = cli("contacts", "read", state["id"])
    check(back.get("organization") == f"Org {TOKEN}", "organization not updated")
    check(len(back.get("phones", [])) == 2, f"phones after update {back.get('phones')}")
    return "organization set, phone added, original phone kept", ms


def synced():
    t = time.time()
    hit = poll(lambda: cli("contacts", "read", state["id"])[0].get("synced") is True, SYNC_TIMEOUT)
    check(hit, f"no CardDAV ETag after {SYNC_TIMEOUT}s")
    return f"iCloud (CardDAV) accepted the card after {time.time() - t:.1f}s", None


def delete():
    out, ms = cli("contacts", "delete", state["id"])
    check(out.get("deleted"), err(out))
    back, _ = cli("contacts", "read", state["id"])
    check((back.get("error") or {}).get("code") == "not_found", f"read after delete returned {back}")
    return "read now returns not_found", ms


def run():
    if step(APP, "create", create):
        step(APP, "search by name", search_name)
        step(APP, "search by email", search_email)
        step(APP, "read", read)
        step(APP, "update", update)
        step(APP, "reached iCloud", synced)
        step(APP, "delete", delete)
