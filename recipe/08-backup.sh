#!/bin/bash
# recipe/08-backup.sh — nightly encrypted backups of the server's DATA to Backblaze B2 with restic.
# Run from your computer:  ./nv run recipe/08-backup.sh
# Settings: alerts.to (address that receives alerts), alerts.from (sender shown on alerts). Alerts are put straight
# into the Inbox of the account that has alerts.to as its address or as an alias; if there is none, this recipe
# creates one (with a random password nobody knows: set your own with nv-set-password to read it in webmail).
# Optional alerts.account: a Stalwart account id to use instead (ids: tools/google/README.md, "account").
#
# Design: two places only (server + B2). Data only, no /etc and no secrets: everything else is
# rebuilt by the recipes. Backed up:
#   - Stalwart's RocksDB (all mail, accounts, settings, DKIM keys): reflink snapshot taken with
#     Stalwart stopped for ~2 s, uploaded afterwards (copying a live RocksDB dir isn't consistent)
#   - Roundcube's SQLite DB (identities, prefs; SMTP passwords inside are encrypted with des_key,
#     which is NOT backed up, so they're unreadable in the backup)
#   - the Google module's state DB (/var/lib/nv-fetch/state.db), if recipe/11 is used
# B2 side (set up once from your computer with the B2 master key): a private bucket with lifecycle
# "hidden files deleted after 30 days"; an application key that is bucket-only with list/read/write but
# NO deleteFiles (restic hides instead of deleting, so an attacker with root on the server can't destroy
# history for 30 days). B2's web form can't make that key ("Read and Write" includes deleteFiles). All of it, and
# /root/.secrets/restic.env on the server, in one command of yours (it reads your password manager; settings
# backup.* in site.json, see the tool's header):
#   ./nv sh tools/b2-setup.sh --dry      then without --dry
# This recipe checks the key's permissions every run and stops if it can do more than list/read/write files.
# Without the restic password (kept in your password manager by the tool) the backups are unreadable.
# By hand instead: restic.env is four lines, mode 0600: RESTIC_REPOSITORY=b2:<bucket>:<path>, RESTIC_PASSWORD,
# B2_ACCOUNT_ID and B2_ACCOUNT_KEY (the key's id and secret).

RESTIC_VER=0.19.1
RESTIC_SIGNER=CF8F18F2844575973F79D4E191A6868BD3F7A907   # restic.net/gpg-key-alex.asc
ALERT_TO=${NV_ALERTS_TO:?set alerts.to in site.json}
ALERT_FROM=${NV_ALERTS_FROM:?set alerts.from in site.json}             # sender shown on every alert (backups, failures, Junk spikes)
HOST=$NV_SERVER_HOSTNAME

echo "== restic $RESTIC_VER (signature-verified release binary)"
if ! restic version 2>/dev/null | grep -q "restic $RESTIC_VER "; then
  dnf -y -q install bzip2
  mkdir -p /root/installs/restic && cd /root/installs/restic
  for f in restic_${RESTIC_VER}_linux_amd64.bz2 SHA256SUMS SHA256SUMS.asc; do
    [ -f $f ] || curl -sSfLO https://github.com/restic/restic/releases/download/v$RESTIC_VER/$f
  done
  export GNUPGHOME=/root/.gnupg-restic; mkdir -p -m 700 $GNUPGHOME
  gpg -q --list-keys $RESTIC_SIGNER >/dev/null 2>&1 || curl -sSfL https://restic.net/gpg-key-alex.asc | gpg -q --import
  gpg --status-fd 1 --verify SHA256SUMS.asc SHA256SUMS 2>/dev/null | grep VALIDSIG | grep -q $RESTIC_SIGNER \
    || { echo "restic SIGNATURE CHECK FAILED"; exit 1; }
  grep " restic_${RESTIC_VER}_linux_amd64.bz2$" SHA256SUMS | sha256sum -c --quiet
  bunzip2 -kf restic_${RESTIC_VER}_linux_amd64.bz2
  install -m 755 restic_${RESTIC_VER}_linux_amd64 /usr/local/bin/restic
fi
restic version

live && { [ -s /root/.secrets/restic.env ] || { echo "missing /root/.secrets/restic.env (see header)"; exit 1; }; }

echo "== alerts account (owner of $ALERT_TO)"
if live; then
  ALERT_ACCOUNT=$(ALERT_TO="$ALERT_TO" ALERT_ACCOUNT="${NV_ALERTS_ACCOUNT:-}" python3 -I - <<'PY'
import json, os, secrets, subprocess, sys, urllib.request
K = open("/root/.secrets/laptop-api.key").read().strip()
def j(calls):
    r = urllib.request.Request("http://127.0.0.1:8080/jmap/", data=json.dumps({"using": ["urn:ietf:params:jmap:core",
        "urn:stalwart:jmap"], "methodCalls": calls}).encode(), headers={"Authorization": "Bearer " + K, "Content-Type": "application/json"})
    out = json.load(urllib.request.urlopen(r, timeout=30))["methodResponses"]
    if out[0][0] == "error" or out[0][1].get("notCreated"):
        sys.exit(f"Stalwart refused: {json.dumps(out[0][1])[:300]}")
    return out[0][1]
to, want = os.environ["ALERT_TO"].lower(), os.environ["ALERT_ACCOUNT"]
doms = {d["id"]: d["name"].lower() for d in j([["x:Domain/get", {"ids": None, "properties": ["name"]}, "d"]])["list"]}
accts = j([["x:Account/get", {"ids": None, "properties": ["name", "domainId", "emailAddress", "aliases"]}, "a"]])["list"]
def own(a):   # every address the account receives: name@domain, its email address, its enabled aliases
    s = {f'{a["name"]}@{doms.get(a.get("domainId"), "")}'.lower(), (a.get("emailAddress") or "").lower()}
    return s | {f'{x["name"]}@{doms.get(x["domainId"], "")}'.lower() for x in (a.get("aliases") or {}).values() if x.get("enable", True)}
if want:   # set in site.json: use it, but say so if it doesn't own the address
    a = next((a for a in accts if a["id"] == want), None) or sys.exit(f"alerts.account {want}: no such account")
    note = "" if to in own(a) else f" (WARNING: it doesn't have {to} as an address: alerts go to {a['name']})"
    print(f"using alerts.account {want} ({a['name']}){note}", file=sys.stderr); print(want); sys.exit()
hits = [a for a in accts if to in own(a)]
if len(hits) > 1:
    sys.exit(f"{to} belongs to several accounts ({', '.join(a['name'] for a in hits)}): set alerts.account")
if hits:
    print(f"{to}: account {hits[0]['id']} ({hits[0]['name']})", file=sys.stderr); print(hits[0]["id"]); sys.exit()
local, _, dom = to.partition("@")
did = next((i for i, n in doms.items() if n == dom), None) or sys.exit(f"{dom} isn't a domain in Stalwart: add it, or change alerts.to")
# a random password nobody knows (as a hash, like nv-set-password stores): the account has the credential that
# nv-set-password replaces when you want to read it in webmail
pw = subprocess.run(["openssl", "passwd", "-6", "-stdin"], input=secrets.token_urlsafe(32).encode(), capture_output=True, check=True).stdout.decode().strip()
new = j([["x:Account/set", {"create": {"n": {"@type": "User", "name": local, "domainId": did, "description": "alerts (recipe/08)",
          "credentials": {"0": {"@type": "Password", "secret": pw}}}}}, "c"]])["created"]["n"]["id"]
print(f"{to}: created account {new} (random password; nv-set-password {local} to read it in webmail)", file=sys.stderr)
print(new)
PY
) || exit 1
else
  ALERT_ACCOUNT="<secret:alerts.account>"   # looked up on the server; ./nv diff matches it like a secret
fi
install -d -m 700 /var/backups/nv /var/cache/restic

echo "== scripts"
put /usr/local/sbin/nv-alert 700 <<EOF
#!/usr/bin/python3 -I
# nv-alert <subject> : put stdin as a message straight into the admin's Inbox via Stalwart's JMAP API
# (Email/import skips the spam filter: short machine-written alerts scored ~6 and risked landing in Junk).
# Falls back to plain SMTP on port 25 if the API call fails.
import sys, json, time, os, subprocess, urllib.request, email.utils
TO, FROM, ACCT = "$ALERT_TO", "$ALERT_FROM", "$ALERT_ACCOUNT"
subj = "[nv] " + (sys.argv[1] if len(sys.argv) > 1 else "alert")
msg = (f"From: nv alerts <{FROM}>\r\nTo: {TO}\r\nSubject: {subj}\r\nDate: {email.utils.formatdate()}\r\n"
       f"Message-ID: <{int(time.time())}.{os.getpid()}@$HOST>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n"
       + sys.stdin.read().replace("\r\n", "\n").replace("\n", "\r\n")).encode()
try:
    K = open("/root/.secrets/laptop-api.key").read().strip(); B = "http://127.0.0.1:8080"
    H = {"Authorization": "Bearer " + K}
    def j(calls):
        r = urllib.request.Request(B + "/jmap/", data=json.dumps({"using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"], "methodCalls": calls}).encode(), headers={**H, "Content-Type": "application/json"})
        return json.load(urllib.request.urlopen(r, timeout=30))["methodResponses"]
    inbox = [m["id"] for m in j([["Mailbox/get", {"accountId": ACCT, "properties": ["role"]}, "m"]])[0][1]["list"] if m.get("role") == "inbox"][0]
    blob = json.load(urllib.request.urlopen(urllib.request.Request(f"{B}/jmap/upload/{ACCT}/", data=msg, headers={**H, "Content-Type": "message/rfc822"}), timeout=30))["blobId"]
    r = j([["Email/import", {"accountId": ACCT, "emails": {"a": {"blobId": blob, "mailboxIds": {inbox: True}}}}, "i"]])[0][1]
    if "a" not in (r.get("created") or {}): raise RuntimeError(r)
except Exception as e:
    print("nv-alert: API import failed (%s), sending by SMTP" % e, file=sys.stderr)
    subprocess.run(["curl", "-s", "--url", "smtp://127.0.0.1:25/$HOST", "--mail-from", FROM, "--mail-rcpt", TO, "-T", "-"], input=msg, check=True)
EOF

put /usr/local/sbin/nv-backup 700 <<'EOF'
#!/bin/bash
# Nightly: consistent Stalwart snapshot + Roundcube DB -> restic (B2). Weekly prune on Sundays.
set -euo pipefail
set -a; . /root/.secrets/restic.env; set +a
export RESTIC_CACHE_DIR=/var/cache/restic
SNAP=/var/lib/stalwart-snap
rm -rf "$SNAP"
trap 'systemctl start stalwart' EXIT            # never leave Stalwart stopped
# the Google module's state (where each pull stopped, what was mirrored/trimmed): without it a restored server
# would start pulling "from now" and skip mail that arrived after the backup. Copied BEFORE the mail snapshot: a state
# slightly older than the mail is harmless (Message-IDs catch the overlap); a newer one would claim mail the backup lacks.
EXTRA=(); STATE_FAILED=
if [ -f /var/lib/nv-fetch/state.db ]; then
  if sqlite3 /var/lib/nv-fetch/state.db ".timeout 30000" ".backup /var/backups/nv/nv-fetch-state.db"; then
    EXTRA=(/var/backups/nv/nv-fetch-state.db)
  else STATE_FAILED=1; fi
fi
t0=$(date +%s.%N)
systemctl stop stalwart
cp -a --reflink=always /var/lib/stalwart "$SNAP"
systemctl start stalwart
trap - EXIT
echo "stalwart snapshot: $(echo "$(date +%s.%N) - $t0" | bc) s of downtime"
sqlite3 /var/lib/roundcube/roundcube.db ".backup /var/backups/nv/roundcube.db"
restic backup --host nv --tag nightly --no-scan "$SNAP" /var/backups/nv/roundcube.db "${EXTRA[@]}"
rm -rf "$SNAP"
date -u +%Y-%m-%dT%H:%M:%SZ > /var/backups/nv/last-backup-ok   # for the dashboard (survives reboots; systemd's record doesn't)
# everything else is backed up; fail the run (-> alert) so a missing Google state never goes unnoticed
[ -z "$STATE_FAILED" ] || { echo "could not copy /var/lib/nv-fetch/state.db: tonight's backup lacks the Google state"; exit 1; }
if [ "$(date +%u)" = 7 ] || [ "${1:-}" = --prune ]; then
  restic forget --host nv --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
fi
EOF

put /usr/local/sbin/nv-backup-check 700 <<'EOF'
#!/bin/bash
# Monthly: verify repository structure + re-download and verify 10% of the data; mail only if it finds a problem.
set -uo pipefail
set -a; . /root/.secrets/restic.env; set +a
export RESTIC_CACHE_DIR=/var/cache/restic
out=$(mktemp); rc=0
{ echo "== snapshots"; restic snapshots --host nv --compact | tail -n 8
  echo; echo "== repository size"; restic stats --mode raw-data | grep -E "Total Size|Total Blob|Snapshots"
  echo; echo "== check (structure + 10% of data re-downloaded)"; } >"$out" 2>&1
restic check --read-data-subset=10% >>"$out" 2>&1 || rc=$?
status=$([ $rc = 0 ] && echo OK || echo "FAILED (exit $rc)")
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $status" > /var/backups/nv/last-check   # for the dashboard
# mail only when something is wrong; a good check shows on the dashboard (nv-status)
[ $rc = 0 ] || nv-alert "monthly backup check: $status" <"$out"
rm -f "$out"; exit $rc
EOF
chmod 700 /usr/local/sbin/nv-backup /usr/local/sbin/nv-backup-check /usr/local/sbin/nv-alert
dnf -y -q install bc sqlite

echo "== systemd units"
put /etc/systemd/system/nv-alert@.service <<'EOF'
[Unit]
Description=Mail an alert about failed unit %i

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'journalctl -u %i -n 40 --no-pager -o cat | /usr/local/sbin/nv-alert "FAILED: %i"'
EOF
put /etc/systemd/system/nv-backup.service <<'EOF'
[Unit]
Description=Nightly restic backup to B2
After=network-online.target stalwart.service
Wants=network-online.target
OnFailure=nv-alert@%n.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nv-backup
Nice=10
IOSchedulingClass=idle
EOF
put /etc/systemd/system/nv-backup.timer <<'EOF'
[Unit]
Description=Nightly restic backup to B2

[Timer]
OnCalendar=*-*-* 03:15 UTC
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
EOF
put /etc/systemd/system/nv-backup-check.service <<'EOF'
[Unit]
Description=Monthly restic check (mails a report)
After=network-online.target
Wants=network-online.target
OnFailure=nv-alert@%n.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nv-backup-check
Nice=10
EOF
put /etc/systemd/system/nv-backup-check.timer <<'EOF'
[Unit]
Description=Monthly restic check

[Timer]
OnCalendar=*-*-01 05:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable -q --now nv-backup.timer nv-backup-check.timer

echo "== repository"
if live; then
  set -a; . /root/.secrets/restic.env; set +a
  export RESTIC_CACHE_DIR=/var/cache/restic
  # the key must not be able to delete (see header): B2's sign-in answer lists what it may do
  # (the key goes to curl as a header file, never on its command line, where every local user could see it in ps)
  B2AUTH=$(curl -s -H @<(printf 'Authorization: Basic %s\n' "$(printf '%s:%s' "$B2_ACCOUNT_ID" "$B2_ACCOUNT_KEY" | base64 -w0)") \
    https://api.backblazeb2.com/b2api/v3/b2_authorize_account)
  caps=$(jq -r '.apiInfo.storageApi.capabilities // empty | join(",")' <<<"$B2AUTH")
  # ...and must be limited to this repository's bucket (a key for all buckets passes the permission check otherwise)
  kbucket=$(jq -r '.apiInfo.storageApi.bucketName // empty' <<<"$B2AUTH"); rbucket=$(cut -d: -f2 <<<"$RESTIC_REPOSITORY")
  if [ -n "$caps" ] && [ "$kbucket" != "$rbucket" ]; then
    echo "the B2 key isn't limited to the bucket $rbucket (it is limited to: ${kbucket:-no bucket, all of them}): make a new one (see header)"; exit 1
  fi
  case ",$caps," in
    ,,) echo "couldn't read the B2 key's permissions (wrong key in restic.env, or B2 unreachable)"; exit 1 ;;
    *) # only list/read permissions plus writeFiles: anything else (deleteFiles, writeBuckets = lifecycle rules,
       # retention, bypassGovernance, ...) lets whoever holds the key destroy the history
       # (grep finds nothing for a good key and exits 1: that's success here, not an error for set -e)
       extra=$(tr ',' '\n' <<<"$caps" | { grep -vxE 'writeFiles|list[A-Za-z]*|read[A-Za-z]*' || true; } | paste -sd, -)
       if [ -n "$extra" ]; then
         echo "the B2 key can do more than list/read/write files ($extra): make a new one (see header)"; exit 1
       fi
       echo "B2 key permissions: $caps (can't delete or change the bucket: good)" ;;
  esac
  # ...and the bucket must keep what restic hides for 30 days (the window in which a wrecked history can be undone),
  # never hide files on its own, and be private. Read with the same key (listBuckets).
  bucket=$(jq -r '{accountId, bucketId: .apiInfo.storageApi.bucketId} | @json' <<<"$B2AUTH" | curl -s -X POST \
      -H @<(printf 'Authorization: %s\n' "$(jq -r .authorizationToken <<<"$B2AUTH")") --data-binary @- \
      "$(jq -r .apiInfo.storageApi.apiUrl <<<"$B2AUTH")/b2api/v3/b2_list_buckets" | jq -c '.buckets[0] // empty')
  unset B2AUTH
  [ -n "$bucket" ] || { echo "couldn't read the B2 bucket's settings (the key must be limited to the backup bucket)"; exit 1; }
  jq -e '.bucketType == "allPrivate"' <<<"$bucket" >/dev/null || { echo "the B2 bucket isn't private: make it private"; exit 1; }
  if jq -e '[.lifecycleRules[] | select(.daysFromUploadingToHiding != null)] | length > 0' <<<"$bucket" >/dev/null; then
    echo "the B2 bucket has a lifecycle rule that hides files by age (daysFromUploadingToHiding): it would delete live backups"; exit 1
  fi
  if jq -e '[.lifecycleRules[] | select(.daysFromHidingToDeleting != null and .daysFromHidingToDeleting < 30)] | length > 0' <<<"$bucket" >/dev/null; then
    echo "the B2 bucket deletes hidden files after less than 30 days (B2's \"keep only the last version\" is 1 day): set it to 30 (see header)"; exit 1
  fi
  if jq -e '[.lifecycleRules[] | select(.fileNamePrefix == "" and .daysFromHidingToDeleting >= 30)] | length > 0' <<<"$bucket" >/dev/null; then
    echo "B2 bucket: private, hidden files kept $(jq -r '[.lifecycleRules[] | select(.fileNamePrefix == "") | .daysFromHidingToDeleting] | min' <<<"$bucket") days: good"
  else
    echo "note: the B2 bucket has no rule deleting hidden files, so they're kept forever (safe, but they cost storage): see header"
  fi
  restic cat config >/dev/null 2>&1 || restic init
fi
systemctl list-timers 'nv-backup*' --no-pager | head -4
