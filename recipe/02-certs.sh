#!/bin/bash
# recipe/02-certs.sh — one TLS certificate for everything on the server
# Wildcard via Cloudflare DNS-01, owned by certbot. nginx and Stalwart both use it;
# Stalwart's own ACME stays off (several cert mechanisms fighting each other is a classic pain).
#
# Run from your computer (the token goes straight from your password manager into a root-only file; 1Password shown):
#   op read "<secret reference of the token>" \
#     | ssh root@<server.hostname> 'umask 077; mkdir -p /root/.secrets; { printf "dns_cloudflare_api_token = "; cat; } > /root/.secrets/cloudflare.ini'
#   ./nv run recipe/02-certs.sh
#
# Token: a Cloudflare user token with Zone.DNS:Edit on the zone of server.hostname only, IP-filtered to the
# server's IPv4, no expiry.
# Settings: server.hostname; certs.extra_names (optional: more names on the same cert, e.g. an existing IMAP/SMTP
# name your clients already use, so they keep working when it moves to this server).

CERT=$NV_SERVER_HOSTNAME
EXTRA=""
for n in ${NV_CERTS_EXTRA_NAMES:-}; do EXTRA="$EXTRA -d $n"; done
CREDS=/root/.secrets/cloudflare.ini

live && { [ -s "$CREDS" ] || { echo "missing $CREDS (see header)"; exit 1; }; }
chmod 600 "$CREDS"

echo "== certbot + cloudflare plugin"
dnf -y -q install certbot python3-certbot-dns-cloudflare

echo "== issue (or keep) $CERT + *.$CERT ${NV_CERTS_EXTRA_NAMES:-}"
certbot certonly -n --agree-tos --register-unsafely-without-email \
  --dns-cloudflare --dns-cloudflare-credentials "$CREDS" \
  --dns-cloudflare-propagation-seconds 30 \
  --key-type ecdsa --cert-name "$CERT" \
  -d "$CERT" -d "*.$CERT" $EXTRA \
  --keep-until-expiring --expand

echo "== deploy hook: hand the cert to consumers after each renewal"
put /etc/letsencrypt/renewal-hooks/deploy/10-consumers.sh 755 <<EOF
#!/bin/bash
# Runs after every successful issue/renewal.
set -u
LIVE=/etc/letsencrypt/live/$CERT
# Stalwart (runs as user stalwart; can't read /etc/letsencrypt) — copy with its ownership
if id stalwart >/dev/null 2>&1 && [ -d /etc/stalwart ]; then
  install -d -m 750 -o root -g stalwart /etc/stalwart/tls
  install -m 640 -o root -g stalwart "\$LIVE/fullchain.pem" /etc/stalwart/tls/fullchain.pem
  install -m 640 -o root -g stalwart "\$LIVE/privkey.pem"   /etc/stalwart/tls/privkey.pem
  systemctl try-reload-or-restart stalwart || true
fi
systemctl is-active -q nginx && systemctl reload nginx || true
EOF

echo "== renewal timer + dry run"
systemctl enable --now certbot-renew.timer
certbot renew --dry-run -q && echo "renew dry-run OK"

echo "== summary"
certbot certificates 2>/dev/null | grep -E "Certificate Name|Domains|Expiry|Key Type"
systemctl list-timers certbot-renew.timer --no-pager | sed -n 2p
