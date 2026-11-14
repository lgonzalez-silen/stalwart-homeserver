#!/usr/bin/python3 -I
# nv-google-trim: keep Google accounts with a storage limit (e.g. a school or work Google Workspace) small.
# Only for sources with keep_days set in site.json (google.sources[]). Design: google/README.md
#
#   message older than keep_days AND its Message-ID is kept on the server (a folder other than Trash, Junk, Google Spam) -> moved to that account's Trash
#   everything else (newer, not on the server, no Message-ID, Spam, Trash, Drafts, Chats)   -> left alone
#
# Moving to Trash = Google deletes it for good after 30 days, so a mistake can be undone for a month (Trash -> Inbox).
# Sources without keep_days are never touched. Nothing on the server is changed. Every message moved is recorded in
# state.db (table google_trim).
# usage: nv-google-trim [--dry] [src ...]   (--dry: report only, change nothing; default: all sources with keep_days)
#        nv-google-trim --max N              (stop after N moves per source in this run; default 50000)
import sys, os, time, json, re, imaplib, email, email.policy, datetime, sqlite3, urllib.request

sys.path.insert(0, "/usr/local/lib/nv"); sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))  # repo copy last
from nvlib import jmap, upload, mid, message_ids, gmail_folders, site, ADMIN  # noqa: E402
SITE = site()   # installed by recipe/09-ops.sh
SOURCES = {s["name"]: (s["user"], s["account"], int(s["keep_days"])) for s in SITE["google"]["sources"]
           if s.get("keep_days") and s.get("enabled", True)}   # enabled: false pauses the trim too
STATE = "/var/lib/nv-fetch/state.db"
DRY = "--dry" in sys.argv
MAX = int(sys.argv[sys.argv.index("--max") + 1]) if "--max" in sys.argv else 50000
ARGS = [a for a in sys.argv[1:] if a in SOURCES]
now = lambda: datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")

def nv_mids(acct):
    """Every Message-ID the server KEEPS: in some folder other than Trash or Junk (those get emptied, so a copy
    that only sits there doesn't count, and the Google copy is left alone)."""
    # also "Google Spam" (nv-spam-mirror's folder): its copies are removed when Google expires them
    out, n = message_ids(acct, skip_roles=("trash", "junk"), skip_names=("Google Spam",))
    if n < 1000 or len(out) < 0.5 * n:
        raise RuntimeError(f"server index for {acct} looks wrong ({n} emails, {len(out)} ids): refusing to trim")
    return out

def trim(src, user, acct, KEEP_DAYS, c):
    on_nv = nv_mids(acct)
    skip = {k for (k,) in c.execute("select key from google_trim_skip where src = ?", (src,))}
    m = imaplib.IMAP4_SSL("imap.gmail.com", 993, timeout=120)
    m.login(user, open(f"/root/.secrets/fetch/{src}.pw").read().strip())
    box = gmail_folders(m, ("\\All", "\\Trash"))
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
    print(f"[{src}] older than {cutoff}: {len(uids)} | on server -> Trash: {len(go)} ({size_go/1e9:.2f} GB) | "
          f"not on server, kept: {keep} | no Message-ID, kept: {nomid}" + (" | DRY, nothing moved" if DRY else ""), flush=True)
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
