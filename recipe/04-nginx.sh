#!/bin/bash
# recipe/04-nginx.sh — nginx as the only listener on 80/443, in front of Stalwart's HTTP
# Run from your computer:  ./nv run recipe/04-nginx.sh
# Settings: server.hostname, server.ipv4, server.ipv6, webmail.hostname (default rc.<server.hostname>),
# admin.allow (optional list of IPs/CIDRs allowed to reach the WebUI at /admin; empty = open). This only hides the
# web console: the admin API itself is the JMAP endpoint every mail app uses, so it can't be IP-limited here. What
# protects admin is TOTP on the admin account and an API key limited to 127.0.0.1/::1 (recipe/03).
#
# First build: run this (nginx installed + tested, NOT started while Stalwart has 443), then
# recipe/05-stalwart-settings.sh: it moves Stalwart's HTTP to 127.0.0.1:8080, sets X-Forwarded-For, removes Stalwart's
# 443 listener, restarts Stalwart and starts nginx, then checks the admin console through nginx.
#
# Constraints from Stalwart 1.0 docs:
# - Web admin/OAuth login only works on the public URL (https://<server.hostname>), served at the
#   root of the hostname -> no admin.* subdomain and no path prefix.
# - With clientIpSource=xForwardedFor, the HTTP listener must be reachable ONLY via the proxy.

HOST=$NV_SERVER_HOSTNAME
WEBMAIL=${NV_WEBMAIL_HOSTNAME:-rc.$HOST}
read -r -a ADMIN_ALLOW <<< "${NV_ADMIN_ALLOW:-}"
LIVE=/etc/letsencrypt/live/$HOST

dnf -y -q install nginx

# Drop the stock welcome-page server block from nginx.conf (ours in conf.d replaces it)
nginx_track /etc/nginx/nginx.conf   # edited in place below: restorable if the test fails
python3 - <<'PY'
import re, pathlib
p = pathlib.Path('/etc/nginx/nginx.conf'); s = p.read_text()
s2 = re.sub(r'\n    server \{\n        listen       80;.*?\n    \}\n', '\n', s, count=1, flags=re.S)
if s2 != s: p.write_text(s2); print("removed stock server block")
PY

# nginx -> 127.0.0.1:8080 (http_cache_port_t) needs this under SELinux
setsebool -P httpd_can_network_connect 1

ALLOW_LINES=""
if [ ${#ADMIN_ALLOW[@]} -gt 0 ]; then
  for ip in "${ADMIN_ALLOW[@]}"; do ALLOW_LINES+="        allow $ip;"$'\n'; done
  ALLOW_LINES+="        deny all;"$'\n'
fi

put /etc/nginx/conf.d/00-common.conf <<EOF
# Shared settings
server_tokens off;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
client_max_body_size 100m;   # JMAP uploads / attachments

# Rate limiting (defense in depth). With clientIpSource=X-Forwarded-For, Stalwart 1.0.1 bans and
# rate-limits HTTP clients by the forwarded IP (checked in source: HttpSessionData.remote_ip
# feeds auth fail2ban, anonymous limits and scan bans). Issue #3323 described pre-1.0 code.
# Note: Stalwart log lines (e.g. auth.success) show remoteIp=127.0.0.1 because that field comes
# from the TCP connection span, not the request; the forwarded IP shows in debug http events.
limit_req_status 429;
# The server's own addresses are exempt from the per-IP limit (bulk JMAP uploads by Vandelay
# running on the server reach nginx from its public IP). An empty key means "not limited".
geo \$self_ip { default 0; 127.0.0.0/8 1; ::1/128 1; $NV_SERVER_IPV4/32 1;${NV_SERVER_IPV6:+ $NV_SERVER_IPV6/128 1;} }
map \$self_ip \$perip_key { 1 ""; default \$binary_remote_addr; }
limit_req_zone \$perip_key zone=perip:10m rate=20r/s;
map \$request_method \$auth_post_key { POST \$binary_remote_addr; default ""; }
limit_req_zone \$auth_post_key zone=authpost:10m rate=10r/m;
# Roundcube login POSTs (./?_task=login), used by recipe/07-roundcube.sh
map "\$request_method:\$arg__task" \$rc_login_key { "POST:login" \$binary_remote_addr; default ""; }
limit_req_zone \$rc_login_key zone=rclogin:10m rate=10r/m;
EOF

put /etc/nginx/conf.d/10-$HOST.conf <<EOF
# Plain HTTP: redirect everything
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    # HTTP-01 for the per-domain mail helper cert (recipe/06-mail-domain-certs.sh)
    location ^~ /.well-known/acme-challenge/ { root /var/www/letsencrypt; }
    location / { return 301 https://\$host\$request_uri; }
}

# Catch-all on 443 for unknown names (scanners hitting the bare IP)
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    http2 on;
    server_name _;
    ssl_certificate     $LIVE/fullchain.pem;
    ssl_certificate_key $LIVE/privkey.pem;
    return 444;
}

# Stalwart: JMAP, OAuth/OIDC, well-known discovery, DAV, web admin
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $HOST;
    ssl_certificate     $LIVE/fullchain.pem;
    ssl_certificate_key $LIVE/privkey.pem;
    add_header Strict-Transport-Security "max-age=31536000" always;

    limit_req zone=perip burst=100 nodelay;

    # Old muscle memory: $HOST/rc -> Roundcube on its own origin
    location = /rc  { return 301 https://$WEBMAIL/; }
    location ^~ /rc/ { return 301 https://$WEBMAIL/; }

    location /admin {
$ALLOW_LINES        proxy_pass http://127.0.0.1:8080;
        include /etc/nginx/stalwart_proxy.conf;
    }

    # Credential endpoints: OAuth login form POST and token/device/register endpoints
    location ~ ^/(login|auth/) {
        limit_req zone=authpost burst=10 nodelay;
        proxy_pass http://127.0.0.1:8080;
        include /etc/nginx/stalwart_proxy.conf;
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
        include /etc/nginx/stalwart_proxy.conf;
    }
}
EOF

put /etc/nginx/stalwart_proxy.conf <<'EOF'
proxy_http_version 1.1;
proxy_set_header Host $host;
# set (not append) so clients can't inject a fake first hop; Stalwart reads 1 hop
proxy_set_header X-Forwarded-For $remote_addr;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header Upgrade $http_upgrade;          # JMAP websockets
proxy_set_header Connection $connection_upgrade;
proxy_read_timeout 1h;                           # JMAP push / eventsource
proxy_buffering off;
EOF

nginx_apply none   # tested here; started/reloaded below
if ss -tlnpH | grep -q ':443 .*stalwart'; then
  echo "Stalwart still owns 443: nginx installed + validated but NOT started: recipe/05 hands 443 over"
else
  systemctl enable --now nginx
  # restart, not reload: a reload that changes a limit_req_zone key fails at runtime ([emerg] in
  # error.log) while systemctl still reports success, leaving the old config live (bit us 2026-11-08)
  systemctl restart nginx
  echo "nginx running"
fi
