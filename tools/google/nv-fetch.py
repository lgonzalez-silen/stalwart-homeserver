#!/usr/bin/python3 -I
# nv-fetch: pull new mail from Google accounts (Gmail, Google Workspace) into Stalwart. Design: google/README.md
#
# Per source: poll Google's "All Mail" every 60 s for messages newer than a stored UID mark, skip drafts, chats and
# Sent mail that isn't also in the Inbox (decided from each message's labels; All Mail has no Spam or Trash), and
# import each into the target Stalwart account's Inbox via JMAP Email/import (no
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

sys.path.insert(0, "/usr/local/lib/nv"); sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))  # repo copy last
from nvlib import jmap, upload, mid, message_ids, gmail_folders, site, ADMIN  # noqa: E402
SITE = site()   # installed by recipe/09-ops.sh
# google.sources[] in site.json: name, user (Google login), account (Stalwart account id it delivers to),
# own (addresses whose mail is imported as already read, like a Sieve "own Bcc copies" rule), enabled (default true).
SOURCES = {s["name"]: {"user": s["user"], "target": s["account"], "own": s.get("own", [s["user"]]),
                       "enabled": s.get("enabled", True)} for s in SITE["google"]["sources"]}
HOST = SITE["server"]["hostname"]
# Sent is skipped only when the message isn't also in Inbox: Gmail labels mail FROM the owner's other addresses
# (e.g. one Google account -> another) as Inbox+Sent. Copies of mail they sent themselves are then caught by the
# Message-ID check.
POLL = 60                      # seconds between checks
STATE = "/var/lib/nv-fetch/state.db"

def log(src, *a): print(f"[{src}]", *a, flush=True)
now = lambda: datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")

PERMANENT = {"tooLarge", "invalidEmail"}   # JMAP SetError types that are about the message itself


class Rejected(Exception):
    """Stalwart answered, but refused the message (notCreated)."""


def db():
    os.makedirs(os.path.dirname(STATE), mode=0o700, exist_ok=True)
    c = sqlite3.connect(STATE, timeout=30)
    c.execute("create table if not exists mark (src text primary key, uidvalidity int, last_uid int, started text)")
    c.execute("create table if not exists done (src text, key text, uid int, at text, result text, primary key (src, key))")
    # heartbeat for nv-status: when each source last checked Google successfully, and its last error
    c.execute("create table if not exists pass (src text primary key, ok_at text, err_at text, err text)")
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
        allmail = gmail_folders(m, ("\\All",)).get("\\All")
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
        """Message-IDs of these emails, leaving out copies that sit only in Junk or Trash: a stranger who knows a
        message's Message-ID could otherwise send a fake (filed in Junk) and make the pull skip the real one."""
        out = set()
        for i in range(0, len(ids), 500):
            for e in jmap([["Email/get", {"accountId": self.target, "ids": ids[i:i+500], "properties": ["messageId", "mailboxIds"]}, "g"]])[0][1]["list"]:
                if set(e.get("mailboxIds") or {}) - self.binned:
                    out.update(mid(m) for m in (e.get("messageId") or []))
        return out

    def load_index(self):
        mbs = jmap([["Mailbox/get", {"accountId": self.target, "properties": ["role"]}, "m"]])[0][1]["list"]
        self.binned = {m["id"] for m in mbs if m.get("role") in ("junk", "trash")}
        ids, pos = [], 0
        while True:
            r = jmap([["Email/query", {"accountId": self.target, "position": pos, "limit": 10000}, "q"]])[0][1]
            ids += r["ids"]; pos += len(r["ids"])
            if not r["ids"]: break
        self.state = jmap([["Email/get", {"accountId": self.target, "ids": [], "properties": ["id"]}, "s"]])[0][1]["state"]
        self.mids = self._mids_of(ids)
        log(self.name, f"index: {len(self.mids)} Message-IDs in account {self.target} ({len(ids)} messages)")

    def exists_on_nv(self, msgid):
        if not hasattr(self, "mids"): self.load_index()
        # check=False: an error here (e.g. cannotCalculateChanges) just means "reload the index"
        r = jmap([["Email/changes", {"accountId": self.target, "sinceState": self.state, "maxChanges": 5000}, "c"]], check=False)[0][1]
        if "newState" not in r or r.get("hasMoreChanges"):
            self.load_index()
        else:
            self.mids |= self._mids_of(r["created"] + r["updated"]); self.state = r["newState"]
        return mid(msgid) in self.mids

    def import_one(self, raw, internaldate, flags):
        try:
            blob = upload(self.target, raw)
        except urllib.error.HTTPError as e:
            # 413 = too large: about this message. Other errors (400 can mean a full upload quota) are retried.
            if e.code == 413: raise Rejected(f"upload refused as too large (HTTP 413, {len(raw)/1e6:.1f} MB)")
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
        # Which new messages to pull: list EVERY uid above the mark (the mailbox's own index, complete), read each
        # one's labels, and apply the rule locally. (Gmail's search, X-GM-RAW, can lag behind new mail; a uid it
        # didn't return used to be treated as excluded and skipped forever.)
        todo, decided = self.pending(last)
        n = 0
        for uid in todo:
            typ, d = self.imap.uid("FETCH", str(uid), "(X-GM-MSGID INTERNALDATE FLAGS BODY.PEEK[])")
            raw = next((p[1] for p in d if isinstance(p, tuple)), None) if typ == "OK" else None
            if raw is None:
                # Google failed to hand it over, or it vanished meanwhile. Retry on the next passes; after 3, record
                # it, tell the owner once, and move on, so one message can't stop the whole account.
                self.rejects[uid] = self.rejects.get(uid, 0) + 1
                if self.rejects[uid] < 3:
                    raise RuntimeError(f"FETCH uid {uid}: {typ}, no message body; retrying next pass")
                self.skip(c, f"gm-uid:{uid}", uid, "fetch-failed", f"Google UID {uid} could not be fetched ({typ}), 3 tries.")
                continue
            meta = b"".join(p[0] if isinstance(p, tuple) else p for p in d if p)
            gm = re.search(rb"X-GM-MSGID (\d+)", meta)
            idt = re.search(rb'INTERNALDATE "([^"]+)"', meta)
            flags = (re.search(rb"FLAGS \(([^)]*)\)", meta) or [None, b""])[1].decode()
            idate = None
            if idt:
                idate = datetime.datetime.strptime(idt.group(1).decode(), "%d-%b-%Y %H:%M:%S %z").astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            hdr = email.message_from_bytes(raw[:65536], policy=email.policy.compat32)
            msgid = mid(hdr.get("Message-ID"))
            key = f"<{msgid}>" if msgid else f"gm:{gm.group(1).decode() if gm else uid}"
            if c.execute("select 1 from done where src=? and key in (?,?)", (self.name, key, msgid)).fetchone():
                result = "skip-done"
            elif msgid and self.exists_on_nv(msgid):
                result = "skip-present"
            else:
                try:
                    self.import_one(raw, idate, flags); result = "imported"; n += 1
                except Rejected as e:
                    # Stalwart refused this one message (too large, invalid). Retry on the next passes; after 3
                    # refusals, record it, tell the owner once, and move on, so one message can't block the account.
                    self.rejects[uid] = self.rejects.get(uid, 0) + 1
                    if self.rejects[uid] < 3: raise
                    self.skip(c, key, uid, "rejected", f"Google UID {uid}, {len(raw)/1e6:.1f} MB, received {idate}.\n"
                              f"Reason: {e}\n\nMost often it is larger than the server's message size limit.")
                    continue
            c.execute("insert or ignore into done values (?,?,?,?,?)", (self.name, key, uid, now(), result))
            c.execute("update mark set last_uid=? where src=?", (uid, self.name))
            c.commit()
            log(self.name, f"uid {uid}: {result}")
        if decided > last:   # every uid up to here was listed and judged (excluded ones need nothing)
            c.execute("update mark set last_uid=max(last_uid, ?) where src=?", (decided, self.name)); c.commit()
        return n

    def pending(self, last):
        """(uids to pull, highest uid decided). Lists all uids above `last`, reads their labels, and keeps the ones the
        rule wants: not a draft or chat, and in the Inbox or not Sent (mail FROM the owner's other addresses is labeled
        Inbox+Sent; copies of their own sent mail are caught by the Message-ID check). A uid whose labels didn't come
        back stops the 'decided' mark there, so it's looked at again next pass."""
        typ, d = self.imap.uid("SEARCH", "UID", f"{last+1}:*")
        if typ != "OK": raise RuntimeError(f"UID SEARCH failed ({typ})")
        uids = sorted(u for u in map(int, d[0].split()) if u > last) if d and d[0] else []
        labels = {}
        def read(reply):
            for line in reply:
                line = line.decode(errors="replace") if isinstance(line, bytes) else (line[0].decode(errors="replace") if isinstance(line, tuple) else "")
                u = re.search(r"UID (\d+)", line)
                if not u: continue
                lab = re.search(r"X-GM-LABELS \((.*?)\)(?: |\)|$)", line); fl = re.search(r"FLAGS \((.*?)\)", line)
                names = [q.replace("\\\\", "\\") or w for q, w in re.findall(r'"((?:[^"\\]|\\.)*)"|(\S+)', lab.group(1))] if lab else []
                labels[int(u.group(1))] = (names, fl.group(1) if fl else "")
        for i in range(0, len(uids), 500):
            typ, d = self.imap.uid("FETCH", ",".join(map(str, uids[i:i+500])), "(X-GM-LABELS FLAGS)")
            if typ != "OK": raise RuntimeError(f"label FETCH failed ({typ})")
            read(d)
        todo, decided = [], last
        for u in uids:
            if u not in labels:   # its labels didn't come back in the batch: ask for that one message alone
                typ, d = self.imap.uid("FETCH", str(u), "(X-GM-LABELS FLAGS)")
                if typ == "OK": read(d)
            if u not in labels:   # still nothing: an error (counted, alerted after ~10), never a silent stop
                raise RuntimeError(f"no labels for uid {u} in Gmail's reply; can't decide it, not moving past it")
            names, fl = labels[u]
            if not ("\\Draft" in fl or "\\Draft" in names or any("chat" in x.lower() for x in names)) \
                    and ("\\Inbox" in names or "\\Sent" not in names):
                todo.append(u)
            decided = u
        return todo, decided

    def skip(self, c, key, uid, result, why):
        """Record a message we give up on (it stays at Google), alert once, move the mark past it."""
        c.execute("insert or ignore into done values (?,?,?,?,?)", (self.name, key, uid, now(), result))
        c.execute("update mark set last_uid=max(last_uid, ?) where src=?", (uid, self.name)); c.commit()
        log(self.name, f"uid {uid}: {result}")
        body = (f"One message in {self.cfg['user']} was skipped by the mail pull (it stays at Google; read it there).\n\n{why}\n")
        subprocess.run(["/usr/local/sbin/nv-alert", f"mail pull skipped a message: {self.name}"], input=body.encode())

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
    tries = 0        # Source() talks to Stalwart; at boot it may not be up yet: keep trying, and alert if it never works
    while True:
        try:
            s = Source(src, SOURCES[src]); break
        except Exception as e:
            tries += 1
            log(src, f"start failed ({tries}), retrying in {POLL}s: {type(e).__name__}: {e}")
            if once: raise
            if tries % 1440 == 10:   # after ~10 minutes, then once a day
                body = (f"The mail pull for {SOURCES[src]['user']} can't start: {type(e).__name__}: {e}\n\n"
                        "Usually the server's API key (/root/.secrets/laptop-api.key) or an account id in site.json.\n")
                subprocess.run(["/usr/local/sbin/nv-alert", f"mail pull failing: {src}"], input=body.encode())
            time.sleep(POLL)
    c = db()
    while True:
        try:
            s.one_pass(c); s.fails = 0
            c.execute("insert into pass (src, ok_at) values (?, ?) on conflict(src) do update set ok_at=excluded.ok_at", (src, now()))
            c.commit()
        except Exception as e:
            s.failed(f"{type(e).__name__}: {e}")
            try:
                c.execute("insert into pass (src, err_at, err) values (?, ?, ?) on conflict(src) do update set "
                          "err_at=excluded.err_at, err=excluded.err", (src, now(), f"{type(e).__name__}: {e}"[:300]))
                c.commit()
            except Exception: pass
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
