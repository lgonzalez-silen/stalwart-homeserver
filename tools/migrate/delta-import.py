#!/usr/bin/env python3
# delta-import.py <account-id> <mbox-file>[=<folder/path>] ... [--since=YYYY-MM-DDTHH:MM:SSZ] [--no-id] [--apply]
# Catch-up after the main migration: imports into a Stalwart account only the messages from old-server mbox files
# whose Message-ID isn't in the account yet. Dry run (report only) unless --apply.
#   --since   only messages the old server received after this UTC time (From_ line), so a second catch-up doesn't
#             re-add messages users already deleted on the new server.
#   --no-id   also import messages without a Message-ID. They can't be matched, so each run would import them again:
#             use it once, on the first catch-up, together with --since.
#   target    the full folder path on the server (e.g. "archive/old/Sent"); default: the folder where most of the
#             file's already-present messages live.
# Messages are split, cleaned and dated exactly like mbox2maildir.py (same parser: Content-Length aware, bookkeeping
# headers removed from the header block only, original bytes otherwise, From_ dates in the old server's time zone).
# Keeps read/answered/flagged/draft/forwarded. Skips Dovecot "FOLDER INTERNAL DATA" placeholders and messages marked
# deleted. Also reports messages already present but in a different folder (moved since the copy): reported only.
import collections, datetime, json, mmap, os, sys, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mbox2maildir as M2M   # noqa: E402  (same folder)
from zoneinfo import ZoneInfo  # noqa: E402

K = open("/root/.secrets/laptop-api.key").read().strip(); B = "http://127.0.0.1:8080"   # admin API key (recipe/07)
M2M.TZ = ZoneInfo(M2M._site_tz())
KW = {"S": "$seen", "R": "$answered", "F": "$flagged", "D": "$draft", "P": "$forwarded"}


def j(calls):
    r = urllib.request.Request(B + "/jmap/", data=json.dumps({"using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
                               "methodCalls": calls}).encode(), headers={"Authorization": "Bearer " + K, "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=300))["methodResponses"]


def header(raw, name):
    hdr, _ = M2M.split_headers(raw)
    for n, line in M2M.parse_header_lines(hdr):
        if n == name:
            return line.split(b":", 1)[1].decode("utf-8", "replace").strip()
    return ""


since = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--since=")), None)
apply, no_id = "--apply" in sys.argv, "--no-id" in sys.argv
args = [a for a in sys.argv[1:] if not a.startswith("--")]
acct, files = args[0], args[1:]

mboxes = {m["id"]: m for m in j([["Mailbox/get", {"accountId": acct, "properties": ["name", "role", "parentId"]}, "m"]])[0][1]["list"]}
def path(m):
    p = [m["name"]]
    while m.get("parentId"):
        m = mboxes[m["parentId"]]; p.append(m["name"])
    return "/".join(reversed(p)).replace(M2M.DOT, ".")
bypath = collections.defaultdict(list)
for i, m in mboxes.items():
    bypath[path(m)].append(i)
    if m.get("role") and not m.get("parentId"):   # also by role: INBOX, Sent, Drafts, Trash, Junk, Archive
        bypath[m["role"].upper() if m["role"] == "inbox" else m["role"].capitalize()].append(i)
bypath = {k: sorted(set(v)) for k, v in bypath.items()}

where = {}; pos = 0   # lowercased Message-ID -> mailbox ids, whole account
while True:
    ids = j([["Email/query", {"accountId": acct, "position": pos, "limit": 5000}, "q"]])[0][1]["ids"]
    if not ids:
        break
    for k in range(0, len(ids), 500):
        for e in j([["Email/get", {"accountId": acct, "ids": ids[k:k + 500], "properties": ["messageId", "mailboxIds"]}, "g"]])[0][1]["list"]:
            for mid in e.get("messageId") or []:
                where.setdefault(mid.lower(), set()).update(e["mailboxIds"])
    pos += len(ids)
print("account %s: %d messages, %d distinct Message-IDs" % (acct, pos, len(where)))

total_new = 0
for spec in files:
    fpath, _, target = spec.partition("=")
    with open(fpath, "rb") as f:
        data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    new, votes = [], collections.Counter(); n = noid = ph = dele = 0
    for from_line, raw in M2M.iter_messages(data):
        n += 1
        ts = M2M.from_line_ts(from_line, 0)
        recv = datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if ts else None
        if since and (recv or "") <= since:
            continue
        if "FOLDER INTERNAL DATA" in header(raw, b"subject"):
            ph += 1; continue
        body, flags = M2M.convert_message(raw)
        if "T" in flags:
            dele += 1; continue
        mid = header(raw, b"message-id").strip("<> \t").lower()
        if not mid:
            noid += 1
            if no_id:
                new.append((body, flags, recv))
            continue
        if mid in where:
            votes.update(where[mid])
        else:
            new.append((body, flags, recv))
    if target:
        cands = bypath.get(target, [])
        if len(cands) != 1:
            sys.exit("%s: target folder %r %s" % (fpath, target, "not found" if not cands else "is ambiguous"))
        tid = cands[0]
    else:
        tid = votes.most_common(1)[0][0] if votes else None
        if tid and mboxes[tid].get("role") in ("trash", "junk"):   # never pick a folder that gets emptied by a vote
            print("%s: most copies are in %s; give the target folder explicitly as %s=<folder/path>" % (fpath, path(mboxes[tid]), fpath))
            tid = None
    others = sum(v for k, v in votes.items() if k != tid)
    print("%-40s %6d msgs | new %4d | no Message-ID %d (%s) | deleted %d | placeholders %d | -> %s | elsewhere: %d"
          % (fpath, n, len(new), noid, "included" if no_id else "skipped", dele, ph, path(mboxes[tid]) if tid else "?", others))
    if apply and new:
        if not tid:
            sys.exit("no target folder for %s: give one as %s=<folder/path>" % (fpath, fpath))
        ok = 0
        for body, flags, recv in new:
            up = json.load(urllib.request.urlopen(urllib.request.Request(B + "/jmap/upload/%s/" % acct, data=body,
                           headers={"Authorization": "Bearer " + K, "Content-Type": "message/rfc822"}), timeout=300))
            em = {"blobId": up["blobId"], "mailboxIds": {tid: True}, "keywords": {KW[c]: True for c in flags if c in KW}}
            if recv:
                em["receivedAt"] = recv
            res = j([["Email/import", {"accountId": acct, "emails": {"x": em}}, "i"]])[0][1]
            if res.get("created"):
                ok += 1
            else:
                print("   import failed:", res.get("notCreated"))
        print("   imported %d of %d" % (ok, len(new))); total_new += ok
print("TOTAL imported:", total_new if apply else "(dry run, nothing imported)")
