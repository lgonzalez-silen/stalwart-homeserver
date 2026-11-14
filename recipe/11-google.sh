#!/bin/bash
# recipe/11-google.sh — optional: pull mail from Google accounts (Gmail, Google Workspace) into Stalwart.
# Run from your computer:  ./nv run recipe/11-google.sh     (after recipe/09, which installs /etc/nv/site.json)
# Then, once per source, store its Google app password (typed without echo, tested with a real IMAP login):
#   ssh -t root@<server.hostname> nv-fetch-secret <name>
# Settings: google.sources[] (see tools/google/README.md), each with
#   name         short id, e.g. gmail-alice (state and the password file use it)
#   user         the Google login
#   account      Stalwart account id the mail goes to
#   own          (optional) that person's own addresses: mail from them is imported as already read
#   enabled      (optional, default true) false stops the pull for this source
#   spam_mirror  (optional, default true) show this account's Google Spam in the "Google Spam" folder
#   keep_days    (optional) trim: move mail older than this to the account's Trash, only when it is on the server
# Installs: nv-fetch (service, always on), nv-spam-mirror (every 5 min), nv-google-trim (weekly, only if a source
# has keep_days), nv-fetch-secret.

[ "${NV_GOOGLE_SOURCES_COUNT:-0}" -gt 0 ] || { echo "no google.sources in site.json: nothing to do"; exit 0; }
live && { [ -s /etc/nv/site.json ] || { echo "run recipe/09-ops.sh first (installs /etc/nv/site.json)"; exit 1; }; }
TRIM=no
for ((i = 0; i < NV_GOOGLE_SOURCES_COUNT; i++)); do k=NV_GOOGLE_SOURCES_${i}_KEEP_DAYS; [ -n "${!k:-}" ] && TRIM=yes; done

echo "== tools"
install -d -m 700 /var/lib/nv-fetch /root/.secrets/fetch
repo_file tools/google/nv-fetch.py | put /usr/local/sbin/nv-fetch 700
repo_file tools/google/nv-fetch-secret.py | put /usr/local/sbin/nv-fetch-secret 700
repo_file tools/google/nv-spam-mirror.py | put /usr/local/sbin/nv-spam-mirror 700
repo_file tools/google/nv-google-trim.py | put /usr/local/sbin/nv-google-trim 700

echo "== units"
repo_file tools/google/nv-fetch.service | put /etc/systemd/system/nv-fetch.service
repo_file tools/google/nv-spam-mirror.service | put /etc/systemd/system/nv-spam-mirror.service
repo_file tools/google/nv-spam-mirror.timer | put /etc/systemd/system/nv-spam-mirror.timer
repo_file tools/google/nv-google-trim.service | put /etc/systemd/system/nv-google-trim.service
repo_file tools/google/nv-google-trim.timer | put /etc/systemd/system/nv-google-trim.timer
systemctl daemon-reload
systemctl enable -q nv-fetch.service
systemctl restart nv-fetch.service              # long-running: restart so it runs the code just installed
systemctl enable -q --now nv-spam-mirror.timer
if [ $TRIM = yes ]; then systemctl enable -q --now nv-google-trim.timer; else systemctl disable -q --now nv-google-trim.timer 2>/dev/null || true; fi

echo "== status"
systemctl is-active nv-fetch.service
run /usr/local/sbin/nv-fetch --status
systemctl list-timers 'nv-spam-mirror*' 'nv-google-trim*' --no-pager | head -4
