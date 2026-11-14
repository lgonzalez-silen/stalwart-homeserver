# stalwart-bootstrap.py: run by recipe/03 on the server (python3 - <hostname> [default domain]).
# Does what Stalwart's setup wizard does, through the same API the wizard uses, and makes the API key the other
# recipes and tools use. Each step runs only when needed, so running it again is safe:
#   1. First start (no /etc/stalwart/config.json): save the wizard's settings (x:Bootstrap): hostname, default
#      domain, TLS certificate from certbot instead of ACME, DKIM keys generated, logs without colors. Stalwart
#      answers with the admin account it created and its password: saved to /root/.secrets/stalwart-admin
#      ("user:password", root only), never printed.
#   2. No API key (/root/.secrets/laptop-api.key missing: first build, or after a restore, whose database doesn't
#      know this install's key): create one for the admin account, allowed from 127.0.0.1/::1 only.
# Both steps sign in with a one-time recovery credential (STALWART_RECOVERY_ADMIN, which Stalwart accepts in
# bootstrap and normal mode): a random value in a root-only file under /run, used for this run and then removed
# (Stalwart is restarted without it). It's never printed or logged, and the admin's password or TOTP isn't needed.
import base64, json, os, secrets, subprocess, sys, time, urllib.error, urllib.request

HOST = sys.argv[1]
DOMAIN = sys.argv[2] if len(sys.argv) > 2 else ""
CONFIG = "/etc/stalwart/config.json"
ADMIN = "/root/.secrets/stalwart-admin"
KEYFILE = "/root/.secrets/laptop-api.key"
SETUP_ENV = "/run/stalwart-setup.env"
DROPIN = "/run/systemd/system/stalwart.service.d/90-setup.conf"
os.umask(0o077)
os.makedirs("/root/.secrets", exist_ok=True)
CRED = "setup:" + secrets.token_urlsafe(18)


def api(calls):
    r = urllib.request.Request("http://127.0.0.1:8080/jmap/", data=json.dumps(
        {"using": ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"], "methodCalls": calls}).encode(),
        headers={"Authorization": "Basic " + base64.b64encode(CRED.encode()).decode(),
                 "Content-Type": "application/json"})
    out = json.load(urllib.request.urlopen(r, timeout=60))["methodResponses"]
    for name, args, _ in out:
        if name == "error" or args.get("notUpdated") or args.get("notCreated"):
            sys.exit(f"Stalwart refused: {json.dumps(args)[:400]}")   # error answers carry no secrets
    return out


def restart():
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "restart", "stalwart"], check=True)
    for _ in range(60):   # until the HTTP listener answers (a few seconds after systemd says "started")
        try:
            urllib.request.urlopen("http://127.0.0.1:8080/", timeout=5)
            return
        except urllib.error.HTTPError:   # any HTTP answer means it's up
            return
        except (urllib.error.URLError, OSError):
            time.sleep(1)
    sys.exit("Stalwart didn't answer on 127.0.0.1:8080 within a minute: see journalctl -u stalwart")


setup, key = not os.path.exists(CONFIG), not os.path.exists(KEYFILE)
if not (setup or key):
    print("set up already, API key present: nothing to do")
    sys.exit(0)
try:
    with open(SETUP_ENV, "w") as f:
        f.write(f"STALWART_RECOVERY_ADMIN={CRED}\n")
    os.makedirs(os.path.dirname(DROPIN), exist_ok=True)
    with open(DROPIN, "w") as f:
        f.write(f"[Service]\nEnvironmentFile={SETUP_ENV}\n")
    restart()

    if setup:
        print("== first start: Stalwart's setup, through its API")
        form = api([["x:Bootstrap/get", {"ids": ["singleton"]}, "b"]])[0][1]["list"][0]
        tracer = dict(form["tracer"], ansi=False)   # Stalwart's own log defaults, without color codes
        want = {"defaultHostname": HOST, "requestTlsCertificate": False, "generateDkimKeys": True, "tracer": tracer}
        if DOMAIN:
            want["defaultDomain"] = DOMAIN
        print(f"hostname {HOST}, default domain {DOMAIN or form['defaultDomain']}, certificate from certbot "
              "(no ACME), DKIM keys generated, logs without colors")
        done = api([["x:Bootstrap/set", {"update": {"singleton": want}}, "b"]])[0][1]["updated"]["singleton"]
        with open(ADMIN, "w") as f:
            f.write(f"{done['username']}:{done['secret']}\n")
        print(f"admin account {done['username']}: its password is in {ADMIN} (root only)")
        restart()   # out of bootstrap mode (still with the setup credential, for the key)
        if not os.path.exists(CONFIG):
            sys.exit(f"Stalwart didn't write {CONFIG}: see journalctl -u stalwart")

    if key:
        admins = [a for a in api([["x:Account/get", {"ids": None, "properties": ["name", "roles"]}, "a"]])[0][1]["list"]
                  if (a.get("roles") or {}).get("@type") == "Admin"]
        if not admins:
            sys.exit("no account with the Admin role found: make the API key in the WebUI (see recipe/03 header)")
        owner = next((a for a in admins if a["name"] == "admin"), admins[0])
        made = api([["x:ApiKey/set", {"accountId": owner["id"], "create": {"k": {
            "description": "recipes and server tools (127.0.0.1 only)",
            "allowedIps": {"127.0.0.1": True, "::1": True}}}}, "k"]])[0][1]["created"]["k"]
        with open(KEYFILE, "w") as f:
            f.write(made["secret"] + "\n")
        print(f"API key for the recipes and tools created for {owner['name']}: {KEYFILE} (root only)")
finally:   # the setup credential must never outlive this run
    for p in (DROPIN, SETUP_ENV):
        if os.path.exists(p):
            os.remove(p)
    restart()
print("Stalwart restarted normally (the one-time credential is gone)")
