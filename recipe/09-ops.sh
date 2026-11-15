#!/bin/bash
# recipe/09-ops.sh — quiet operations: you hear from the server only when something needs you.
#   - Weekly release check for software outside the OS repos (Stalwart, Roundcube, identity_smtp, restic):
#     lists newer upstream versions on the dashboard (nv-status) and mails once per new version. Upgrades stay deliberate: read the
#     release notes, then rerun the matching recipe.
#   - OS security updates: dnf-automatic (recipe/01) installs them daily and reboots when needed, silently;
#     a failed run mails via nv-alert@ (OnFailure).
#   - Junk watch (nv-junk-report, daily): mails only when an account's Junk spikes; see tools/ops/.
#   - nv-set-password <login>: set a user's password (typed without echo), then test it with a real IMAP login.
#   - nv-status (every 15 min): the dashboard behind ./nv status; mails only when a critical check turns bad.
# Also installs /etc/nv/site.json, which the tools on the server read.
# Not here on purpose: Cockpit (no web console; SSH keys only), mail summaries of routine updates.
# Not checked: the pinned Stretched Elastic skin commit (recipe/07); look at it when upgrading Roundcube.
# Run from your computer:  ./nv run recipe/09-ops.sh
live && { command -v nv-alert >/dev/null || { echo "run recipe/08-backup.sh first (provides nv-alert)"; exit 1; }; }
systemctl cat nv-alert@.service >/dev/null 2>&1 || { echo "run recipe/08-backup.sh first (provides nv-alert@)"; exit 1; }

echo "== dnf-automatic: alert only on failure"
mkdir -p /etc/systemd/system/dnf-automatic.service.d
put /etc/systemd/system/dnf-automatic.service.d/alert.conf <<'EOF'
[Unit]
OnFailure=nv-alert@%n.service
EOF
# certificate renewal (certbot-renew.timer, twice a day): a failure alerts too, long before anything expires
mkdir -p /etc/systemd/system/certbot-renew.service.d
put /etc/systemd/system/certbot-renew.service.d/alert.conf <<'EOF'
[Unit]
OnFailure=nv-alert@%n.service
EOF

echo "== weekly release check"
install -d -m 700 /var/lib/nv-release-check
put /usr/local/sbin/nv-release-check 700 <<'EOF'
#!/usr/bin/python3 -I
# nv-release-check: which upstream versions are newer than what's installed: listed on the dashboard, and mailed
# once per new version (nothing else is mailed).
# State: /var/lib/nv-release-check/notified (one "name version" per line already reported).
# usage: nv-release-check [--dry]   (--dry: print what it sees, mail nothing, remember nothing)
import json, os, re, subprocess, sys, urllib.request
STATE = "/var/lib/nv-release-check/notified"
DRY = "--dry" in sys.argv

def gh(path):
    req = urllib.request.Request("https://api.github.com/repos/" + path, headers={"User-Agent": "nv-release-check"})
    return json.load(urllib.request.urlopen(req, timeout=30))
def latest_release(repo): return gh(repo + "/releases/latest")["tag_name"].lstrip("v")
def latest_tag(repo): return max((t["name"].lstrip("v") for t in gh(repo + "/tags")), key=lambda s: ver(s))
def ver(s): return tuple(int(x) for x in re.findall(r"\d+", s)[:3])
def out(cmd):
    try: return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout
    except Exception: return ""
def first_ver(s):
    m = re.search(r"\d+\.\d+\.\d+", s or ""); return m.group(0) if m else None
def read(p):
    try: return open(p).read().strip()
    except OSError: return None

checks = [   # name, installed version, latest (callable), where to read the notes
    ("Stalwart",      first_ver(out(["/usr/local/bin/stalwart", "--version"])),
     lambda: latest_release("stalwartlabs/stalwart"), "https://github.com/stalwartlabs/stalwart/releases"),
    ("Roundcube",     first_ver(os.path.realpath("/var/www/roundcube")),
     lambda: latest_release("roundcube/roundcubemail"), "https://github.com/roundcube/roundcubemail/releases"),
    ("identity_smtp", read("/var/www/roundcube/plugins/identity_smtp/.nv-version"),
     lambda: latest_tag("deflomu/Roundcube-SMTP-per-Identity-Plugin"), "https://github.com/deflomu/Roundcube-SMTP-per-Identity-Plugin/tags"),
    ("restic",        first_ver(out(["/usr/local/bin/restic", "version"])),
     lambda: latest_release("restic/restic"), "https://github.com/restic/restic/releases"),
]
seen = set((read(STATE) or "").splitlines())
new, problems, avail = [], [], []
for name, have, latest, url in checks:
    if name == "identity_smtp" and not have: continue   # optional plugin (webmail.identity_smtp), not installed
    try:
        l = latest()
    except Exception as e:
        problems.append(f"{name}: couldn't check ({e})"); continue
    if DRY: print(f"{name:14} installed {have}  latest {l}")
    if not have: problems.append(f"{name}: installed version unknown"); continue
    if ver(l) > ver(have): avail.append(f"{name} {l}")
    if ver(l) > ver(have) and f"{name} {l}" not in seen:
        new.append(f"{name}: installed {have}, latest {l}\n    {url}")
        seen.add(f"{name} {l}")
if DRY:
    print("available:", avail or "nothing new"); print("problems:", problems or "none"); sys.exit(0)
# for the dashboard (nv-status): what's newer than installed right now.
if len(problems) < len(checks):
    with open(STATE + ".available.tmp", "w") as f: f.write("\n".join(avail) + ("\n" if avail else ""))
    os.replace(STATE + ".available.tmp", os.path.join(os.path.dirname(STATE), "available"))
if new:
    body = ("Newer versions are out:\n\n" + "\n".join(new) + "\n\nRead every release's notes between your version and the new "
            "one, then upgrade as the recipe header says (docs/operations.md, Upgrades). ./nv status lists them too.\n")
    subject = "new release: " + ", ".join(n.split(":")[0] for n in new)
    # remembered only once the mail went out, so a failed alert is tried again next week
    if subprocess.run(["/usr/local/sbin/nv-alert", subject], input=body.encode()).returncode == 0:
        with open(STATE + ".tmp", "w") as f: f.write("\n".join(sorted(seen)) + "\n")
        os.replace(STATE + ".tmp", STATE)
# GitHub hiccups are normal; only a run where every check failed counts as a failure (OnFailure mails)
if problems and len(problems) == len(checks):
    print("\n".join(problems), file=sys.stderr); sys.exit(1)
EOF
chmod 700 /usr/local/sbin/nv-release-check
put /etc/systemd/system/nv-release-check.service <<'EOF'
[Unit]
Description=Weekly check for newer Stalwart/Roundcube/identity_smtp/restic releases (dashboard, and one mail per new version)
After=network-online.target
Wants=network-online.target
OnFailure=nv-alert@%n.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nv-release-check
EOF
put /etc/systemd/system/nv-release-check.timer <<'EOF'
[Unit]
Description=Weekly release check
[Timer]
OnCalendar=Mon 14:00 UTC
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable -q --now nv-release-check.timer
run /usr/local/sbin/nv-release-check --dry

echo "== site settings for the tools: /etc/nv/site.json (the tools read their accounts and sources from it)"
install -d -m 700 /etc/nv
printf '%s' "$NV_SITE_JSON" | put /etc/nv/site.json 600

echo "== ops tools: Junk report (daily prune; spikes on the dashboard), nv-set-password, nv-status (dashboard)"
install -d -m 755 /usr/local/lib/nv
repo_file tools/lib/nvlib.py | put /usr/local/lib/nv/nvlib.py 644   # shared by the tools here and in recipe/11
repo_file tools/ops/nv-junk-report.py | put /usr/local/sbin/nv-junk-report 700
repo_file tools/ops/nv-set-password.py | put /usr/local/sbin/nv-set-password 700
repo_file tools/ops/nv-junk-report.service | put /etc/systemd/system/nv-junk-report.service
repo_file tools/ops/nv-junk-report.timer | put /etc/systemd/system/nv-junk-report.timer
repo_file tools/ops/nv-status.py | put /usr/local/sbin/nv-status 700
repo_file tools/ops/nv-status.service | put /etc/systemd/system/nv-status.service
repo_file tools/ops/nv-status.timer | put /etc/systemd/system/nv-status.timer
systemctl daemon-reload
systemctl enable -q --now nv-junk-report.timer
systemctl enable -q --now nv-status.timer
if live; then /usr/local/sbin/nv-status --print | head -40; fi   # first run: what the dashboard shows
