#!/bin/bash
# recipe/03-stalwart.sh — install Stalwart 1.x (official installer)
# Run from your computer:  ./nv run recipe/03-stalwart.sh
# Then: recipe/03-stalwart-admin.md (save the admin password, turn on two-factor).
#
# Layout (installer defaults): binary /usr/local/bin/stalwart, config /etc/stalwart/config.json
# (written at the first setup), env /etc/stalwart/stalwart.env, data /var/lib/stalwart, logs
# /var/log/stalwart. Runs as user "stalwart" with CAP_NET_BIND_SERVICE.
#
# First setup without the WebUI wizard (tools/ops/stalwart-bootstrap.py): the same settings the wizard asks for,
# saved through the same API: hostname = server.hostname, default domain = mail.default_domain if set (else
# Stalwart's guess: the hostname without its first label), TLS from certbot (no ACME), DKIM keys generated. The
# admin account's password lands in /root/.secrets/stalwart-admin, and an API key limited to 127.0.0.1/::1 in
# /root/.secrets/laptop-api.key (used by recipe/05 and the tools). Nothing secret is printed.
#
# UPGRADES (procedure tested 1.0.1 -> 1.1.0, ~2 s downtime):
#   1. Read every release's notes in between (github.com/stalwartlabs/stalwart/releases); look for
#      "must"/"re-enable"/permission notes. nv-release-check (recipe/09) mails you once when one is out.
#   2. On the laptop: download stalwart-x86_64-unknown-linux-gnu.tar.gz for the tag, then
#        gh attestation verify <file> --repo stalwartlabs/stalwart --format json
#      and check the file's sha256 is among the attested subjects (built by Stalwart CI from that tag).
#   3. Right after the nightly backup (nv-backup, recipe/08), on the server:
#        cp -a /etc/stalwart /etc/stalwart.bak-pre-<new>; cp -a /usr/local/bin/stalwart /usr/local/bin/stalwart-<old>
#        systemctl stop stalwart; cp -a --reflink=always /var/lib/stalwart /var/lib/stalwart-pre-<new>   (instant on XFS)
#        install -m 755 <new binary> /usr/local/bin/stalwart
#        echo STALWART_UPDATE_ROLE_PERMISSIONS=true >> /etc/stalwart/stalwart.env   (adds new permissions to default roles)
#        systemctl start stalwart; check x:Role/get; remove that env line; systemctl restart stalwart
#   4. In this recipe, set STALWART_VER and STALWART_SHA256 to the new release (what a fresh build installs).
#   5. Check: log has no WARN/ERROR after "version = <new>", IMAP/SMTP/webmail, a webmail send to Gmail
#      (DKIM/SPF/DMARC pass), nv-fetch + nv-spam-mirror runs, /admin loads.
#   Rollback: systemctl stop stalwart; mv /var/lib/stalwart{,-failed}; mv /var/lib/stalwart-pre-<new> /var/lib/stalwart;
#             cp -a /usr/local/bin/stalwart-<old> /usr/local/bin/stalwart; cp -a /etc/stalwart.bak-pre-<new>/. /etc/stalwart/; start.
#   Delete the -pre copy and the old binary after a quiet week.

HOST=$NV_SERVER_HOSTNAME
# First install: this release, this binary (sha256 of the x86_64 gnu build, checked against GitHub's build attestation
# when it was pinned). Later versions: the UPGRADES procedure above.
STALWART_VER=1.1.0
STALWART_SHA256=97dce1a2d60e09f2cee8fb74f2514da5a576cc79e5204d16d7fcdade181ba05d

echo "== installer (official), pinned to Stalwart $STALWART_VER"
mkdir -p /root/installs && { live && cd /root/installs; }
# The installer runs as root, so it is pinned: if Stalwart changes it, the recipe stops. Read the new script, then
# set NV_STALWART_INSTALLER_SHA256=<new hash> for that run (and update the pin here).
PIN=${NV_STALWART_INSTALLER_SHA256:-aba687be5a0c1e3fe966183ade4a6098454d4c3b0b2f1d7bec534c8eb69cf4a4}   # 2026-11-14
if ! command -v stalwart >/dev/null; then   # only checked when it would actually run
  curl --proto '=https' --tlsv1.2 -sSf https://get.stalw.art/install.sh -o stalwart-install.sh
  if live && ! echo "$PIN  stalwart-install.sh" | sha256sum -c --quiet; then
    echo "stalwart-install.sh changed (sha256 $(sha256sum stalwart-install.sh | cut -c1-64)): review it before trusting it"; exit 1
  fi
  # The installer fetches the latest release and starts it. Instead: download the pinned release here, check the
  # binary inside it BEFORE anything runs, and have the installer copy that checked file instead of downloading.
  if live && [ "$(uname -m)" != x86_64 ]; then echo "the pinned Stalwart build is for x86_64 only"; exit 1; fi
  TGZ=/root/installs/stalwart-$STALWART_VER-x86_64-unknown-linux-gnu.tar.gz
  [ -f "$TGZ" ] || curl --proto '=https' --tlsv1.2 -sSfL -o "$TGZ" \
    "https://github.com/stalwartlabs/stalwart/releases/download/v$STALWART_VER/stalwart-x86_64-unknown-linux-gnu.tar.gz"
  if live && [ "$(tar -xzOf "$TGZ" stalwart | sha256sum | cut -c1-64)" != "$STALWART_SHA256" ]; then
    mv -f "$TGZ" "$TGZ.REJECTED"; echo "the downloaded Stalwart $STALWART_VER isn't the pinned build: nothing installed"; exit 1
  fi
  DL='ensure downloader "${BASE_URL}/${_component}-${_arch}.tar.gz" "$_tar" "$_arch"'
  if live && ! grep -qF "$DL" stalwart-install.sh; then
    echo "stalwart-install.sh no longer downloads the way this recipe expects: nothing installed"; exit 1
  fi
  sed -i "s#${DL//\$/\\\$}#ensure cp \"$TGZ\" \"\$_tar\"#" stalwart-install.sh
  sh stalwart-install.sh
  if live && ! echo "$STALWART_SHA256  /usr/local/bin/stalwart" | sha256sum -c --quiet; then   # belt and braces
    mv /usr/local/bin/stalwart /root/installs/stalwart.REJECTED; systemctl stop stalwart || true
    echo "the installed Stalwart binary isn't the pinned $STALWART_VER build: moved to /root/installs/stalwart.REJECTED, stopped"; exit 1
  fi
fi
stalwart --version || true

echo "== env: hostname + public URL (nginx serves HTTPS on 443 for this name)"
ENV=/etc/stalwart/stalwart.env
add_line $ENV "STALWART_HOSTNAME=$HOST"
# The web admin login ONLY works on the public HTTPS address (https://$HOST/admin). Port 8080, the bare IP, or
# localhost via an SSH tunnel all fail with "Unknown client id". recipe/05 hands 443 to nginx; sign in after that.
add_line $ENV "STALWART_PUBLIC_URL=https://$HOST"

echo "== start after the local resolver (unbound waits ~25 s for unbound-anchor at boot)"
mkdir -p /etc/systemd/system/stalwart.service.d
put /etc/systemd/system/stalwart.service.d/10-after-dns.conf <<'EOF'
[Unit]
After=unbound.service nss-lookup.target network-online.target
Wants=unbound.service network-online.target
EOF
systemctl daemon-reload

echo "== TLS: copy the certbot cert where Stalwart can read it (deploy hook does this on renewals)"
run /etc/letsencrypt/renewal-hooks/deploy/10-consumers.sh
ls -l /etc/stalwart/tls/

echo "== first setup (instead of the WebUI wizard) and the API key, when not done yet"
if live; then
  repo_file tools/ops/stalwart-bootstrap.py | python3 -I - "$HOST" "${NV_MAIL_DEFAULT_DOMAIN:-}" || exit 1
fi

echo "== status"
systemctl is-active stalwart
ss -tlnpH | awk '/stalwart/{print $4}' | sort -u | tr '\n' ' '; echo
echo "Next: recipe/04-nginx.sh, recipe/05-stalwart-settings.sh, then recipe/03-stalwart-admin.md"
