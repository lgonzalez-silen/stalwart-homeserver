#!/bin/bash
# tools/publish-sites.sh — push each static site's files to the server (run on your computer):
#   ./nv sh tools/publish-sites.sh [site ...]      (default: every site in websites[])
# Source: websites[].source (a folder with index.html at the top; edit there, re-run to publish).
# The upload replaces the site in one step (new folder, then swap), so visitors never see half a site.
# Then run recipe/10-websites.sh for the nginx config (only needed when sites are added or removed).
set -euo pipefail
NV=root@$NV_SERVER_HOSTNAME
want=" $* "
for ((i = 0; i < ${NV_WEBSITES_COUNT:-0}; i++)); do
  n=NV_WEBSITES_${i}_NAME; s=NV_WEBSITES_${i}_SOURCE; site=${!n}; src=${!s/#\~/$HOME}
  [ $# -eq 0 ] || [[ $want == *" $site "* ]] || continue
  [ -f "$src/index.html" ] || { echo "missing $src/index.html"; exit 1; }
  echo "== content $site ($(find "$src" -type f | wc -l | tr -d ' ') files)"
  # never publish server-side code: nginx would serve it as plain text
  if find "$src" \( -name '*.php' -o -name '.htaccess' -o -name '.htpasswd' \) | grep -q .; then
    echo "refusing: $site has .php/.htaccess files"; exit 1
  fi
  COPYFILE_DISABLE=1 tar --no-xattrs -C "$src" --exclude .DS_Store -cf - . | ssh "$NV" "
    set -e; D=/var/www/sites/$site
    mkdir -p /var/www/sites; test -n '$site'
    rm -rf \$D.new; mkdir \$D.new; tar -C \$D.new -xf - --no-same-owner
    chown -R root:root \$D.new; chmod -R u=rwX,go=rX \$D.new
    rm -rf \$D.old; [ -d \$D ] && mv \$D \$D.old; mv \$D.new \$D; rm -rf \$D.old
    restorecon -R \$D 2>/dev/null || true"
done
