#!/bin/bash
# recipe/07-stalwart-settings.sh — Stalwart settings that live in its database (not in files)
# Run from your computer:  ./nv run recipe/07-stalwart-settings.sh        (NV_SHOW=1 ./nv run ... : read-only check)
# Runs on the server against the admin API on http://127.0.0.1:8080 with the API key in
# /root/.secrets/laptop-api.key (an admin API key restricted to 127.0.0.1/::1; create it in the WebUI and store it
# there, mode 0600). Password auth stops working once the admin account has TOTP, hence the key.
# In render mode the JSON it would send goes to <dir>/jmap.log.
# Settings: mail.mx_hosts (every MX name your domains use; listed in the MTA-STS policy).
#           mail.max_message_mb (largest message accepted, default 25 like Gmail; Stalwart's default is 100).
#           Large files belong in shared links: on a personal server every big message is a real share of the disk.
#
# Settings done by hand in the WebUI (record yours in your site notes when changed):
#   - Wizard: default domain, ACME off, DKIM on, manual DNS (03-stalwart-wizard.md)
#   - TLS › Certificates: File /etc/stalwart/tls/fullchain.pem + privkey.pem
#   - Listeners: smtp 25, submissions 465 (implicit), submission 587 (STARTTLS), imaps 993,
#     sieve 127.0.0.1:4190 only (Roundcube's filters); http 127.0.0.1:8080 only; https 443 deleted;
#     pop3s 995 deleted unless someone uses POP3
#   - HTTP Server › Proxy: Client IP source = X-Forwarded-For, hops 1
#   - Allowed IPs (auto-ban exemptions): 127.0.0.1, ::1 and the server's own IPv4 + IPv6 (Roundcube's SMTP comes
#     from the server's public address, so failed webmail sends must not ban the server itself)
#   - Telemetry › file tracer: ansi off (otherwise the logs are full of color codes)
#   - Admin account: TOTP two-factor (secret in your password manager)
#   - API key for these recipes and the tools: allowed IPs 127.0.0.1, ::1 (Bearer)

KEYFILE=/root/.secrets/laptop-api.key
J() {   # J <json>: one JMAP request to the admin API
  if live; then
    # the key goes to curl as a header file, never on its command line (visible to every local user in ps)
    curl -sf -H @<(printf 'Authorization: Bearer %s\n' "$(<$KEYFILE)") -H "Content-Type: application/json" \
      http://127.0.0.1:8080/jmap/ --data-binary "$1"
  else
    printf '%s\n' "$1" >> "$NV_RENDER/jmap.log"
  fi
}
live && { [ -s $KEYFILE ] || { echo "missing $KEYFILE (see header)"; exit 1; }; }
DAY=86400000
MAXMSG=$(( ${NV_MAIL_MAX_MESSAGE_MB:-25} * 1048576 ))
MX_JSON=""; for h in ${NV_MAIL_MX_HOSTS:?set mail.mx_hosts in site.json}; do MX_JSON+="${MX_JSON:+,}\"$h\":true"; done

if [ "${NV_SHOW:-}" != 1 ]; then
  # Bans expire (empty period = permanent in 1.0.1); auth threshold 30/day (default 100)
  # Message-ID/Date: add when missing on every port (default only 25). Message size limit from site.json. MTA-STS: the policy must list every MX
  # name the domains use (default lists only the server hostname).
  # Outgoing DMARC aggregate + failure + TLS reports to OTHER domains: off (default daily: dozens a day of courtesy
  # mail, some bouncing, and failure reports go mostly to spammers' addresses). Reports ABOUT your domains still
  # arrive. Re-enable: "daily". These report settings take effect at the next Stalwart restart, not when saved.
  J "{\"using\":[\"urn:ietf:params:jmap:core\"],\"methodCalls\":[
    [\"x:Security/set\",{\"accountId\":\"b\",\"update\":{\"singleton\":{
      \"authBanRate\":{\"count\":30,\"period\":$DAY},\"authBanPeriod\":$DAY,
      \"abuseBanPeriod\":$DAY,\"loiterBanPeriod\":$DAY,\"scanBanPeriod\":$((DAY*7))}}},\"s\"],
    [\"x:SpamPyzor/set\",{\"accountId\":\"b\",\"update\":{\"singleton\":{\"enable\":true}}},\"p\"],
    [\"x:MtaStageData/set\",{\"accountId\":\"b\",\"update\":{\"singleton\":{
      \"addMessageIdHeader\":{\"match\":{},\"else\":\"true\"},\"addDateHeader\":{\"match\":{},\"else\":\"true\"},
      \"maxMessageSize\":{\"match\":{},\"else\":\"$MAXMSG\"}}}},\"d\"],
    [\"x:MtaSts/set\",{\"accountId\":\"b\",\"update\":{\"singleton\":{
      \"mxHosts\":{$MX_JSON}}}},\"m\"],
    [\"x:DmarcReportSettings/set\",{\"accountId\":\"b\",\"update\":{\"singleton\":{
      \"aggregateSendFrequency\":{\"match\":{},\"else\":\"disable\"},
      \"failureSendFrequency\":{\"match\":{},\"else\":\"disable\"}}}},\"r\"],
    [\"x:TlsReportSettings/set\",{\"accountId\":\"b\",\"update\":{\"singleton\":{
      \"sendFrequency\":{\"match\":{},\"else\":\"disable\"}}}},\"t\"]]}" \
    | jq -c '.methodResponses[] | [.[0], (.[1].updated // .[1].notUpdated)]'
fi

J '{"using":["urn:ietf:params:jmap:core"],"methodCalls":[
  ["x:Security/get",{"accountId":"b","ids":["singleton"]},"a"],
  ["x:SpamPyzor/get",{"accountId":"b","ids":["singleton"]},"b"],
  ["x:AllowedIp/get",{"accountId":"b","ids":null},"c"]]}' \
  | jq -c '(.methodResponses[0][1].list[0] | del(.scanBanPaths)),
           (.methodResponses[1][1].list[0] | {pyzor: .enable}),
           (.methodResponses[2][1].list | map(.address) | {allowedIps: .})'
