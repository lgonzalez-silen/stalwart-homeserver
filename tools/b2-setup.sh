#!/bin/bash
# tools/b2-setup.sh — the B2 side of recipe/08, from your computer, in one command (yours to run: it reads your
# password manager):
#   ./nv sh tools/b2-setup.sh [--dry] [--replace-key]
# 1. bucket backup.bucket: created private with the 30-day rule (deleted files stay recoverable for 30 days), or
#    an existing one checked and fixed (made private, rule added). A rule that hides files by age stops it.
# 2. key: a new key for that bucket only that can list, read and write but not delete (a break-in on the server
#    can't wipe the backups), unless the server already has /root/.secrets/restic.env (kept; --replace-key makes
#    a new one and deletes the older ones). After a restore, the old server's key is listed, not deleted: delete
#    it once recipe 08 passes.
# 3. /root/.secrets/restic.env on the server (0600). Nothing secret is printed or put on a command line.
#    --replace-key changes only the key lines. A repository already in the bucket (a restore) keeps its password:
#    the tool never offers a new one for it.
# Settings (backup.*): bucket, path (folder in the bucket, default "nv"), and where the three secrets come from:
# b2_master_key_id, b2_master_key (the account's master application key, Backblaze › App Keys), restic_password.
# Any password manager works. Each is one of:
#   "cmd:<command that prints it>"   e.g. "cmd:bw get password b2-master" (Bitwarden), "cmd:pass show b2/master",
#                                    "cmd:security find-generic-password -w -s b2-master" (macOS Keychain)
#   "op://<vault>/<item>/<field>"    1Password (op_account: which account, if you have several); for
#                                    restic_password the item is created with a new password if it doesn't exist
#   empty                            asked at a hidden prompt; for restic_password, Enter makes one and shows it
#                                    once for you to save
# Keep the restic password: the backups can't be read without it.
exec python3 -I - "$@" <<'PY'
import base64, getpass, json, os, shlex, subprocess, sys, urllib.error, urllib.request

DRY, REPLACE = "--dry" in sys.argv, "--replace-key" in sys.argv
E = lambda k, d="": os.environ.get("NV_" + k, "") or d
HOST, BUCKET, PATH = E("SERVER_HOSTNAME"), E("BACKUP_BUCKET"), E("BACKUP_PATH", "nv")
if not (HOST and BUCKET):
    sys.exit("set server.hostname and backup.bucket in site.json")
OPENV = {**os.environ, **({"OP_ACCOUNT": E("BACKUP_OP_ACCOUNT")} if E("BACKUP_OP_ACCOUNT") else {})}

try:   # stdin is this script (heredoc): prompts and answers go through the terminal, when there is one
    TTY, TTYOUT = open("/dev/tty"), open("/dev/tty", "w")   # two handles: a terminal can't be opened "r+" (no seeking)
except OSError:
    TTY = TTYOUT = None

def secret(setting, label, create=False):
    ref = E("BACKUP_" + setting.upper())
    if ref.startswith("cmd:"):   # any password manager's CLI: the command prints the secret (its prompts stay visible)
        r = subprocess.run(ref[4:], shell=True, stdin=TTY, stdout=subprocess.PIPE, text=True)
        if r.returncode or not r.stdout.strip():
            sys.exit(f"backup.{setting}: the command failed (exit {r.returncode})")
        return r.stdout.strip()
    if ref and not ref.startswith("op://"):
        sys.exit(f"backup.{setting} must be \"cmd:...\", \"op://...\" or empty, never the secret itself (site.json is a "
                 f"file in your site repo: secrets belong in your password manager)")
    if not ref:
        hint = " (Enter: make one)" if create else ""
        v = getpass.getpass(f"{label}{hint} (backup.{setting} is not set; typing is hidden): ").strip()
        if v or not create:
            return v or sys.exit("empty")
        if DRY:
            print("would: make a new restic password and show it once"); return "<new>"
        if TTY is None:
            sys.exit("no terminal to show a new restic password on: run this in your own terminal")
        import secrets
        v = secrets.token_urlsafe(30)
        TTYOUT.write(f"\nNew restic password, shown once. Save it in your password manager NOW: without it the backups\n"
                     f"can't be read, by anyone.\n\n    {v}\n\n"); TTYOUT.flush()
        while True:
            TTYOUT.write("Type its last 4 characters to confirm you saved it: "); TTYOUT.flush()
            if TTY.readline().strip() == v[-4:]: break
            TTYOUT.write("doesn't match: check what you saved\n")
        TTYOUT.write("\033[2J\033[3J\033[H"); TTYOUT.flush()   # clear the screen and its scrollback: the password doesn't stay
        return v
    r = subprocess.run(["op", "read", ref], stdin=TTY, capture_output=True, text=True, env=OPENV)
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
    # the same rules recipe 08 checks: nothing hidden by age, nothing hidden deleted in under 30 days
    if any(r.get("daysFromUploadingToHiding") for r in rules):
        sys.exit(f"{BUCKET} has a rule that hides files by age (it would expire backups): remove it in Backblaze first")
    if any(r.get("daysFromHidingToDeleting") is not None and r["daysFromHidingToDeleting"] < 30 for r in rules):
        sys.exit(f"{BUCKET} has a rule deleting hidden files in under 30 days: remove it in Backblaze first")
    fix = {}
    if bk["bucketType"] != "allPrivate":
        fix["bucketType"] = "allPrivate"
    if not any(r.get("fileNamePrefix") == "" and (r.get("daysFromHidingToDeleting") or 0) >= 30 for r in rules):
        if rules:
            sys.exit(f"{BUCKET} has other lifecycle rules: remove them in Backblaze, then run this again (it adds the 30-day rule)")
        fix["lifecycleRules"] = [RULE]
    if fix:
        do(f"bucket {BUCKET}: " + ", ".join({"bucketType": "make private", "lifecycleRules": "keep deleted files 30 days"}[k] for k in fix),
           "b2_update_bucket", {"accountId": ACCT, "bucketId": bid, **fix})
    else:
        print(f"bucket {BUCKET}: private, deleted files kept 30 days (good)")

has_env = ssh("test -s /root/.secrets/restic.env").returncode == 0
if has_env and not REPLACE:
    print("server already has /root/.secrets/restic.env: key kept (--replace-key makes a new one)")
    sys.exit()
NAME = "restic-" + HOST.replace(".", "-")
if has_env:   # --replace-key: only the key lines change; the repository and its password on the server stay as they are
    pw, what = None, f"put the new key in /root/.secrets/restic.env on {HOST} (repository and password unchanged)"
else:
    # a repository already in the bucket (restoring to a new server): its password must be the existing one, never a new one
    existing = bid and b2("b2_list_file_names", {"bucketId": bid, "prefix": f"{PATH}/config", "maxFileCount": 1})["files"]
    if existing:
        print(f"b2:{BUCKET}:{PATH} already holds a repository: using its restic password (it can't be replaced)")
    pw = secret("restic_password", "restic password of that repository" if existing else "restic password", create=not existing)
    if "\n" in pw:
        sys.exit("the restic password spans several lines: use a one-line password")
    what = f"write /root/.secrets/restic.env on {HOST} (repository b2:{BUCKET}:{PATH})"
k = do(f"create key {NAME} for {BUCKET} only: list, read, write (no delete)", "b2_create_key",
       {"accountId": ACCT, "keyName": NAME, "bucketId": bid, "capabilities": ["listBuckets", "listFiles", "readFiles", "writeFiles"]})
if DRY:
    print("would: " + what); sys.exit()
q = shlex.quote   # restic.env is read with the shell's "." (a $ or ` in a password must stay literal)
keylines = f"B2_ACCOUNT_ID={q(k['applicationKeyId'])}\nB2_ACCOUNT_KEY={q(k['applicationKey'])}\n"
if has_env:
    w = ssh("umask 077; f=/root/.secrets/restic.env; { grep -vE '^B2_ACCOUNT_(ID|KEY)=' $f; cat; } > $f.new && mv $f.new $f", keylines)
else:
    w = ssh("umask 077; mkdir -p /root/.secrets; cat > /root/.secrets/restic.env.new && mv /root/.secrets/restic.env.new /root/.secrets/restic.env",
            f"RESTIC_REPOSITORY={q(f'b2:{BUCKET}:{PATH}')}\nRESTIC_PASSWORD={q(pw)}\n" + keylines)
if w.returncode:
    b2("b2_delete_key", {"applicationKeyId": k["applicationKeyId"]})
    sys.exit(f"could not write restic.env on {HOST} (the new key was deleted again): {w.stderr.strip()[:200]}")
print(f"wrote /root/.secrets/restic.env on {HOST} (repository b2:{BUCKET}:{PATH}, key {k['applicationKeyId']})")
older = [x["applicationKeyId"] for x in b2("b2_list_keys", {"accountId": ACCT, "maxKeyCount": 1000})["keys"]
         if x["keyName"] == NAME and x["applicationKeyId"] != k["applicationKeyId"]]
if REPLACE:   # same repository and password, new key in place: the old ones go
    for old in older:
        b2("b2_delete_key", {"applicationKeyId": old}); print(f"deleted older key {old}")
elif older:   # e.g. the server a restore replaces: kept until recipe 08 has proved the new setup works
    print(f"older keys of this server still work: {', '.join(older)}. Once recipe 08 passes, delete them in Backblaze "
          f"(App Keys), or run this again with --replace-key")
print("next: ./nv run recipe/08-backup.sh")
PY
