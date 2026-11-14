#!/usr/bin/python3 -I
# nv-set-password <login>   e.g.  nv-set-password alice
# Asks for a new password (not echoed, twice), stores it on the Stalwart account, then verifies it with a real
# IMAP login on localhost. Run it interactively over ssh -t; the password never appears in logs or arguments.
# --random: set a random password instead of prompting (used to test this script on unused accounts).
import sys, json, getpass, imaplib, ssl, secrets, subprocess, urllib.request
K = open("/root/.secrets/laptop-api.key").read().strip(); API = "http://127.0.0.1:8080/jmap/"
def j(calls):
    r = urllib.request.Request(API, data=json.dumps({"using": ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"], "methodCalls": calls}).encode(),
                               headers={"Authorization": "Bearer " + K, "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=30))["methodResponses"]

login = sys.argv[1]
login = login.split("@")[0]
accts = [a for a in j([["x:Account/get", {"properties": ["name", "domainId", "credentials"]}, "a"]])[0][1]["list"] if a["name"] == login]
if len(accts) != 1: sys.exit(f"no single account named {login!r}")
a = accts[0]
cred = [cid for cid, c in (a.get("credentials") or {}).items() if c.get("@type") == "Password"]
if len(cred) != 1: sys.exit(f"expected one Password credential on {login}, found {len(cred)}")

if "--random" in sys.argv:
    pw = secrets.token_urlsafe(24)
else:
    pw = getpass.getpass(f"New password for {login}: ")
    if pw != getpass.getpass("Again: "): sys.exit("passwords don't match; nothing changed")
    if len(pw) < 6: sys.exit("too short; nothing changed")

# store a SHA-512 crypt hash ($6$), like the migrated accounts, not the plain password
hashed = subprocess.run(["openssl", "passwd", "-6", "-stdin"], input=pw.encode(), capture_output=True, check=True).stdout.decode().strip()
assert hashed.startswith("$6$")
r = j([["x:Account/set", {"update": {a["id"]: {f"credentials/{cred[0]}/secret": hashed}}}, "s"]])[0][1]
if a["id"] not in (r.get("updated") or {}): sys.exit(f"update failed: {r.get('notUpdated') or r}")

# IMAP login name: bare name only works for the default domain; others need name@domain
dom = j([["x:Domain/get", {"ids": [a["domainId"]], "properties": ["name"]}, "d"]])[0][1]["list"][0]["name"]
user = f"{login}@{dom}"
ok = False
try:
    m = imaplib.IMAP4_SSL("127.0.0.1", 993, ssl_context=ssl._create_unverified_context())
    m.login(user, pw); m.logout(); ok = True
except Exception as e:
    print("verify login failed:", e)
print(f"{user}: password updated; IMAP login as {user}: {'OK' if ok else 'FAILED'}")
