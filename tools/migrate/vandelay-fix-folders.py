# vandelay-fix-folders.py <login> <account-id> <archive.sqlite> <password-file> [--dry-run]   (run on the server)
# Vandelay de-duplicates by Message-ID, so a message that sat in two folders on the old server lands in only one.
# This reads the archive's folder placements and adds the missing folder memberships in Stalwart (no copies made).
import json, sqlite3, urllib.request, base64, collections, sys
ACCT_USER, ACCT, DB = sys.argv[1], sys.argv[2], sys.argv[3]
DRY = "--dry-run" in sys.argv
PW=open(sys.argv[4]).read().strip()
AUTH="Basic "+base64.b64encode(f"{ACCT_USER}:{PW}".encode()).decode()
def jmap(calls):
    req=urllib.request.Request("http://127.0.0.1:8080/jmap/", data=json.dumps({"using":["urn:ietf:params:jmap:core","urn:ietf:params:jmap:mail"],"methodCalls":calls}).encode(), headers={"Authorization":AUTH,"Content-Type":"application/json"})
    return json.load(urllib.request.urlopen(req))["methodResponses"]
mbs=jmap([["Mailbox/get",{"accountId":ACCT,"properties":["name","parentId","role"]},"m"]])[0][1]["list"]
byid={m["id"]:m for m in mbs}
def p(m):
    s=[m["name"]]
    while m.get("parentId"): m=byid[m["parentId"]]; s.append(m["name"])
    return "/".join(reversed(s))
DOT="\u2024"   # mbox2maildir writes "." inside a folder name as U+2024; compare with "." either way
norm=lambda x: x.replace(DOT,".")
path2id={norm(p(m)):i for i,m in byid.items()}
role2path={m["role"]:norm(p(m)) for m in mbs if m.get("role")}
ids=[]; pos=0
while True:
    r=jmap([["Email/query",{"accountId":ACCT,"position":pos,"limit":5000},"q"]])[0][1]
    if not r["ids"]: break
    ids+=r["ids"]; pos+=len(r["ids"])
bymid={}; inmb=collections.defaultdict(set)
for i in range(0,len(ids),500):
    for e in jmap([["Email/get",{"accountId":ACCT,"ids":ids[i:i+500],"properties":["messageId","mailboxIds"]},"g"]])[0][1]["list"]:
        for m in (e.get("messageId") or [])[:1]:
            bymid.setdefault(m.lower(), []).append(e["id"]); inmb[e["id"]] |= set(e["mailboxIds"])
db=sqlite3.connect(DB)
amb={r[0]:r for r in db.execute("select id,name,parent_id,role from mailboxes")}
def ap(i):
    r=amb[i]
    if r[3] and r[3] in role2path: return role2path[r[3]]
    s=[r[1]]
    while r[2]: r=amb[r[2]]; s.append(r[1])
    return norm("/".join(reversed(s)))
add=collections.defaultdict(set); missing=collections.Counter(); nofolder=collections.Counter()
for mi,mbj in db.execute("select json_extract(message_match,'$.m[0]'), mailbox_ids from emails"):
    for lm in json.loads(mbj):
        f=ap(int(lm))
        eids=bymid.get(mi) if mi else None
        if not eids: missing[f]+=1; continue
        tgt=path2id.get(f)
        if not tgt: nofolder[f]+=1; continue
        if not any(tgt in inmb[x] for x in eids): add[eids[0]].add(tgt)
n=sum(len(v) for v in add.values())
print(f"memberships to add: {n} on {len(add)} messages; not found in Stalwart: {dict(missing)}")
if nofolder: print(f"archive folders with no matching folder in Stalwart (skipped): {dict(nofolder)}")
if DRY: sys.exit()
items=list(add.items()); done=fail=0
for i in range(0,len(items),500):
    upd={eid:{f"mailboxIds/{t}":True for t in tg} for eid,tg in items[i:i+500]}
    r=jmap([["Email/set",{"accountId":ACCT,"update":upd},"s"]])[0][1]
    done+=len(r.get("updated") or {}); fail+=len(r.get("notUpdated") or {})
    if r.get("notUpdated"): print("notUpdated sample:", list(r["notUpdated"].values())[:2])
print(f"updated {done} messages, failed {fail}")
