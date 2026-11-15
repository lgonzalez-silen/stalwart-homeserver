#!/bin/bash
# recipe/07-roundcube.sh — Roundcube webmail at https://<webmail.hostname> (<server.hostname>/rc redirects)
# Run from your computer:  ./nv run recipe/07-roundcube.sh
# Settings: server.hostname, server.timezone, webmail.hostname (default rc.<server.hostname>),
# webmail.product_name, webmail.local_plugins / webmail.local_skins (installed outside the Roundcube release,
# e.g. by recipe/07b; enabled here and carried over on upgrades).
# webmail.identity_smtp (optional, default false): the third-party identity_smtp plugin, which lets each identity
# send through its own outside SMTP server (for people moving from a setup that had that). Off, nobody can make the
# server open SMTP connections to other hosts or store outside passwords. Turning it off later disables it; the
# outside passwords stay in the database (encrypted) until the identities are edited.
#
# Why its own subdomain: browser origin isolation. Stalwart's admin/OAuth lives on
# https://<server.hostname>; Roundcube has a history of XSS bugs, so it must not share that origin.
# Talks to Stalwart over IMAPS/ManageSieve on 127.0.0.1 but verifies the cert as server.hostname
# (127.0.0.1 is in Stalwart's auto-ban exemptions, so Roundcube's IP is never banned; webmail brute
# force is throttled by Roundcube's login_rate_limit and nginx instead). SMTP goes to <server.hostname>:587
# by name (the server's own public IP, not exempt), because the identity_smtp plugin reuses the SMTP
# TLS options for external servers, so they can't pin peer_name. SMTP auth only follows a good IMAP login.
# Storage: SQLite (WAL) in /var/lib/roundcube. Config + des_key in /etc/roundcube (survive upgrades).

VER=1.7.6                              # upgrade: bump, run this, then recipe/07b (rebuild the compact CSS first)
# identity_smtp (third-party, per-identity SMTP server): tag 1.7.0 = commit bb4792cc (2026-03-27)
IDSMTP_VER=1.7.0
IDSMTP_SHA256=fc4b54a9a2dab6ec0c2232c26baab694667f1f1bd28630f944ea3cc509edffa7   # repo moved elm/ -> deflomu/ (same repo id 2802192, same maintainer); checked 2026-11-11
# Stretched Elastic skin by johndoh (Elastic + Desktop/List layouts). master after 0.2, includes the
# list-mode icon fix (#6). Known 1.7 gaps: its layout.html lacks Elastic 1.7's early dark-mode script
# (possible light flash on load) and the quota widget's initial "hidden" class. Cosmetic.
SE_COMMIT=ca430f1e039186d58b57f8f6f5d5f2c1de8bf1e9
SE_SHA256=5828f2b5a7a974828fa40f5c268966d70a004e71dd859578b06ce6c484a6dac3
SIGNING_KEY=5AB2BAA141C4F7D5          # roundcube.net/download (long key ID)
SIGNING_FPR=F3E4C04BB3DB5D4215C45F7F5AB2BAA141C4F7D5   # its full fingerprint (releases are signed by a subkey of it)
HOST=${NV_WEBMAIL_HOSTNAME:-rc.$NV_SERVER_HOSTNAME}
MAILHOST=$NV_SERVER_HOSTNAME
TZ_PHP=${NV_SERVER_TIMEZONE:-UTC}
IDSMTP=; [ "${NV_WEBMAIL_IDENTITY_SMTP:-}" = yes ] && IDSMTP=identity_smtp
PLUGINS="archive zipdownload managesieve markasjunk attachment_reminder $IDSMTP identity_select ${NV_WEBMAIL_LOCAL_PLUGINS:-}"
PLUGINS_PHP=""; for p in $PLUGINS; do PLUGINS_PHP+="${PLUGINS_PHP:+, }'$p'"; done
APP=/var/www/roundcube                 # symlink -> /var/www/roundcubemail-$VER
DATA=/var/lib/roundcube
LOGS=/var/log/roundcube
CONF=/etc/roundcube

echo "== packages (PHP 8.3 from AppStream)"
dnf -y -q install php-fpm php-cli php-common php-pdo php-intl php-mbstring php-xml php-gd \
  php-opcache php-pecl-zip sqlite gnupg2

echo "== PHP-FPM runs as nginx; upload limits"
sed -i -E 's/^user = .*/user = nginx/; s/^group = .*/group = nginx/' /etc/php-fpm.d/www.conf
put /etc/php.d/99-roundcube.ini <<EOF
upload_max_filesize = 25M
post_max_size = 30M
memory_limit = 256M
date.timezone = $TZ_PHP   ; Roundcube computes "Today" with the PHP default zone, not the user's: UTC showed evening mail as Today
expose_php = Off
; Mitigation for CVE-2026-115560 (unpatched as of 2026-11; remove once PHP ships the fix)
session.upload_progress.enabled = 0
EOF
systemctl enable -q php-fpm

echo "== download + verify Roundcube $VER"
mkdir -p /root/installs && { live && cd /root/installs; }
T=roundcubemail-$VER-complete.tar.gz
[ -f $T ] || curl -sSfLO https://github.com/roundcube/roundcubemail/releases/download/$VER/$T
[ -f $T.asc ] || curl -sSfLO https://github.com/roundcube/roundcubemail/releases/download/$VER/$T.asc
export GNUPGHOME=/root/.gnupg-roundcube; mkdir -p -m 700 $GNUPGHOME
gpg -q --list-keys $SIGNING_KEY >/dev/null 2>&1 || curl -sSfL https://roundcube.net/download/pubkey.asc | gpg -q --import
# GOODSIG: good signature by a key that isn't expired or revoked (gpg says EXPKEYSIG/REVKEYSIG instead); VALIDSIG's
# last field: the primary key's full fingerprint, which must be Roundcube's (GOODSIG's user-ID text isn't matched)
gpg --status-fd 1 --verify $T.asc $T 2>/dev/null | awk -v F="$SIGNING_FPR" '$2 == "GOODSIG" { g = 1 } $2 == "VALIDSIG" && $NF == F { v = 1 }
  END { exit !(g && v) }' \
  && echo "signature OK ($SIGNING_KEY)" || { echo "SIGNATURE CHECK FAILED"; exit 1; }

echo "== install to /var/www/roundcubemail-$VER (code root-owned, read-only for nginx)"
if [ ! -d /var/www/roundcubemail-$VER ]; then
  tar xzf $T -C /var/www
  chown -R root:root /var/www/roundcubemail-$VER
fi
P=/var/www/roundcubemail-$VER/plugins/identity_smtp
if [ -n "$IDSMTP" ]; then
echo "== third-party plugin identity_smtp $IDSMTP_VER (source reviewed 2026-11-02)"
if [ ! -d $P ]; then
  T2=identity_smtp-$IDSMTP_VER.tar.gz
  [ -f $T2 ] || curl -sSfL -o $T2 https://github.com/deflomu/Roundcube-SMTP-per-Identity-Plugin/archive/refs/tags/$IDSMTP_VER.tar.gz
  echo "$IDSMTP_SHA256  $T2" | sha256sum -c --quiet || { echo "identity_smtp CHECKSUM FAILED"; exit 1; }
  mkdir -p $P && tar xzf $T2 -C $P --strip-components=1
  chown -R root:root $P
fi
put $P/.nv-version <<< "$IDSMTP_VER"   # read by nv-release-check (recipe/09); the plugin carries no version itself
fi

echo "== third-party skin Stretched Elastic @ ${SE_COMMIT:0:8} (Desktop/List layouts; reviewed 2026-11-08)"
S=/var/www/roundcubemail-$VER/skins/stretchedelastic
if [ ! -d $S ]; then
  T3=stretchedelastic-$SE_COMMIT.tar.gz
  [ -f $T3 ] || curl -sSfL -o $T3 https://github.com/johndoh/roundcube-stretchedelastic/archive/$SE_COMMIT.tar.gz
  echo "$SE_SHA256  $T3" | sha256sum -c --quiet || { echo "stretchedelastic CHECKSUM FAILED"; exit 1; }
  mkdir -p $S && tar xzf $T3 -C $S --strip-components=1
  chown -R root:root $S
fi

echo "== switch $APP -> roundcubemail-$VER (old version dirs stay for rollback: ln -sfn <old dir> $APP)"
NEW=/var/www/roundcubemail-$VER
rm -rf $NEW/installer
CUR=$(readlink -f $APP 2>/dev/null || true)
if [ -n "$CUR" ] && [ "$CUR" != "$NEW" ]; then
  # carry our own plugins + skin over so the switch never runs without them (recipe/07b refreshes them after)
  for x in $(for p in ${NV_WEBMAIL_LOCAL_PLUGINS:-}; do echo plugins/$p; done) $(for s in ${NV_WEBMAIL_LOCAL_SKINS:-}; do echo skins/$s; done); do
    [ -e "$CUR/$x" ] && [ ! -e "$NEW/$x" ] && cp -a "$CUR/$x" "$NEW/$x"
  done
  [ -s $DATA/roundcube.db ] && sudo -u nginx sqlite3 $DATA/roundcube.db ".backup $DATA/roundcube.db.bak-before-$VER" && chmod 640 $DATA/roundcube.db.bak-before-$VER
fi
[ -f $CONF/config.inc.php ] && ln -sfn $CONF/config.inc.php $NEW/config/config.inc.php   # config in place before the switch
ln -sfn $NEW $APP

echo "== data/log/config dirs"
install -d -m 750 -o nginx -g nginx $DATA $LOGS
# temp/ sits inside a folder the web server owns: never let root follow a link someone put there (a compromised
# webmail could aim it at /root). Remove a link, then create the folder AS nginx.
[ -L $DATA/temp ] && rm -f $DATA/temp
sudo -u nginx mkdir -p -m 750 $DATA/temp
install -d -m 750 -o root -g nginx $CONF
semanage fcontext -a -t httpd_sys_rw_content_t "$DATA(/.*)?" 2>/dev/null || semanage fcontext -m -t httpd_sys_rw_content_t "$DATA(/.*)?"
semanage fcontext -a -t httpd_sys_rw_content_t "$LOGS(/.*)?" 2>/dev/null || semanage fcontext -m -t httpd_sys_rw_content_t "$LOGS(/.*)?"
restorecon -R $DATA $LOGS /var/www

echo "== config (des_key generated once, kept in $CONF)"
live && { [ -s $CONF/des_key ] || { umask 077; openssl rand -base64 24 | tr -d '\n' > $CONF/des_key; }; }
chown root:nginx $CONF/des_key; chmod 640 $CONF/des_key
if live; then DES=$(cat $CONF/des_key); else DES='<secret:des_key>'; fi
PRODUCT=${NV_WEBMAIL_PRODUCT_NAME:-Webmail}; PRODUCT_PHP=${PRODUCT//\\/\\\\}; PRODUCT_PHP=${PRODUCT_PHP//\'/\\\'}   # PHP single-quoted string
RC_MAXMSG=$(( ${NV_MAIL_MAX_MESSAGE_MB:-25} * 3 / 4 ))   # attachments: base64 makes a message ~1/3 bigger than its files
put $CONF/config.inc.php 640 root:nginx <<EOF
<?php
// Managed by recipe/07-roundcube.sh — edit there, not here.
\$tls = ['ssl' => ['verify_peer' => true, 'verify_peer_name' => true,
                   'peer_name' => '$MAILHOST', 'cafile' => '/etc/pki/tls/certs/ca-bundle.crt']];

\$config['db_dsnw'] = 'sqlite:///$DATA/roundcube.db?mode=0640';
\$config['imap_host'] = 'ssl://127.0.0.1:993';
\$config['imap_conn_options'] = \$tls;
\$config['smtp_host'] = 'tls://$MAILHOST:587';
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';
\$config['smtp_conn_options'] = ['ssl' => ['verify_peer' => true, 'verify_peer_name' => true,
                                           'cafile' => '/etc/pki/tls/certs/ca-bundle.crt']];
\$config['managesieve_host'] = 'tls://127.0.0.1:4190';
\$config['managesieve_conn_options'] = \$tls;

\$config['des_key'] = '$DES';
\$config['product_name'] = '${PRODUCT_PHP}';
\$config['support_url'] = '';
\$config['skin'] = 'elastic';
\$config['plugins'] = [$PLUGINS_PHP];
// identity_select: on reply, also pick the identity from Delivered-To (Bcc'd, list and forwarded mail)
\$config['identity_select_headers'] = ['Delivered-To'];
\$config['temp_dir'] = '$DATA/temp/';
\$config['log_dir'] = '$LOGS/';
\$config['enable_installer'] = false;
\$config['use_https'] = true;
\$config['ip_check'] = true;
\$config['login_rate_limit'] = 3;          // failed logins per minute per client
\$config['session_lifetime'] = 60;         // minutes
\$config['session_samesite'] = 'Strict';
\$config['mail_domain'] = '%d';
// files per message: ~3/4 of the mail server's limit (mail.max_message_mb). Large files and photo sets
// belong in a shared link (Drive, Photos album), not in everyone's mailbox.
\$config['max_message_size'] = '${RC_MAXMSG}M';
EOF
ln -sfn $CONF/config.inc.php $APP/config/config.inc.php

echo "== SQLite schema (first run only) + WAL"
if live && [ ! -s $DATA/roundcube.db ]; then
  sudo -u nginx sqlite3 $DATA/roundcube.db < $APP/SQL/sqlite.initial.sql
fi
sudo -u nginx sqlite3 $DATA/roundcube.db 'PRAGMA journal_mode=WAL;' >/dev/null
live && (cd $APP && sudo -u nginx php bin/updatedb.sh --package=roundcube --dir=$APP/SQL)   # schema changes between versions
chmod 640 $DATA/roundcube.db; restorecon -R $DATA

echo "== nginx: $HOST (rate-limit zones incl. rclogin are defined in recipe/04-nginx.sh)"
grep -q 'zone=rclogin' /etc/nginx/conf.d/00-common.conf || { echo "run recipe/04-nginx.sh first"; exit 1; }
put /etc/nginx/conf.d/30-$HOST.conf 600 <<EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $HOST;
    ssl_certificate     /etc/letsencrypt/live/$MAILHOST/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$MAILHOST/privkey.pem;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy same-origin always;

    root $APP/public_html;
    index index.php;
    client_max_body_size 30m;
    limit_req zone=perip burst=100 nodelay;
    limit_req zone=rclogin burst=5 nodelay;

    location ~ /\. { deny all; }
    # Roundcube 1.6+ serves skins/plugins/js through static.php/<path> (PATH_INFO)
    location ~ \.php(/|\$) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)\$;
        try_files \$fastcgi_script_name =404;
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param HTTPS on;
    }
}
EOF
live && { php -l $CONF/config.inc.php >/dev/null || { echo "config.inc.php has a PHP error: fix it before webmail breaks"; php -l $CONF/config.inc.php; exit 1; }; }
nginx_apply none
systemctl restart php-fpm
systemctl reload nginx

echo "== checks"
# nginx was just reloaded: give its new workers a moment (a request during the switch can be dropped)
if live; then
  for i in 1 2 3 4 5; do code=$(curl -s -o /dev/null -w "%{http_code}" --resolve $HOST:443:127.0.0.1 https://$HOST/ || true)
    [ "$code" = 200 ] && break; sleep 1; done
  echo "login page via nginx: $code"; [ "$code" = 200 ] || { echo "webmail is not answering: systemctl status nginx php-fpm"; exit 1; }
fi
sudo -u nginx sqlite3 $DATA/roundcube.db 'PRAGMA journal_mode;' | sed 's/^/sqlite journal_mode: /'
