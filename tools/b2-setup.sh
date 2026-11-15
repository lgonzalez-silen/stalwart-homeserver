#!/bin/bash
# tools/b2-setup.sh — the B2 side of recipe/08, from your computer, in one command (yours to run: it reads your
# password manager):
#   ./nv sh tools/b2-setup.sh [--dry] [--replace-key]
# 1. bucket backup.bucket: created private with the 30-day rule (deleted files stay recoverable for 30 days), or
#    an existing one checked and fixed (made private, rule added). A rule that hides files by age stops it.
# 2. key: a new key for that bucket only that can list, read and write but not delete (a break-in on the server
#    can't wipe the backups), unless the server already has /root/.secrets/restic.env (kept; --replace-key makes
#    a new one and deletes this server's older keys).
# 3. /root/.secrets/restic.env on the server (0600). Nothing secret is printed or put on a command line.
# Settings (backup.*): bucket, path (folder in the bucket, default "nv"), and where your password manager keeps
# the secrets, as 1Password references ("op://<vault>/<item>/<field>"): b2_master_key_id, b2_master_key (the
# account's master application key, Backblaze › App Keys), restic_password (made and saved for you if that item
# doesn't exist yet: keep it, the backups can't be read without it), op_account (if you have several 1Password
# accounts). A setting left empty is asked for at a no-echo prompt instead.
exec python3 -I - "$@" <<'PY'
import base64, getpass, json, os, subprocess, sys, urllib.error, urllib.request

DRY, REPLACE = "--dry" in sys.argv, "--replace-key" in sys.argv
E = lambda k, d="": os.environ.get("NV_" + k, "") or d
HOST, BUCKET, PATH = E("SERVER_HOSTNAME"), E("BACKUP_BUCKET"), E("BACKUP_PATH", "nv")
if not (HOST and BUCKET):
    sys.exit("set server.hostname and backup.bucket in site.json")
OPENV = {**os.environ, **({"OP_ACCOUNT": E("BACKUP_OP_ACCOUNT")} if E("BACKUP_OP_ACCOUNT") else {})}

def secret(setting, label, create=False):
    ref = E("BACKUP_" + setting.upper())
    if not ref.startswith("op://"):
        return getpass.getpass(f"{label} (backup.{setting} is not set; typing is hidden): ").strip() or sys.exit("empty")
    r = subprocess.run(["op", "read", ref], capture_output=True, text=True, env=OPENV)
    if r.returncode == 0 and r.stdout.strip():
        return r.stdout.strip()
    vault, item, field = (ref[5:].split("/") + ["", "", ""])[:3]
    if not (create and field == "password" and "isn't an item" in r.stderr):
        sys.exit(f"could not read backup.{setting} ({ref}): {r.stderr.strip()[:200]}")
    if DRY:
        print(f"would: create the 1Password item '{item}' in '{vault}' with a new random password"); return "<new>"
    c = subprocess.run(["op", "item", "create", "--category", "password", "--vault", vault, "--title", item,
                        "--generate-password=letters,digits,40"], capture_output=True, text=True, env=OPENV)
    if c.returncode:
        sys.exit(f"could not create {item}: {c.stderr.strip()[:200]}")
    print(f"created 1Password item '{item}' in '{vault}' with a new restic password (keep it)")
    return secret(setting, label)

def ssh(cmd, data=None):
    return subprocess.run(["ssh", "-o", "ControlMaster=no", f"root@{HOST}", cmd], input=data, capture_output=True, text=True)

kid, key = secret("b2_master_key_id", "B2 master key id"), secret("b2_master_key", "B2 master application key")
try:
    a = json.load(urllib.request.urlopen(urllib.request.Request("https://api.backblazeb2.com/b2api/v3/b2_authorize_account",
        headers={"Authorization": "Basic " + base64.b64encode(f"{kid}:{key}".encode()).decode()}), timeout=60))
except urllib.error.HTTPError as e:
    sys.exit(f"B2 refused the master key: HTTP {e.code}")
del key
API, ACCT = a["apiInfo"]["storageApi"]["apiUrl"], a["accountId"]
if "writeKeys" not in a["apiInfo"]["storageApi"]["capabilities"]:
    sys.exit("that key can't create keys: use the account's master application key")

def b2(name, body):
    r = urllib.request.Request(f"{API}/b2api/v3/{name}", data=json.dumps(body).encode(), headers={"Authorization": a["authorizationToken"]})
    try:
        return json.load(urllib.request.urlopen(r, timeout=60))
    except urllib.error.HTTPError as e:
        sys.exit(f"{name}: HTTP {e.code} {e.read().decode()[:300]}")

def do(what, name, body):
    print(("would: " if DRY else "") + what)
    return None if DRY else b2(name, body)

RULE = {"fileNamePrefix": "", "daysFromHidingToDeleting": 30, "daysFromUploadingToHiding": None}
found = b2("b2_list_buckets", {"accountId": ACCT, "bucketName": BUCKET})["buckets"]
if not found:
    made = do(f"create bucket {BUCKET}: private, deleted files kept 30 days", "b2_create_bucket",
              {"accountId": ACCT, "bucketName": BUCKET, "bucketType": "allPrivate", "lifecycleRules": [RULE]})
    bid = made and made["bucketId"]
else:
    bk = found[0]; bid = bk["bucketId"]; rules = bk.get("lifecycleRules") or []
    if any(r.get("daysFromUploadingToHiding") for r in rules):
        sys.exit(f"{BUCKET} has a rule that hides files by age (it would expire backups): remove it in Backblaze first")
    fix = {}
    if bk["bucketType"] != "allPrivate":
        fix["bucketType"] = "allPrivate"
    if not any(r.get("fileNamePrefix") == "" and (r.get("daysFromHidingToDeleting") or 0) >= 30 for r in rules):
        fix["lifecycleRules"] = [r for r in rules if r.get("fileNamePrefix") != ""] + [RULE]
    if fix:
        do(f"bucket {BUCKET}: " + ", ".join({"bucketType": "make private", "lifecycleRules": "keep deleted files 30 days"}[k] for k in fix),
           "b2_update_bucket", {"accountId": ACCT, "bucketId": bid, **fix})
    else:
        print(f"bucket {BUCKET}: private, deleted files kept 30 days (good)")

has_env = ssh("test -s /root/.secrets/restic.env").returncode == 0
if has_env and not REPLACE:
    print("server already has /root/.secrets/restic.env: key kept (--replace-key makes a new one)")
    sys.exit()
pw = secret("restic_password", "restic password", create=True)
NAME = "restic-" + HOST.replace(".", "-")
k = do(f"create key {NAME} for {BUCKET} only: list, read, write (no delete)", "b2_create_key",
       {"accountId": ACCT, "keyName": NAME, "bucketId": bid, "capabilities": ["listBuckets", "listFiles", "readFiles", "writeFiles"]})
if DRY:
    print(f"would: write /root/.secrets/restic.env on {HOST} (repository b2:{BUCKET}:{PATH})"); sys.exit()
env = (f"RESTIC_REPOSITORY=b2:{BUCKET}:{PATH}\nRESTIC_PASSWORD={pw}\n"
       f"B2_ACCOUNT_ID={k['applicationKeyId']}\nB2_ACCOUNT_KEY={k['applicationKey']}\n")
w = ssh("umask 077; mkdir -p /root/.secrets; cat > /root/.secrets/restic.env.new && mv /root/.secrets/restic.env.new /root/.secrets/restic.env", env)
if w.returncode:
    b2("b2_delete_key", {"applicationKeyId": k["applicationKeyId"]})
    sys.exit(f"could not write restic.env on {HOST} (the new key was deleted again): {w.stderr.strip()[:200]}")
print(f"wrote /root/.secrets/restic.env on {HOST} (repository b2:{BUCKET}:{PATH}, key {k['applicationKeyId']})")
if REPLACE:
    keys = b2("b2_list_keys", {"accountId": ACCT, "maxKeyCount": 1000})["keys"]
    for old in [x for x in keys if x["keyName"] == NAME and x["applicationKeyId"] != k["applicationKeyId"]]:
        b2("b2_delete_key", {"applicationKeyId": old["applicationKeyId"]}); print(f"deleted older key {old['applicationKeyId']}")
print("next: ./nv run recipe/08-backup.sh")
PY
