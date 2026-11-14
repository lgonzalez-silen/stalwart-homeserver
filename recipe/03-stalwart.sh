#!/bin/bash
# recipe/03-stalwart.sh — install Stalwart 1.x (official installer)
# Run from your computer:  ./nv run recipe/03-stalwart.sh
# Then finish in the setup wizard (see recipe/03-stalwart-wizard.md).
#
# Layout (installer defaults): binary /usr/local/bin/stalwart, config /etc/stalwart/config.json
# (written by the wizard), env /etc/stalwart/stalwart.env, data /var/lib/stalwart, logs
# /var/log/stalwart. Runs as user "stalwart" with CAP_NET_BIND_SERVICE.
#
# UPGRADES (procedure tested 1.0.1 -> 1.1.0, ~2 s downtime):
#   1. Read every release's notes in between (github.com/stalwartlabs/stalwart/releases); look for
#      "must"/"re-enable"/permission notes. nv-release-check (recipe/09) mails when one is out.
#   2. On the laptop: download stalwart-x86_64-unknown-linux-gnu.tar.gz for the tag, then
#        gh attestation verify <file> --repo stalwartlabs/stalwart --format json
#      and check the file's sha256 is among the attested subjects (built by Stalwart CI from that tag).
#   3. Right after the nightly backup (nv-backup, recipe/08), on the server:
#        cp -a /etc/stalwart /etc/stalwart.bak-pre-<new>; cp -a /usr/local/bin/stalwart /usr/local/bin/stalwart-<old>
#        systemctl stop stalwart; cp -a --reflink=always /var/lib/stalwart /var/lib/stalwart-pre-<new>   (instant on XFS)
#        install -m 755 <new binary> /usr/local/bin/stalwart
#        echo STALWART_UPDATE_ROLE_PERMISSIONS=true >> /etc/stalwart/stalwart.env   (adds new permissions to default roles)
#        systemctl start stalwart; check x:Role/get; remove that env line; systemctl restart stalwart
#   4. Check: log has no WARN/ERROR after "version = <new>", IMAP/SMTP/webmail, a webmail send to Gmail
#      (DKIM/SPF/DMARC pass), nv-fetch + nv-spam-mirror runs, /admin loads.
#   Rollback: systemctl stop stalwart; mv /var/lib/stalwart{,-failed}; mv /var/lib/stalwart-pre-<new> /var/lib/stalwart;
#             cp -a /usr/local/bin/stalwart-<old> /usr/local/bin/stalwart; cp -a /etc/stalwart.bak-pre-<new>/. /etc/stalwart/; start.
#   Delete the -pre copy and the old binary after a quiet week.

HOST=$NV_SERVER_HOSTNAME

echo "== installer (official; downloads latest release from GitHub)"
mkdir -p /root/installs && { live && cd /root/installs; }
# The installer runs as root, so it is pinned: if Stalwart changes it, the recipe stops. Read the new script, then
# set NV_STALWART_INSTALLER_SHA256=<new hash> for that run (and update the pin here).
PIN=${NV_STALWART_INSTALLER_SHA256:-aba687be5a0c1e3fe966183ade4a6098454d4c3b0b2f1d7bec534c8eb69cf4a4}   # 2026-11-14
curl --proto '=https' --tlsv1.2 -sSf https://get.stalw.art/install.sh -o stalwart-install.sh
if live && ! echo "$PIN  stalwart-install.sh" | sha256sum -c --quiet; then
  echo "stalwart-install.sh changed (sha256 $(sha256sum stalwart-install.sh | cut -c1-64)): review it before trusting it"; exit 1
fi
if ! command -v stalwart >/dev/null; then
  sh stalwart-install.sh
fi
stalwart --version || true

echo "== env: hostname + public URL (nginx serves HTTPS on 443 for this name)"
ENV=/etc/stalwart/stalwart.env
add_line $ENV "STALWART_HOSTNAME=$HOST"
# After the wizard, the web admin login ONLY works on the public HTTPS address
# (https://$HOST/admin). Port 8080, the bare IP, or localhost via an SSH tunnel all fail
# with "Unknown client id". First login therefore goes through Stalwart's own 443 listener
# (self-signed placeholder cert; accept the warning once), load the certbot cert, then hand
# 443 to nginx (recipe/04-nginx.sh).
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

echo "== status"
systemctl is-active stalwart
ss -tlnpH | awk '/stalwart/{print $4}' | sort -u | tr '\n' ' '; echo
echo "Wizard: ssh -L 8080:127.0.0.1:8080 root@$HOST  then open http://localhost:8080/admin"
