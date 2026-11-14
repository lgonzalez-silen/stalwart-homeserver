#!/bin/bash
# recipe/07b-roundcube-skin.sh — optional: the Elastic Compact skin + its plugins (repo roundcube-elastic-compact)
# Run from your computer, after recipe/07 and after every Roundcube upgrade:
#   ./nv sh recipe/07b-roundcube-skin.sh
# Settings: webmail.compact_skin_source = your checkout of roundcube-elastic-compact on this computer.
# Also add "elastic_compact" and "login_refresh" to webmail.local_plugins and "elastic_compact" to
# webmail.local_skins, then re-run recipe/07: it enables the plugins and carries all three over on upgrades.
# Users pick the skin in Settings > Preferences > User Interface > Interface skin (the default stays elastic).
set -euo pipefail
SRC=${NV_WEBMAIL_COMPACT_SKIN_SOURCE:?set webmail.compact_skin_source in site.json}; SRC=${SRC/#\~/$HOME}
HOST=$NV_SERVER_HOSTNAME
WEBMAIL=${NV_WEBMAIL_HOSTNAME:-rc.$HOST}
[ -x "$SRC/install.sh" ] && [ -x "$SRC/build.sh" ] || { echo "no build.sh/install.sh in $SRC"; exit 1; }

echo "== build the CSS against the server's Roundcube (changes styles.min.css only if Elastic changed: commit it)"
"$SRC/build.sh" "root@$HOST:/var/www/roundcube"

echo "== install on the server"
COPYFILE_DISABLE=1 tar --no-xattrs -C "$SRC" --exclude .git --exclude .DS_Store -cf - . | ssh "root@$HOST" '
  set -e; T=$(mktemp -d); trap "rm -rf -- \"$T\"" EXIT
  tar -C "$T" -xf -; bash "$T/install.sh" /var/www/roundcube'
ssh "root@$HOST" "curl -s -o /dev/null -w 'skin css via nginx: %{http_code}\n' --resolve $WEBMAIL:443:127.0.0.1 https://$WEBMAIL/static.php/skins/elastic_compact/styles/styles.min.css"
