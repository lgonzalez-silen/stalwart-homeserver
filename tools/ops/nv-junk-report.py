#!/usr/bin/python3 -I
# nv-junk-report: Junk report. Runs daily from a timer to prune the detail accounts' old Junk; spikes show on the
# dashboard (nv-status), not by mail. --show prints the full report for review.
#   - every account: messages that arrived in Junk in the last 24h, top sender domains, 7-day baseline
#   - SPIKE in the subject when an account's 24h count > max(MIN_SPIKE, 3 x its daily average over the prior 7 days)
#   - junk_report.detail_accounts in site.json (e.g. a forward-only account nobody reads on the server): each Junk
#     message listed with time, sender, subject, score, and their Junk older than KEEP_DAYS is deleted
# Accounts are read live from Stalwart (all except "admin").
# usage: nv-junk-report          timer mode: mail only if there's a spike (also prunes the detail accounts' Junk)
#        nv-junk-report --show   print the full report (incl. the detail accounts' sender/subject list) for review
#        nv-junk-report --dry    print counts only; nothing mailed or deleted
import json, os, sys, subprocess, datetime, collections, urllib.request

sys.path.insert(0, "/usr/local/lib/nv"); sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))  # repo copy last
from nvlib import jmap, upload, mid, message_ids, gmail_folders, site, ADMIN  # noqa: E402
SITE = site()   # installed by recipe/09-ops.sh
CONF = SITE.get("junk_report", {})
KEEP_DAYS = int(CONF.get("keep_days", 30))   # retention for DETAIL accounts' Junk
MIN_SPIKE = 10
DRY = "--dry" in sys.argv
SHOW = "--show" in sys.argv

def iso(d): return d.strftime("%Y-%m-%dT%H:%M:%SZ")
now = datetime.datetime.now(datetime.timezone.utc)
since8 = now - datetime.timedelta(days=8)
day = datetime.timedelta(days=1)

def accounts():
    return {a["id"]: a["name"] for a in jmap([["x:Account/get", {"properties": ["name"]}, "a"]], using=ADMIN)[0][1]["list"]
            if a["name"] != "admin"}
ACCOUNTS = accounts()
DETAIL = {i for i, n in ACCOUNTS.items() if n in CONF.get("detail_accounts", [])}   # Junk listed message by message

lines, spikes, detail = [], [], []
for acct, name in ACCOUNTS.items():
    try:
        mb = jmap([["Mailbox/get", {"accountId": acct, "properties": ["role", "name"]}, "m"]])[0][1]["list"]
        junk = [m["id"] for m in mb if m.get("role") == "junk"] or [m["id"] for m in mb if m["name"].lower() in ("junk", "junk mail")]
        if not junk:
            lines.append(f"{name:8} (no Junk folder)"); continue
        ids = jmap([["Email/query", {"accountId": acct, "filter": {"inMailbox": junk[0], "after": iso(since8)},
                                     "sort": [{"property": "receivedAt", "isAscending": False}], "limit": 5000}, "q"]])[0][1]["ids"]
        msgs = []
        for i in range(0, len(ids), 500):   # Stalwart answers at most 500 objects per get/set (maxObjectsInGet/Set)
            msgs += jmap([["Email/get", {"accountId": acct, "ids": ids[i:i+500],
                                         "properties": ["receivedAt", "from", "subject", "header:X-Spam-Score:asText"]}, "g"]])[0][1]["list"]
    except Exception as e:
        lines.append(f"{name:8} ERROR {e}"); spikes.append(f"{name} (report error)"); continue
    t = lambda m: datetime.datetime.fromisoformat(m["receivedAt"].replace("Z", "+00:00"))
    last = [m for m in msgs if t(m) > now - day]
    prior = [m for m in msgs if now - 8 * day < t(m) <= now - day]
    avg = len(prior) / 7
    dom = collections.Counter(((m.get("from") or [{}])[0].get("email") or "?").rsplit("@", 1)[-1].lower() for m in last)
    top = ", ".join(f"{d} {n}" for d, n in dom.most_common(5))
    flag = len(last) > max(MIN_SPIKE, 3 * avg)
    if flag: spikes.append(name)
    lines.append(f"{name:8} {len(last):4} in 24h   (7-day avg {avg:5.1f}){'   <-- SPIKE' if flag else ''}" + (f"\n         {top}" if top else ""))
    if acct in DETAIL:
        detail.append(f"\n{name} Junk, last 24h (not forwarded; kept {KEEP_DAYS} days on the server):")
        for m in last:
            f = (m.get("from") or [{}])[0]
            score = (m.get("header:X-Spam-Score:asText") or "").strip().split("score=")[-1].split(",")[0]
            detail.append(f"  {t(m):%m-%d %H:%M}Z  {score:>6}  {f.get('email','?')[:45]:45}  {(m.get('subject') or '')[:70]}")
        if not last: detail.append("  (none)")
        old = jmap([["Email/query", {"accountId": acct, "filter": {"inMailbox": junk[0],
                     "before": iso(now - datetime.timedelta(days=KEEP_DAYS))}, "limit": 5000}, "o"]])[0][1]["ids"]
        if old and not (DRY or SHOW):
            for i in range(0, len(old), 500):
                jmap([["Email/set", {"accountId": acct, "destroy": old[i:i+500]}, "d"]])
            detail.append(f"  ({len(old)} older than {KEEP_DAYS} days deleted)")

if DRY:
    for l in lines: print(l.split("\n")[0])
    print("spikes:", spikes or "none"); sys.exit(0)

body = ("Messages filed in Junk per account. Spike = more than max(%d, 3x the 7-day daily average).\n"
        "Move anything legitimate out of Junk: the filter learns from it.\n\n" % MIN_SPIKE
        + "\n".join(lines) + "\n" + "\n".join(detail) + "\n")
if SHOW:
    print(body); sys.exit(0)
# no mail: spikes show on the dashboard (nv-status). The timer run still prunes the detail accounts' old Junk.
sys.exit(0)
