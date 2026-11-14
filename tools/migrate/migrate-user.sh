#!/bin/bash
# migrate-user.sh <old-user> <login> <account-id> [folder-prefix]      (run on the server as root; see README.md)
#   mbox files in /var/lib/migrate/<old-user>/ (mail/ = folders, spool-INBOX = inbox)
#   -> Maildir++ (mbox2maildir.py) -> Vandelay archive -> the Stalwart account -> per-folder counts (cmpacct.py)
#   -> missing second-folder memberships restored (vandelay-fix-folders.py)
# <login>: the account's login (alice, or alice@example.org outside the default domain). Its password is asked once
# (no echo) and used for the export; it is never written to disk except a 0600 temp file removed at the end.
# folder-prefix (e.g. archive/old-accounts/bob): put the whole mailbox, inbox included, under that folder.
set -euo pipefail
u=$1; login=$2; acct=$3; prefix=${4:-}
HERE=$(cd "$(dirname "$0")" && pwd)
HOST=$(python3 -c 'import json; print(json.load(open("/etc/nv/site.json"))["server"]["hostname"])')
src=/var/lib/migrate/$u
[ -d "$src" ] || { echo "no $src"; exit 1; }
W=$(mktemp -d /var/lib/migrate/work-XXXXXX); PWF=$W/pw; trap 'rm -f "$PWF"' EXIT
read -rsp "password for $login: " pw; echo; umask 077; printf '%s' "$pw" > "$PWF"; export VANDELAY_PASSWORD=$pw; unset pw
mkdir -p "$W/mail/$prefix"
[ -d "$src/mail" ] && cp -a --reflink=auto "$src/mail/." "$W/mail/$prefix/"
MD="--mail-dir $W/mail"
if [ -f "$src/spool-INBOX" ]; then
  if [ -n "$prefix" ]; then
    [ -e "$W/mail/$prefix/INBOX" ] && { echo "both mail/INBOX and spool-INBOX exist: merge them first"; exit 1; }
    cp --reflink=auto "$src/spool-INBOX" "$W/mail/$prefix/INBOX"
  else MD="$MD --spool $src/spool-INBOX"; fi
fi
python3 -I "$HERE/mbox2maildir.py" $MD --out "$W/maildir" | tail -1
AUTOMAP=""; [ -n "$prefix" ] && AUTOMAP=--noautomap   # else Vandelay merges inner Sent/Trash/... into the account's own
vandelay import maildir $AUTOMAP "$W/maildir" "$W/archive.sqlite" > "$W/import.log" 2>&1 || { tail -20 "$W/import.log"; exit 1; }
grep -E "^email:" "$W/import.log" | tail -1 || true
vandelay export --url "https://$HOST" --auth-basic "$login" --account-id "$acct" "$W/archive.sqlite" > "$W/export.log" 2>&1 || { tail -20 "$W/export.log"; exit 1; }
grep -iE "^(mailbox|email):|error|warn" "$W/export.log" | tail -5 || true
echo "(full logs: $W/import.log, $W/export.log)"
FIXP=(); [ -n "$prefix" ] && FIXP=(--prefix "$prefix")
python3 -I "$HERE/vandelay-fix-folders.py" "$login" "$acct" "$W/archive.sqlite" "$PWF" "${FIXP[@]}" --dry-run
read -rp "add those folder memberships? Type yes: " ok; [ "$ok" = yes ] && \
  python3 -I "$HERE/vandelay-fix-folders.py" "$login" "$acct" "$W/archive.sqlite" "$PWF" "${FIXP[@]}"
python3 -I "$HERE/cmpacct.py" "$acct" "$W/maildir/manifest.tsv" ${prefix:+--only-manifest}
rm -rf "$W/maildir"; echo "archive kept: $W/archive.sqlite (delete when you're happy with the result)"
