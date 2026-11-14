#!/usr/bin/python3 -I
# nv-fetch-secret <source>   store the Google app password for one fetch source, then test an IMAP login with it.
# Sources: google.sources[].name in site.json. Run interactively:  ssh -t root@<server> nv-fetch-secret <name>
# The password is read without echo and saved to /root/.secrets/fetch/<source>.pw (root-only); it never appears in
# arguments, logs or output. Google shows app passwords with spaces; they're removed.
import sys, os, json, getpass, imaplib

SITE = json.load(open(os.environ.get("NV_SITE", "/etc/nv/site.json")))   # installed by recipe/09-ops.sh
SOURCES = {s["name"]: s["user"] for s in SITE["google"]["sources"]}
if len(sys.argv) != 2 or sys.argv[1] not in SOURCES:
    sys.exit("usage: nv-fetch-secret " + "|".join(SOURCES))
src = sys.argv[1]; user = SOURCES[src]

pw = getpass.getpass(f"App password for {user} (spaces are fine): ").replace(" ", "").strip()
if len(pw) != 16 or not pw.isalpha():
    sys.exit("that doesn't look like a Google app password (16 letters); nothing saved")

try:
    m = imaplib.IMAP4_SSL("imap.gmail.com", 993, timeout=30)
    m.login(user, pw)
    typ, boxes = m.list()
    m.logout()
except imaplib.IMAP4.error as e:
    msg = str(e)
    hint = (" -> IMAP is turned off: Gmail Settings > See all settings > Forwarding and POP/IMAP > Enable IMAP"
            if "not enabled for imap" in msg.lower() or "imap access is disabled" in msg.lower() else "")
    sys.exit(f"login failed for {user}: {msg}{hint}\nnothing saved")

os.makedirs("/root/.secrets/fetch", mode=0o700, exist_ok=True)
path = f"/root/.secrets/fetch/{src}.pw"
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(pw + "\n")
print(f"{user}: IMAP login OK ({len(boxes)} folders/labels visible); saved to {path}")
