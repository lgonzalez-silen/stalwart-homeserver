#!/bin/bash
# recipe/08-backup.sh — nightly encrypted backups of the server's DATA to Backblaze B2 with restic.
# Run from your computer:  ./nv run recipe/08-backup.sh
# Settings: alerts.to (address that receives alerts), alerts.from (sender shown on alerts),
# alerts.account (Stalwart account id that owns alerts.to; alerts are put straight into its Inbox).
#
# Design: two places only (server + B2). Data only, no /etc and no secrets: everything else is
# rebuilt by the recipes. Backed up:
#   - Stalwart's RocksDB (all mail, accounts, settings, DKIM keys): reflink snapshot taken with
#     Stalwart stopped for ~2 s, uploaded afterwards (copying a live RocksDB dir isn't consistent)
#   - Roundcube's SQLite DB (identities, prefs; SMTP passwords inside are encrypted with des_key,
#     which is NOT backed up, so they're unreadable in the backup)
# B2 side (set up once from your computer with the B2 master key): a private bucket with lifecycle
# "hidden files deleted after 30 days"; an application key that is bucket-only with list/read/write but
# NO deleteFiles (restic hides instead of deleting, so an attacker with root on the server can't destroy
# history for 30 days). Test it: overwrite keeps the old version, delete -> 401.
# Secrets: /root/.secrets/restic.env (RESTIC_REPOSITORY, RESTIC_PASSWORD, B2_ACCOUNT_ID/KEY), mode 0600;
# keep a copy in your password manager. Without RESTIC_PASSWORD the backups are unreadable.

RESTIC_VER=0.19.1
RESTIC_SIGNER=CF8F18F2844575973F79D4E191A6868BD3F7A907   # restic.net/gpg-key-alex.asc
ALERT_ACCOUNT=${NV_ALERTS_ACCOUNT:?set alerts.account in site.json}   # Stalwart account id of ALERT_TO
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
t0=$(date +%s.%N)
systemctl stop stalwart
cp -a --reflink=always /var/lib/stalwart "$SNAP"
systemctl start stalwart
trap - EXIT
echo "stalwart snapshot: $(echo "$(date +%s.%N) - $t0" | bc) s of downtime"
sqlite3 /var/lib/roundcube/roundcube.db ".backup /var/backups/nv/roundcube.db"
restic backup --host nv --tag nightly --no-scan "$SNAP" /var/backups/nv/roundcube.db
rm -rf "$SNAP"
if [ "$(date +%u)" = 7 ] || [ "${1:-}" = --prune ]; then
  restic forget --host nv --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
fi
EOF

put /usr/local/sbin/nv-backup-check 700 <<'EOF'
#!/bin/bash
# Monthly: verify repository structure + re-download and verify 10% of the data; mail a report either way.
set -uo pipefail
set -a; . /root/.secrets/restic.env; set +a
export RESTIC_CACHE_DIR=/var/cache/restic
out=$(mktemp); rc=0
{ echo "== snapshots"; restic snapshots --host nv --compact | tail -n 8
  echo; echo "== repository size"; restic stats --mode raw-data | grep -E "Total Size|Total Blob|Snapshots"
  echo; echo "== check (structure + 10% of data re-downloaded)"; } >"$out" 2>&1
restic check --read-data-subset=10% >>"$out" 2>&1 || rc=$?
status=$([ $rc = 0 ] && echo OK || echo "FAILED (exit $rc)")
nv-alert "monthly backup check: $status" <"$out"
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
  restic cat config >/dev/null 2>&1 || restic init
fi
systemctl list-timers 'nv-backup*' --no-pager | head -4
