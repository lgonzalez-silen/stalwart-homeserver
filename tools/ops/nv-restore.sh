#!/bin/bash
# nv-restore: put a backup back on this server (installed by recipe/08; the whole procedure: docs/restore.md).
#   nv-restore               list the snapshots: pick one BY ITS ID (its date and size must be the old server's)
#   nv-restore <snapshot-id> stop the backups and the services using the data, restore that snapshot (Stalwart's data,
#                            Roundcube's database, the Google module's state if it was backed up), start Stalwart and
#                            webmail again. The data it replaces is kept in /var/lib/stalwart-empty. Backups and the
#                            Google module stay stopped until you've checked the result.
#   nv-restore --done        after checking webmail: start the backups and the Google module again, and delete the
#                            replaced data and the restore's scratch copy.
set -euo pipefail
ENVF=/root/.secrets/restic.env
SCRATCH=/var/tmp/nv-restore
OLD=/var/lib/stalwart-empty
GOOGLE=(nv-fetch.service nv-spam-mirror.timer nv-google-trim.timer)
has() { systemctl cat "$1" >/dev/null 2>&1; }

[ -s $ENVF ] || { echo "no $ENVF: run tools/b2-setup.sh and recipe/08 first (docs/restore.md, step 3)"; exit 1; }
set -a; . $ENVF; set +a
export RESTIC_CACHE_DIR=/var/cache/restic

case ${1:-} in
  "")
    restic snapshots --compact
    echo; echo "Pick one by its ID (check that its date and size are the old server's), then: nv-restore <ID>"
    exit 0 ;;
  --done)
    systemctl start nv-backup.timer
    for u in "${GOOGLE[@]}"; do has "$u" && systemctl start "$u"; done
    rm -rf /var/tmp/nv-restore /var/lib/stalwart-empty
    echo "backups (and the Google module, if installed) running again; replaced data and scratch copy deleted"
    systemctl list-timers 'nv-backup*' --no-pager
    exit 0 ;;
  -*) sed -n '2,10p' "$0"; exit 1 ;;
esac
ID=$1

# the snapshot must exist, and no earlier restore may be half-done
snap=$(restic snapshots --json "$ID" 2>/dev/null) || true
[ "$(jq 'length' <<<"${snap:-[]}" 2>/dev/null)" = 1 ] || { echo "no snapshot $ID: run nv-restore to list them"; exit 1; }
jq -r '.[0] | "snapshot \(.short_id): \(.time[:19]) UTC, host \(.hostname), \(.paths | join(" "))"' <<<"$snap"
for p in $OLD $SCRATCH; do
  [ ! -e "$p" ] || { echo "$p is still there from an earlier restore: check it, then nv-restore --done (deletes it)"; exit 1; }
done

trap 'echo "nv-restore stopped (line $LINENO). Stalwart, webmail and backups may be stopped; see docs/restore.md"' ERR
echo "== stopping the backups, the Google module, Stalwart and webmail"
systemctl stop nv-backup.timer nv-backup.service
for u in "${GOOGLE[@]}"; do has "$u" && systemctl stop "$u"; done
systemctl stop stalwart php-fpm

echo "== restoring $ID into $SCRATCH"
restic restore "$ID" --target $SCRATCH
[ -d $SCRATCH/var/lib/stalwart-snap ] || { echo "the snapshot has no /var/lib/stalwart-snap: not one of this setup's backups"; exit 1; }

echo "== putting it in place (the replaced data goes to $OLD)"
mv /var/lib/stalwart $OLD
mv $SCRATCH/var/lib/stalwart-snap /var/lib/stalwart
chown -R stalwart:stalwart /var/lib/stalwart
if [ -f $SCRATCH/var/backups/nv/roundcube.db ]; then
  rm -f /var/lib/roundcube/roundcube.db-wal /var/lib/roundcube/roundcube.db-shm   # the fresh DB's journal, not ours
  install -o nginx -g nginx -m 640 $SCRATCH/var/backups/nv/roundcube.db /var/lib/roundcube/roundcube.db
fi
if [ -f $SCRATCH/var/backups/nv/nv-fetch-state.db ]; then   # where each Google pull stopped: mail since the backup is still fetched
  if [ -d /var/lib/nv-fetch ]; then
    install -m 600 $SCRATCH/var/backups/nv/nv-fetch-state.db /var/lib/nv-fetch/state.db
  else
    echo "NOTE: the backup has the Google module's state, but the module isn't installed: run recipe/11, then on the server"
    echo "      install -m 600 $SCRATCH/var/backups/nv/nv-fetch-state.db /var/lib/nv-fetch/state.db   (before nv-restore --done)"
  fi
fi
restorecon -R /var/lib/stalwart /var/lib/roundcube
[ -d /var/lib/nv-fetch ] && restorecon -R /var/lib/nv-fetch

echo "== starting Stalwart and webmail"
systemctl start stalwart php-fpm
systemctl is-active stalwart php-fpm
trap - ERR
cat <<EOF

Restored $ID. Next (docs/restore.md, step 5 on): make the tools' API key again from your computer, log in to webmail,
send and receive a test message, open a few old folders. Then: nv-restore --done (backups start again).
EOF
