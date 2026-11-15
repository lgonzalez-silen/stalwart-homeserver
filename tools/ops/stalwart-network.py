# stalwart-network.py: run by recipe/05 on the server (python3 - <cutover yes|no> <show 1|"">).
# Brings Stalwart's TLS certificate, listeners, allowed IPs and log format to the state this setup expects, through the admin API.
# Prints every change; with show=1 it only prints what it would change.
#   always:   the certbot certificate (/etc/stalwart/tls, refreshed by certbot's deploy hook) is loaded;
#             sieve on 127.0.0.1:4190 only; submission on 587 (STARTTLS) exists; pop3/pop3s removed;
#             allowed IPs 127.0.0.1, ::1 and the server's own IPv4/IPv6; log-file tracers without ANSI colors;
#             DKIM key management Manual on every domain (Stalwart's default, Automatic, rotates keys every 90 days
#             under new selectors that nobody publishes in DNS: signatures would start failing with no warning).
#             Switching keeps the existing keys. A domain added later in the WebUI starts as Automatic: rerun recipe/05.
#   cutover:  http on 127.0.0.1:8080 only; Client IP source = X-Forwarded-For (1 hop); the https 443 listener removed.
#             recipe/05 then restarts Stalwart and starts nginx (only when nginx isn't running yet).
import json, os, sys, urllib.request

CUT = sys.argv[1] == "yes"
SHOW = len(sys.argv) > 2 and sys.argv[2] == "1"
KEY = open("/root/.secrets/laptop-api.key").read().strip()
IPS = [x for x in ("127.0.0.1", "::1", os.environ.get("NV_SERVER_IPV4", ""), os.environ.get("NV_SERVER_IPV6", "")) if x]


def api(calls):
    r = urllib.request.Request("http://127.0.0.1:8080/jmap/", data=json.dumps(
        {"using": ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"], "methodCalls": calls}).encode(),
        headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    out = json.load(urllib.request.urlopen(r, timeout=60))["methodResponses"]
    for name, args, _ in out:
        if name == "error" or args.get("notCreated") or args.get("notUpdated") or args.get("notDestroyed"):
            sys.exit(f"Stalwart refused: {json.dumps(args)[:400]}")
    return out


changes = []
def change(what, call):
    changes.append(what)
    print(("would: " if SHOW else "") + what)
    if not SHOW:
        api([call])


CERT, PKEY = "/etc/stalwart/tls/fullchain.pem", "/etc/stalwart/tls/privkey.pem"
certs = api([["x:Certificate/get", {"ids": None, "properties": ["certificate"]}, "c"]])[0][1]["list"]
if not any((c.get("certificate") or {}).get("filePath") == CERT for c in certs):
    change(f"TLS certificate from {CERT} (certbot)", ["x:Certificate/set", {"create": {"n": {
        "certificate": {"@type": "File", "filePath": CERT}, "privateKey": {"@type": "File", "filePath": PKEY}}}}, "c"])
    if not CUT and not SHOW:
        print("  Stalwart uses it from its next restart: systemctl restart stalwart (~2 s), or wait for the nightly backup")

for d in api([["x:Domain/get", {"ids": None, "properties": ["name", "dkimManagement"]}, "d"]])[0][1]["list"]:
    if (d.get("dkimManagement") or {}).get("@type") != "Manual":
        change(f"DKIM keys of {d['name']}: Manual (no automatic rotation; the keys stay)",
               ["x:Domain/set", {"update": {d["id"]: {"dkimManagement": {"@type": "Manual"}}}}, "k"])

ls = {l["name"]: l for l in api([["x:NetworkListener/get", {"ids": None}, "l"]])[0][1]["list"]}
by_port = lambda port: [l for l in ls.values() if any(b.endswith(f":{port}") for b in l.get("bind") or {})]

if "sieve" in ls and set(ls["sieve"]["bind"]) != {"127.0.0.1:4190"}:
    change("sieve listener -> 127.0.0.1:4190 only", ["x:NetworkListener/set", {"update": {ls["sieve"]["id"]: {"bind": {"127.0.0.1:4190": True}}}}, "s"])
if not by_port(587):
    change("add submission listener on 587 (STARTTLS)", ["x:NetworkListener/set", {"create": {"n": {
        "name": "submission", "protocol": "smtp", "bind": {"[::]:587": True}, "implicitTls": False}}}, "c"])
for l in [l for l in ls.values() if l["protocol"] in ("pop3",)]:
    change(f"remove {l['name']} listener (POP3 isn't used)", ["x:NetworkListener/set", {"destroy": [l["id"]]}, "d"])

have = {a["address"] for a in api([["x:AllowedIp/get", {"ids": None}, "a"]])[0][1]["list"]}
for ip in IPS:
    if ip not in have:
        change(f"allowed IP {ip} (auto-ban exemption)", ["x:AllowedIp/set", {"create": {"n": {
            "address": ip, "reason": "the server itself (recipe/05)", "createdAt": "2026-01-01T00:00:00Z"}}}, "c"])

for t in api([["x:Tracer/get", {"ids": None, "properties": ["path", "ansi"]}, "t"]])[0][1]["list"]:
    if t.get("path") and t.get("ansi"):
        change(f"log tracer {t['path']}: ANSI colors off", ["x:Tracer/set", {"update": {t["id"]: {"ansi": False}}}, "t"])

if CUT:
    http = ls.get("http") or next(iter([l for l in ls.values() if l["protocol"] == "http" and not l.get("implicitTls")]), None)
    if http and set(http["bind"]) != {"127.0.0.1:8080"}:
        change("http listener -> 127.0.0.1:8080 only (nginx in front)", ["x:NetworkListener/set", {"update": {http["id"]: {"bind": {"127.0.0.1:8080": True}}}}, "h"])
    proxy = api([["x:Http/get", {"ids": ["singleton"]}, "p"]])[0][1]["list"][0]
    if proxy.get("clientIpSource") != "xForwardedFor" or proxy.get("forwardedHops") != 1:
        change("Client IP source = X-Forwarded-For, 1 hop", ["x:Http/set", {"update": {"singleton": {"clientIpSource": "xForwardedFor", "forwardedHops": 1}}}, "p"])
    for l in [l for l in ls.values() if l["protocol"] == "http" and l.get("implicitTls")]:
        change(f"remove {l['name']} listener on 443 (nginx owns 443)", ["x:NetworkListener/set", {"destroy": [l["id"]]}, "d"])

print(f"{'would change' if SHOW else 'changed'}: {len(changes)}")
