#!/usr/bin/python3 -I
# nv-google-trim: keep Google accounts with a storage limit (e.g. a school or work Google Workspace) small.
# Only for sources with keep_days set in site.json (google.sources[]). Design: google/README.md
#
#   message older than keep_days AND its Message-ID is somewhere on the server (any folder) -> moved to that account's Trash
#   everything else (newer, not on the server, no Message-ID, Spam, Trash, Drafts, Chats)   -> left alone
#
# Moving to Trash = Google deletes it for good after 30 days, so a mistake can be undone for a month (Trash -> Inbox).
# Sources without keep_days are never touched. Nothing on the server is changed. Every message moved is recorded in
# state.db (table google_trim).
# usage: nv-google-trim [--dry] [src ...]   (--dry: report only, change nothing; default: all sources with keep_days)
#        nv-google-trim --max N              (stop after N moves per source in this run; default 50000)
import sys, os, time, json, re, imaplib, email, email.policy, datetime, sqlite3, urllib.request

SITE = json.load(open(os.environ.get("NV_SITE", "/etc/nv/site.json")))   # installed by recipe/09-ops.sh
SOURCES = {s["name"]: (s["user"], s["account"], int(s["keep_days"])) for s in SITE["google"]["sources"] if s.get("keep_days")}
STATE = "/var/lib/nv-fetch/state.db"
KEY = open("/root/.secrets/laptop-api.key").read().strip(); API = "http://127.0.0.1:8080"
DRY = "--dry" in sys.argv
MAX = int(sys.argv[sys.argv.index("--max") + 1]) if "--max" in sys.argv else 50000
ARGS = [a for a in sys.argv[1:] if a in SOURCES]
now = lambda: datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")

def jmap(calls):
    body = {"using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"], "methodCalls": calls}
    r = urllib.request.Request(API + "/jmap/", data=json.dumps(body).encode(),
                               headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=120))["methodResponses"]

def nv_mids(acct):
    """Every Message-ID in the nv account, all folders."""
    ids, pos = [], 0
    while True:
        r = jmap([["Email/query", {"accountId": acct, "position": pos, "limit": 10000}, "q"]])[0][1]
        if not r["ids"]: break
        ids += r["ids"]; pos += len(r["ids"])
    out = set()
    for i in range(0, len(ids), 500):
        for e in jmap([["Email/get", {"accountId": acct, "ids": ids[i:i+500], "properties": ["messageId"]}, "g"]])[0][1]["list"]:
            out.update(m.strip("<> ") for m in (e.get("messageId") or []))
    if len(ids) < 1000 or len(out) < 0.5 * len(ids):
        raise RuntimeError(f"nv index for {acct} looks wrong ({len(ids)} emails, {len(out)} ids): refusing to trim")
    return out

def trim(src, user, acct, KEEP_DAYS, c):
    on_nv = nv_mids(acct)
    skip = {k for (k,) in c.execute("select key from google_trim_skip where src = ?", (src,))}
    m = imaplib.IMAP4_SSL("imap.gmail.com", 993, timeout=120)
    m.login(user, open(f"/root/.secrets/fetch/{src}.pw").read().strip())
    box = {}
    for line in m.list()[1]:
        s = line.decode(); flags = s.split(")")[0]; name = s.rsplit(' "/" ', 1)[1]
        for f in ("\\All", "\\Trash"):
            if f in flags: box[f] = name
    m.select(box["\\All"], readonly=DRY)
    cutoff = (datetime.date.today() - datetime.timedelta(days=KEEP_DAYS)).strftime("%Y/%m/%d")
    typ, d = m.uid("SEARCH", "X-GM-RAW", f'"before:{cutoff} -in:trash -in:spam -in:drafts -in:chats"')
    uids = d[0].split() if d and d[0] else []
    go, keep, nomid, size_go = [], 0, 0, 0
    for i in range(0, len(uids), 500):
        typ, dd = m.uid("FETCH", b",".join(uids[i:i+500]).decode(), "(RFC822.SIZE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
        for p in dd:
            if not isinstance(p, tuple): continue
            uid = int(re.search(rb"UID (\d+)", p[0]).group(1)); size = int(re.search(rb"RFC822.SIZE (\d+)", p[0]).group(1))
            mid = str(email.message_from_bytes(p[1], policy=email.policy.compat32).get("Message-ID") or "").strip("<> \r\n")
            if not mid: nomid += 1
            elif mid in skip: keep += 1
            elif mid in on_nv: go.append((uid, mid)); size_go += size
            else: keep += 1
    go = go[:MAX]
    print(f"[{src}] older than {cutoff}: {len(uids)} | on nv -> Trash: {len(go)} ({size_go/1e9:.2f} GB) | "
          f"not on nv, kept: {keep} | no Message-ID, kept: {nomid}" + (" | DRY, nothing moved" if DRY else ""), flush=True)
    if DRY: m.logout(); return
    # Google sometimes answers a MOVE with "System Error" and drops the connection, often AFTER doing the move. So: move
    # 50 at a time; if a batch errors, reconnect and check which of its messages are really still in All Mail; retry
    # those one by one. A message still there after its own retry is left at Google and remembered in
    # google_trim_skip so later runs don't trip over it. More than 20 such in a run = stop (alert).
    def connect():
        n = imaplib.IMAP4_SSL("imap.gmail.com", 993, timeout=120)
        n.login(user, open(f"/root/.secrets/fetch/{src}.pw").read().strip()); n.select(box["\\All"]); return n
    def move(conn, part):
        try:
            return conn.uid("MOVE", ",".join(str(u) for u, _ in part), box["\\Trash"])[0] == "OK"
        except imaplib.IMAP4.abort:
            return False
    def present(conn, part):
        typ, dd = conn.uid("FETCH", ",".join(str(u) for u, _ in part), "(UID)")
        there = {int(x) for p in dd if p for x in re.findall(rb"UID (\d+)", p if isinstance(p, bytes) else p[0])}
        return [x for x in part if x[0] in there]
    def done(part):
        c.executemany("insert or replace into google_trim values (?,?,?,?)", [(src, mid, u, now()) for u, mid in part])
        c.commit()
    moved, skipped = 0, 0
    for i in range(0, len(go), 50):
        batch = go[i:i+50]
        if move(m, batch): done(batch); moved += len(batch); continue
        time.sleep(10); m = connect()
        left = present(m, batch); gone = [x for x in batch if x not in left]; done(gone); moved += len(gone)
        for one in left:
            if move(m, [one]): done([one]); moved += 1; continue
            time.sleep(10); m = connect()
            if not present(m, [one]): done([one]); moved += 1; continue
            skipped += 1
            c.execute("insert or replace into google_trim_skip values (?,?,?)", (src, one[1], now())); c.commit()
            print(f"[{src}] Google refused to move uid {one[0]}; left at Google", flush=True)
            if skipped > 20: raise RuntimeError(f"{src}: more than 20 messages refused; stopping (moved {moved})")
    print(f"[{src}] moved to Trash: {moved}" + (f" | refused by Google, left at Google: {skipped}" if skipped else ""), flush=True)
    m.logout()

if __name__ == "__main__":
    c = sqlite3.connect(STATE, timeout=30)
    c.execute("create table if not exists google_trim (src text, key text, uid int, at text, primary key (src, key))")
    c.execute("create table if not exists google_trim_skip (src text, key text, at text, primary key (src, key))")
    for src in ARGS or list(SOURCES):
        trim(src, *SOURCES[src], c)
