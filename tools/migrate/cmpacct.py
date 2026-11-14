# Per-folder count comparison: Stalwart account (via admin key) vs the converter's manifest / inventory. Counts only.
import json, csv, sys, urllib.request
acct, manifest = sys.argv[1], sys.argv[2]
K=open("/root/.secrets/laptop-api.key").read().strip()
def call(calls):
    r=urllib.request.Request("http://127.0.0.1:8080/jmap/", data=json.dumps({"using":["urn:ietf:params:jmap:core","urn:ietf:params:jmap:mail"],"methodCalls":calls}).encode(), headers={"Authorization":"Bearer "+K,"Content-Type":"application/json"})
    return json.load(urllib.request.urlopen(r))["methodResponses"]
m=call([["Mailbox/get",{"accountId":acct,"properties":["name","parentId","role","totalEmails"]},"m"],["Email/query",{"accountId":acct,"calculateTotal":True,"limit":1},"q"]])
mb=m[0][1]["list"]; byid={x["id"]:x for x in mb}
def path(x):
    p=[x["name"]]
    while x.get("parentId"): x=byid[x["parentId"]]; p.append(x["name"])
    return "/".join(reversed(p)).replace("․",".")
ROLE={"inbox":"INBOX","sent":"Sent","trash":"Trash","junk":"Junk","drafts":"Drafts"}
got={}
for x in mb:
    k=ROLE.get(x.get("role"), path(x)); got[k]=got.get(k,0)+x["totalEmails"]
exp={}
for r in csv.DictReader(open(manifest),delimiter="\t"): exp[r["folder"]]=int(r["messages"])-int(r["deleted_skipped"])
print("emails in account:", m[1][1].get("total"), "| sum of folder totals:", sum(got.values()), "| expected:", sum(exp.values()))
ONLY="--only-manifest" in sys.argv
keys=sorted(set(exp)) if ONLY else sorted(set(exp)|set(got))
if ONLY: print("manifest folders total:", sum(exp.values()), "| same folders in account:", sum(got.get(k,0) for k in exp))
diff=[(k,exp.get(k),got.get(k)) for k in keys if exp.get(k)!=got.get(k) and not (exp.get(k) is None and got.get(k)==0)]
print("folders differing:", len(diff))
for d in diff: print("  %-45s expected %s got %s" % d)
