#!/usr/bin/python3 -I
# nv-fetch: pull new mail from Google accounts (Gmail, Google Workspace) into Stalwart. Design: google/README.md
#
# Per source: watch Google's "All Mail" for messages newer than a stored UID watermark, excluding Sent/Trash/Spam/
# Drafts/Chats (X-GM-RAW), and import each into the target Stalwart account's Inbox via JMAP Email/import (no
# Stalwart spam filter: Google already filtered it).
# Safety rules (never undo the owner's filing):
#   - starts from "now": the first run records UIDNEXT and fetches nothing older
#   - skips any message whose Message-ID is already ANYWHERE in the target account
#   - remembers every key it delivered, so mail moved/deleted on the server is never redelivered
#   - only adds; never changes or deletes anything on the server, and is read-only at Google (BODY.PEEK, EXAMINE)
#
# usage: nv-fetch                 run all enabled sources forever (systemd service)
#        nv-fetch --once [src]    one pass and exit (testing)
#        nv-fetch --status        show watermarks and counts
import sys, os, json, time, sqlite3, imaplib, re, email, email.policy, datetime, threading, subprocess, urllib.request, urllib.error, traceback

SITE = json.load(open(os.environ.get("NV_SITE", "/etc/nv/site.json")))   # installed by recipe/09-ops.sh
# google.sources[] in site.json: name, user (Google login), account (Stalwart account id it delivers to),
# own (addresses whose mail is imported as already read, like a Sieve "own Bcc copies" rule), enabled (default true).
SOURCES = {s["name"]: {"user": s["user"], "target": s["account"], "own": s.get("own", [s["user"]]),
                       "enabled": s.get("enabled", True)} for s in SITE["google"]["sources"]}
HOST = SITE["server"]["hostname"]
# Sent is skipped only when the message isn't also in Inbox: Gmail labels mail FROM the owner's other addresses
# (e.g. one Google account -> another) as Inbox+Sent. Copies of mail they sent themselves are then caught by the
# Message-ID check.
EXCLUDE = '-in:trash -in:spam -in:drafts -in:chats {in:inbox -in:sent}'
POLL = 60                      # seconds between checks
STATE = "/var/lib/nv-fetch/state.db"
KEY = open("/root/.secrets/laptop-api.key").read().strip()
API = "http://127.0.0.1:8080"

def log(src, *a): print(f"[{src}]", *a, flush=True)

PERMANENT = {"tooLarge", "invalidEmail"}   # JMAP SetError types that are about the message itself


class Rejected(Exception):
    """Stalwart answered, but refused the message (notCreated)."""


def jmap(calls):
    body = {"using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"], "methodCalls": calls}
    r = urllib.request.Request(API + "/jmap/", data=json.dumps(body).encode(),
                               headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=60))["methodResponses"]

def db():
    os.makedirs(os.path.dirname(STATE), mode=0o700, exist_ok=True)
    c = sqlite3.connect(STATE, timeout=30)
    c.execute("create table if not exists mark (src text primary key, uidvalidity int, last_uid int, started text)")
    c.execute("create table if not exists done (src text, key text, uid int, at text, result text, primary key (src, key))")
    return c

class Source:
    def __init__(self, name, cfg):
        self.name, self.cfg = name, cfg
        self.target = cfg["target"]
        self.own = {a.lower() for a in cfg["own"]}
        self.inbox = [m["id"] for m in jmap([["Mailbox/get", {"accountId": self.target, "properties": ["role"]}, "m"]])[0][1]["list"]
                      if m.get("role") == "inbox"][0]
        self.imap = None
        self.fails = 0; self.alerted = None; self.rejects = {}

    def connect(self):
        pw = open(f"/root/.secrets/fetch/{self.name}.pw").read().strip()
        m = imaplib.IMAP4_SSL("imap.gmail.com", 993, timeout=120)
        m.login(self.cfg["user"], pw)
        allmail = None
        for line in m.list()[1]:
            s = line.decode()
            if "\\All" in s.split(")")[0]:
                allmail = s.rsplit(' "/" ', 1)[1]
        if not allmail: raise RuntimeError("no \\All mailbox (All Mail hidden from IMAP?)")
        self.allmail = allmail
        self.imap = m

    def examine(self):
        typ, _ = self.imap.select(self.allmail, readonly=True)          # EXAMINE: read-only at Google
        if typ != "OK": raise RuntimeError("cannot examine All Mail")
        uv = int(self.imap.response("UIDVALIDITY")[1][0])
        nx = self.imap.response("UIDNEXT")[1][0]      # response() pops the value: read it once
        if nx: nxt = int(nx)
        else:
            typ, d = self.imap.status(self.allmail, "(UIDNEXT)"); nxt = int(re.search(rb"UIDNEXT (\d+)", d[0]).group(1))
        return uv, nxt

    # Stalwart 1.0.1 can't query by header (filter "header" always matches nothing), so keep our own index of the
    # target account's Message-IDs: full load once, then Email/changes before each lookup.
    def _mids_of(self, ids):
        out = set()
        for i in range(0, len(ids), 500):
            for e in jmap([["Email/get", {"accountId": self.target, "ids": ids[i:i+500], "properties": ["messageId"]}, "g"]])[0][1]["list"]:
                out.update(m.strip("<> ") for m in (e.get("messageId") or []))
        return out

    def load_index(self):
        ids, pos = [], 0
        while True:
            r = jmap([["Email/query", {"accountId": self.target, "position": pos, "limit": 10000}, "q"]])[0][1]
            ids += r["ids"]; pos += len(r["ids"])
            if not r["ids"]: break
        self.state = jmap([["Email/get", {"accountId": self.target, "ids": [], "properties": ["id"]}, "s"]])[0][1]["state"]
        self.mids = self._mids_of(ids)
        log(self.name, f"index: {len(self.mids)} Message-IDs in account {self.target} ({len(ids)} messages)")

    def exists_on_nv(self, mid):
        if not hasattr(self, "mids"): self.load_index()
        r = jmap([["Email/changes", {"accountId": self.target, "sinceState": self.state, "maxChanges": 5000}, "c"]])[0][1]
        if "newState" not in r or r.get("hasMoreChanges"):
            self.load_index()
        else:
            self.mids |= self._mids_of(r["created"] + r["updated"]); self.state = r["newState"]
        return mid.strip("<> ") in self.mids

    def import_one(self, raw, internaldate, flags):
        req = urllib.request.Request(f"{API}/jmap/upload/{self.target}/", data=raw,
                                     headers={"Authorization": "Bearer " + KEY, "Content-Type": "message/rfc822"})
        try:
            blob = json.load(urllib.request.urlopen(req, timeout=120))["blobId"]
        except urllib.error.HTTPError as e:
            if e.code in (400, 413): raise Rejected(f"upload refused (HTTP {e.code}, {len(raw)/1e6:.1f} MB): too large?")
            raise
        msg = email.message_from_bytes(raw[:65536], policy=email.policy.compat32)
        frm = email.utils.parseaddr(str(msg.get("From", "")))[1].lower()
        kw = {}
        if "\\Seen" in flags or frm in self.own: kw["$seen"] = True
        if "\\Flagged" in flags: kw["$flagged"] = True
        e = {"blobId": blob, "mailboxIds": {self.inbox: True}, "keywords": kw}
        if internaldate: e["receivedAt"] = internaldate
        r = jmap([["Email/import", {"accountId": self.target, "emails": {"x": e}}, "i"]])[0][1]
        if "x" not in (r.get("created") or {}):
            err = (r.get("notCreated") or {}).get("x") or {}
            # only problems with THIS message are skipped after 3 tries; anything else (over quota, server trouble)
            # is a normal failure: retried, alerted, and nothing is skipped
            if err.get("type") in PERMANENT: raise Rejected(f"import refused: {err}")
            raise RuntimeError(f"import failed: {err}")
        mid = str(msg.get("Message-ID") or "").strip("<> \r\n")
        if mid and hasattr(self, "mids"): self.mids.add(mid)

    def one_pass(self, c):
        if self.imap is None: self.connect()
        uv, nxt = self.examine()
        row = c.execute("select uidvalidity, last_uid from mark where src=?", (self.name,)).fetchone()
        if row is None or row[0] != uv:
            # first run (or Google reset UIDs): start from now, fetch nothing older. Dedupe protects a UIDVALIDITY reset.
            c.execute("insert or replace into mark values (?,?,?,?)", (self.name, uv, nxt - 1, datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")))
            c.commit(); log(self.name, f"watermark set at UID {nxt-1} (uidvalidity {uv}); only newer mail will be fetched")
            return 0
        last = row[1]
        if nxt - 1 <= last: return 0
        typ, d = self.imap.uid("SEARCH", "UID", f"{last+1}:*", "X-GM-RAW", f'"{EXCLUDE}"')
        uids = sorted(u for u in map(int, d[0].split()) if u > last) if d and d[0] else []
        n = 0
        for uid in uids:
            typ, d = self.imap.uid("FETCH", str(uid), "(X-GM-MSGID INTERNALDATE FLAGS BODY.PEEK[])")
            if typ != "OK": raise RuntimeError(f"FETCH uid {uid} failed ({typ}): retrying next pass")
            meta = b"".join(p[0] if isinstance(p, tuple) else p for p in d if p)
            raw = next((p[1] for p in d if isinstance(p, tuple)), None)
            if raw is None: continue                                   # vanished meanwhile
            gm = re.search(rb"X-GM-MSGID (\d+)", meta)
            idt = re.search(rb'INTERNALDATE "([^"]+)"', meta)
            flags = (re.search(rb"FLAGS \(([^)]*)\)", meta) or [None, b""])[1].decode()
            idate = None
            if idt:
                idate = datetime.datetime.strptime(idt.group(1).decode(), "%d-%b-%Y %H:%M:%S %z").astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            hdr = email.message_from_bytes(raw[:65536], policy=email.policy.compat32)
            mid = (str(hdr.get("Message-ID") or "")).strip()
            key = mid or f"gm:{gm.group(1).decode() if gm else uid}"
            if c.execute("select 1 from done where src=? and key=?", (self.name, key)).fetchone():
                result = "skip-done"
            elif mid and self.exists_on_nv(mid):
                result = "skip-present"
            else:
                try:
                    self.import_one(raw, idate, flags); result = "imported"; n += 1
                except Rejected as e:
                    # Stalwart refused this one message (e.g. over the size limit). Retry on the next passes; after 3
                    # refusals, record it, tell the owner once, and move on, so one message can't block the account.
                    self.rejects[uid] = self.rejects.get(uid, 0) + 1
                    if self.rejects[uid] < 3: raise
                    result = "rejected"
                    body = (f"One message in {self.cfg['user']} could not be imported and was skipped (it stays at Google).\n\n"
                            f"Google UID {uid}, {len(raw)/1e6:.1f} MB, received {idate}.\nReason: {e}\n\n"
                            "Most often it is larger than the server's message size limit. Read it in Google's web mail.\n")
                    subprocess.run(["/usr/local/sbin/nv-alert", f"mail pull skipped a message: {self.name}"], input=body.encode())
            c.execute("insert or ignore into done values (?,?,?,?,?)", (self.name, key, uid, datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"), result))
            c.execute("update mark set last_uid=? where src=?", (uid, self.name))
            c.commit()
            log(self.name, f"uid {uid}: {result}")
        if uids and uids[-1] < nxt - 1:     # newer UIDs that are excluded (sent/spam/...): advance past them
            c.execute("update mark set last_uid=? where src=?", (nxt - 1, self.name)); c.commit()
        elif not uids:
            c.execute("update mark set last_uid=? where src=?", (nxt - 1, self.name)); c.commit()
        return n

    def failed(self, e):
        self.fails += 1
        try: self.imap and self.imap.logout()
        except Exception: pass
        self.imap = None
        log(self.name, f"error ({self.fails} in a row): {e}")
        today = datetime.date.today()
        if self.fails >= 10 and self.alerted != today:       # ~10 minutes of failures; at most one alert per day
            self.alerted = today
            body = (f"Pulling mail from {self.cfg['user']} into the mail server has failed {self.fails} times in a row.\n\nLast error: {e}\n\n"
                    "If it says the login/credentials are invalid, the app password was revoked (e.g. after a Google password\n"
                    "change). Create a new one and run:  ssh -t root@" + HOST + " nv-fetch-secret " + self.name + "\n"
                    "Mail isn't lost meanwhile: it waits at Google and is fetched once this works again.\n")
            subprocess.run(["/usr/local/sbin/nv-alert", f"mail pull failing: {self.name}"], input=body.encode())

def run(src, once=False):
    while True:      # Source() talks to Stalwart; at boot it may not be up yet: keep trying instead of dying silently
        try:
            s = Source(src, SOURCES[src]); break
        except Exception as e:
            log(src, f"start failed, retrying in {POLL}s: {type(e).__name__}: {e}")
            if once: raise
            time.sleep(POLL)
    c = db()
    while True:
        try:
            s.one_pass(c); s.fails = 0
        except Exception as e:
            s.failed(f"{type(e).__name__}: {e}")
            if once: traceback.print_exc()
        if once: return
        time.sleep(POLL)

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--status" in sys.argv:
        c = db()
        for r in c.execute("select src, last_uid, started from mark"): print("mark", r)
        for r in c.execute("select src, result, count(*) from done group by src, result"): print("done", r)
        sys.exit(0)
    srcs = args or [k for k, v in SOURCES.items() if v["enabled"]]
    if "--once" in sys.argv:
        for s in srcs: run(s, once=True)
        sys.exit(0)
    threads = [threading.Thread(target=run, args=(s,), daemon=True) for s in srcs]
    for t in threads: t.start()
    for t in threads: t.join()
