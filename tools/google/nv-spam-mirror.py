#!/usr/bin/python3 -I
# nv-spam-mirror: keep a "Google Spam" folder on the server in step with the Spam folders of the Google accounts,
# and turn local moves into Google actions. Runs every 5 minutes from a systemd timer. Design: google/README.md
#
#   new spam at Google                 -> copied into "Google Spam" (unread), once per Message-ID across accounts
#   Google drops it (30-day expiry)    -> removed from "Google Spam"
#   you move it out of "Google Spam" -> rescue: moved out of Spam at Google too (= "Not spam"); stays where you put it
#     ...into Trash / Junk Mail, or deletes it -> confirmed spam: nothing at Google, never mirrored again
#   rescued directly in Gmail          -> the server's copy moved to Inbox (the pull would otherwise skip it as already present)
#
# The only change ever made at Google: UID MOVE from Spam to INBOX, for messages you rescued on the server.
# usage: nv-spam-mirror [--dry]     (--dry: report what would happen, change nothing anywhere)
import sys, os, json, re, sqlite3, imaplib, datetime, email, email.policy, urllib.request

sys.path.insert(0, "/usr/local/lib/nv"); sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))  # repo copy last
from nvlib import jmap, upload, mid, message_ids, gmail_folders, site, ADMIN  # noqa: E402
SITE = site()   # installed by recipe/09-ops.sh
GROUPS = {}   # target Stalwart account -> Google sources feeding its "Google Spam" folder (google.sources[] in site.json)
for s in SITE["google"]["sources"]:
    if s.get("spam_mirror", True) and s.get("enabled", True):
        GROUPS.setdefault(s["account"], {})[s["name"]] = s["user"]
FOLDER = "Google Spam"
STATE = "/var/lib/nv-fetch/state.db"
DRY = "--dry" in sys.argv
now = lambda: datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")

def say(*a): print(("DRY " if DRY else "") + " ".join(map(str, a)), flush=True)

def mid_of(raw):
    m = email.message_from_bytes(raw, policy=email.policy.compat32)
    return mid(m.get("Message-ID"))

class Google:
    def __init__(self, src, user):
        self.src, self.user = src, user
        self.m = imaplib.IMAP4_SSL("imap.gmail.com", 993, timeout=120)
        self.m.login(user, open(f"/root/.secrets/fetch/{src}.pw").read().strip())
        self.box = gmail_folders(self.m)
        if "\\Junk" not in self.box: raise RuntimeError(f"{src}: no \\Junk (Spam) mailbox visible over IMAP")

    def spam(self):
        """{key: uid} of everything in Google's Spam right now."""
        # Every IMAP answer is checked: an empty result from a Google error would otherwise read as "Google dropped
        # all spam" and remove every mirrored copy.
        typ, _ = self.m.select(self.box["\\Junk"], readonly=True)
        if typ != "OK": raise RuntimeError(f"{self.src}: cannot open Spam ({typ})")
        typ, d = self.m.uid("SEARCH", "ALL")
        if typ != "OK": raise RuntimeError(f"{self.src}: Spam search failed ({typ}: {d})")
        uids = d[0].split() if d and d[0] else []
        out = {}
        for i in range(0, len(uids), 200):
            typ, d = self.m.uid("FETCH", b",".join(uids[i:i+200]).decode(), "(X-GM-MSGID BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
            if typ != "OK": raise RuntimeError(f"{self.src}: Spam fetch failed ({typ})")
            for p in d:
                if not isinstance(p, tuple): continue
                uid = int(re.search(rb"UID (\d+)", p[0]).group(1)); gm = re.search(rb"X-GM-MSGID (\d+)", p[0]).group(1).decode()
                out[mid_of(p[1]) or f"gm:{gm}"] = uid
        return out

    def body(self, uid):
        self.m.select(self.box["\\Junk"], readonly=True)
        typ, d = self.m.uid("FETCH", str(uid), "(INTERNALDATE BODY.PEEK[])")
        raw = next(p[1] for p in d if isinstance(p, tuple))
        idt = re.search(rb'INTERNALDATE "([^"]+)"', next(p[0] for p in d if isinstance(p, tuple)))
        when = datetime.datetime.strptime(idt.group(1).decode(), "%d-%b-%Y %H:%M:%S %z").astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if idt else None
        return raw, when

    def not_spam(self, uid):
        """Rescued on the server: move it out of Spam into INBOX (Gmail's 'Not spam')."""
        self.m.select(self.box["\\Junk"], readonly=False)
        typ, d = self.m.uid("MOVE", str(uid), "INBOX")
        if typ != "OK": raise RuntimeError(f"{self.src}: MOVE uid {uid} failed: {d}")

    def kept_outside_spam(self, key):
        """Still at Google outside Spam/Trash? (i.e. rescued directly in Gmail)"""
        typ, _ = self.m.select(self.box["\\All"], readonly=True)        # All Mail excludes Spam and Trash
        if typ != "OK": raise RuntimeError(f"{self.src}: cannot open All Mail ({typ})")
        if key.startswith("gm:"): typ, d = self.m.uid("SEARCH", "X-GM-MSGID", key[3:])
        else: typ, d = self.m.uid("SEARCH", "X-GM-RAW", f'"rfc822msgid:{key} -in:trash -in:spam"')
        if typ != "OK": raise RuntimeError(f"{self.src}: All Mail search failed ({typ})")   # never read an error as "found"
        if d and d[0]: return True
        if key.startswith("gm:"): return False
        # second, independent check (Gmail's X-GM-RAW search can lag): a plain IMAP header search in All Mail
        typ, d = self.m.uid("SEARCH", "HEADER", "Message-ID", key)
        if typ != "OK": raise RuntimeError(f"{self.src}: All Mail header search failed ({typ})")
        return bool(d and d[0])

def mailbox_ids(acct):
    boxes = jmap([["Mailbox/get", {"accountId": acct, "properties": ["name", "role", "parentId"]}, "m"]])[0][1]["list"]
    role = {b.get("role"): b["id"] for b in boxes if b.get("role")}
    folder = next((b["id"] for b in boxes if b["name"] == FOLDER and not b.get("parentId")), None)
    if folder is None and not DRY:
        r = jmap([["Mailbox/set", {"accountId": acct, "create": {"f": {"name": FOLDER, "parentId": None}}}, "c"]])[0][1]
        folder = r["created"]["f"]["id"]; say(f"[{acct}] created folder '{FOLDER}'")
    return folder, role

def sync(acct, sources, c):
    folder, role = mailbox_ids(acct)
    # Mirror rows don't record their source. If any of this account's Google sources is paused (enabled: false or
    # spam_mirror: false), its spam isn't looked at, so "no longer at Google" can't be told apart from "not checked":
    # skip the expire/rescue step for the account (copies stay put) rather than delete anything.
    paused = [s["name"] for s in SITE["google"]["sources"] if s["account"] == acct and s["name"] not in sources]
    g = {src: Google(src, user) for src, user in sources.items()}
    at_google = {}                                   # key -> {src: uid}
    for src, conn in g.items():
        for key, uid in conn.spam().items(): at_google.setdefault(key, {})[src] = uid

    rows = {r[0]: (r[1], r[2]) for r in c.execute("select key, nv_id, status from spam_mirror where acct=?", (acct,))}
    mirrored = {k: v[0] for k, v in rows.items() if v[1] == "mirrored"}

    # 1. what happened on the server to what we mirrored?
    if mirrored and paused:
        say(f"[{acct}] {', '.join(paused)} paused: not expiring or rescuing mirrored copies this run")
    if mirrored and not paused:
        found = {}
        ids = list(mirrored.values())
        for i in range(0, len(ids), 500):
            for e in jmap([["Email/get", {"accountId": acct, "ids": ids[i:i+500], "properties": ["mailboxIds"]}, "g"]])[0][1]["list"]:
                found[e["id"]] = set(e["mailboxIds"])
        for key, nv_id in mirrored.items():
            boxes = found.get(nv_id)
            if folder in (boxes or ()):
                if key not in at_google:              # Google dropped it: expired, or rescued directly in Gmail?
                    if any(conn.kept_outside_spam(key) for conn in g.values()):
                        say(f"[{acct}] rescued in Gmail -> moving server copy to Inbox: {key[:40]}")
                        if not DRY:   # out of the mirror folder, into Inbox; any other folder the user added stays
                            jmap([["Email/set", {"accountId": acct, "update": {nv_id: {f"mailboxIds/{folder}": None,
                                                                                         f"mailboxIds/{role['inbox']}": True}}}, "u"]])
                            c.execute("update spam_mirror set status='rescued-at-google', at=? where acct=? and key=?", (now(), acct, key))
                    else:
                        others = (boxes or set()) - {folder}
                        say(f"[{acct}] expired at Google -> removing from {FOLDER}{' (kept in its other folders)' if others else ''}: {key[:40]}")
                        if not DRY:   # filed elsewhere too: only leave the mirror folder; otherwise it's ours to remove
                            if others:
                                jmap([["Email/set", {"accountId": acct, "update": {nv_id: {f"mailboxIds/{folder}": None}}}, "u"]])
                            else:
                                jmap([["Email/set", {"accountId": acct, "destroy": [nv_id]}, "d"]])
                            c.execute("update spam_mirror set status='expired', at=? where acct=? and key=?", (now(), acct, key))
                continue
            if not boxes or boxes & {role.get("trash"), role.get("junk")}:
                status = "deleted"                     # confirmed spam
            else:
                status = "rescued"
                for src, uid in at_google.get(key, {}).items():
                    say(f"[{acct}] rescued on server -> Not spam at {src} (uid {uid}): {key[:40]}")
                    if not DRY: g[src].not_spam(uid)
            say(f"[{acct}] {status}: {key[:40]}")
            if not DRY: c.execute("update spam_mirror set status=?, at=? where acct=? and key=?", (status, now(), acct, key))

    # 2. new spam at Google -> mirror it (once per key, ever)
    new = [k for k in at_google if k not in rows]
    # already on the server (forwarded, or pulled by nv-fetch, then marked spam in Gmail): leave that copy where the user
    # filed it and don't add a second one. nv-fetch records every Message-ID it saw in its done table.
    on_nv = {mid(r[0]) for r in c.execute(
        "select key from done where src in (%s) and result in ('imported','skip-present')" % ",".join("?" * len(sources)),
        list(sources))}
    for key in [k for k in new if mid(k) in on_nv]:
        say(f"[{acct}] spam at Google but already on the server (not mirrored): {key[:40]}")
        if not DRY: c.execute("insert into spam_mirror values (?,?,?,?,?)", (acct, key, None, "already-on-nv", now()))
    new = [k for k in new if mid(k) not in on_nv]
    for key in new:
        src, uid = next(iter(at_google[key].items()))
        say(f"[{acct}] new spam from {src} uid {uid} -> {FOLDER}: {key[:40]}")
        if DRY: continue
        raw, when = g[src].body(uid)
        e = {"blobId": upload(acct, raw), "mailboxIds": {folder: True}, "keywords": {}}
        if when: e["receivedAt"] = when
        r = jmap([["Email/import", {"accountId": acct, "emails": {"x": e}}, "i"]])[0][1]
        if "x" not in (r.get("created") or {}): raise RuntimeError(f"import failed: {r.get('notCreated')}")
        c.execute("insert into spam_mirror values (?,?,?,?,?)", (acct, key, r["created"]["x"]["id"], "mirrored", now()))
        c.commit()
    c.commit()
    for conn in g.values():
        try: conn.m.logout()
        except Exception: pass
    say(f"[{acct}] Google Spam now {len(at_google)} | mirrored before this run {len(mirrored)} | new {len(new)}")

if __name__ == "__main__":
    c = sqlite3.connect(STATE, timeout=30)
    c.execute("create table if not exists spam_mirror (acct text, key text, nv_id text, status text, at text, primary key (acct, key))")
    for acct, sources in GROUPS.items():
        sync(acct, sources, c)
