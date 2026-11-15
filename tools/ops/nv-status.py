#!/usr/bin/python3 -I
# nv-status: everything that could need your attention, in one place. Runs every 15 minutes (timer, recipe/09):
# checks the server, keeps a history in SQLite (for trends), and writes /var/lib/nv-status/status.json.
# View it from your computer:  ./nv status          (or  ./nv status --html  for a page with trend lines)
#
# Mail only for things to act on within hours, once when a check turns bad (and once when it recovers):
#   Stalwart not running, disk > 90%, a certificate with < 14 days left, no good backup for > 48 h,
#   a Google pull with no successful check for > 6 h.
# Everything else (new releases, Junk spikes, OS updates, bans, skipped messages) only shows on the dashboard.
#
# usage: nv-status            collect, store, write status.json, alert on changes
#        nv-status --print    the same, and print the summary (no alerts)
import os, sys, json, glob, re, time, sqlite3, shutil, datetime, subprocess
sys.path.insert(0, "/usr/local/lib/nv"); sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))  # repo copy last
from nvlib import jmap, site, ADMIN  # noqa: E402

DIR = "/var/lib/nv-status"
PRINT = "--print" in sys.argv
NOW = datetime.datetime.now(datetime.timezone.utc)
SITE = site()
checks = []   # dicts: id, group, title, state (ok/warn/crit), summary, value (number or None), unit, critical


def add(cid, group, title, state, summary, value=None, unit="", critical=False):
    checks.append({"id": cid, "group": group, "title": title, "state": state, "summary": summary,
                   "value": value, "unit": unit, "critical": critical})


def run(*cmd, timeout=60):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip()


def unit_result(name):
    """(result, finished_at or None) of a systemd service's last run."""
    _, out = run("systemctl", "show", name, "-p", "Result", "-p", "ExecMainExitTimestamp", "--value")
    lines = (out.splitlines() + ["", ""])[:2]
    res, ts = lines[0], lines[1]
    at = None
    if ts and ts != "n/a":
        try:
            at = datetime.datetime.strptime(" ".join(ts.split()[1:3]), "%Y-%m-%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc) \
                if ts.split()[-1] == "UTC" else None
        except ValueError:
            at = None
    return res, at


def hours_since(at):
    return (NOW - at).total_seconds() / 3600 if at else None


def guard(fn):
    """A check that breaks shows up as a warning on the dashboard, instead of stopping the others."""
    def wrapped():
        try:
            fn()
        except Exception as e:
            add(fn.__name__, "status", fn.__name__.replace("check_", ""), "warn", f"check failed: {type(e).__name__}: {e}"[:200])
    return wrapped


@guard
def check_stalwart():
    code, _ = run("systemctl", "is-active", "--quiet", "stalwart")
    _, ver = run("/usr/local/bin/stalwart", "--version")
    add("stalwart", "server", "Stalwart", "ok" if code == 0 else "crit",
        (ver.split()[-1] + " running") if code == 0 else "NOT RUNNING: systemctl status stalwart", critical=True)


@guard
def check_disk():
    u = shutil.disk_usage("/")
    pct = round(100 * u.used / u.total, 1)
    add("disk", "server", "Disk /", "crit" if pct > 90 else "warn" if pct > 85 else "ok",
        f"{pct}% used, {u.free / 1e9:.0f} GB free", pct, "%", critical=True)


@guard
def check_memory():
    m = dict(re.findall(r"^(\w+):\s+(\d+)", open("/proc/meminfo").read(), re.M))
    avail = round(100 * int(m["MemAvailable"]) / int(m["MemTotal"]), 1)
    add("memory", "server", "Memory", "warn" if avail < 10 else "ok", f"{avail}% available", avail, "%")


@guard
def check_certs():
    worst = None
    for f in glob.glob("/etc/letsencrypt/live/*/cert.pem"):
        _, end = run("openssl", "x509", "-enddate", "-noout", "-in", f)
        exp = datetime.datetime.strptime(end.split("=", 1)[1].replace("  ", " "), "%b %d %H:%M:%S %Y GMT").replace(tzinfo=datetime.timezone.utc)
        days = (exp - NOW).days
        if worst is None or days < worst[0]:
            worst = (days, os.path.basename(os.path.dirname(f)))
    if worst:
        add("certs", "server", "Certificates", "crit" if worst[0] < 14 else "warn" if worst[0] < 21 else "ok",
            f"soonest: {worst[1]} in {worst[0]} days (renewal starts at 30)", worst[0], "days", critical=True)


@guard
def check_os():
    code, _ = run("dnf", "-q", "needs-restarting", "-r")
    code2, out = run("dnf", "-q", "--cacheonly", "check-update", timeout=120)
    n = len([l for l in out.splitlines() if l and not l.startswith(" ")]) if code2 == 100 else 0
    _, sec = run("dnf", "-q", "--cacheonly", "updateinfo", "list", "--security", timeout=120)
    nsec = len([l for l in sec.splitlines() if l.strip()])
    state = "warn" if code == 1 or nsec else "ok"
    add("os", "server", "OS updates", state,
        ("REBOOT NEEDED (dnf-automatic reboots on its own when an update needs it); " if code == 1 else "") +
        (f"{nsec} SECURITY updates not installed yet (dnf-automatic runs daily: check journalctl -u dnf-automatic); " if nsec else "") +
        (f"{n} updates waiting; security ones install daily, the rest when you run `dnf upgrade`" if n else "up to date"),
        n, "updates")


def stamp(path):
    """First field of a small status file the backup scripts write (ISO time), as a datetime, or None."""
    try:
        return datetime.datetime.strptime(open(path).read().split()[0], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except (OSError, ValueError, IndexError):
        return None


@guard
def check_backup():
    res, at = unit_result("nv-backup.service")
    ok_at = stamp("/var/backups/nv/last-backup-ok")   # written by nv-backup on success; survives reboots
    if ok_at and (at is None or res == "success"):
        at = ok_at if at is None or ok_at > at else at
    age = hours_since(at)
    if at is None:   # never ran yet (a new server): not an alarm until the timer has had two nights
        _, since = run("systemctl", "show", "nv-backup.timer", "-p", "ActiveEnterTimestamp", "--value")
        try:
            t = datetime.datetime.strptime(" ".join(since.split()[1:3]), "%Y-%m-%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc)
        except (ValueError, IndexError):
            t = None
        waited = hours_since(t)
        state = "crit" if waited is not None and waited > 48 else "warn"
        summary = "no backup has run yet" + ("" if state == "crit" else " (the first one runs tonight, 03:15 UTC)")
    elif res != "success":
        state, summary = "crit", f"last run FAILED ({res}): journalctl -u nv-backup -n 50"
    else:
        state = "crit" if age > 48 else "warn" if age > 30 else "ok"
        summary = f"last good backup {age:.0f} h ago"
    add("backup", "backups", "Nightly backup", state, summary, round(age, 1) if age is not None else None, "h", critical=True)
    try:   # written by nv-backup-check: "<time> OK" or "<time> FAILED (exit n)"; survives reboots
        chk = open("/var/backups/nv/last-check").read().split(None, 1)
    except OSError:
        chk = []
    if chk:
        add("backup-check", "backups", "Monthly backup check", "ok" if chk[1].strip() == "OK" else "warn",
            f"last check {chk[0][:10]}: {chk[1].strip()}")
    else:
        res2, at2 = unit_result("nv-backup-check.service")   # never-run units report "success": use the timestamp
        add("backup-check", "backups", "Monthly backup check", "warn" if at2 and res2 != "success" else "ok",
            (f"last check: {res2}, {at2:%Y-%m-%d}" if at2 else "no check recorded yet (runs on the 1st)"))


@guard
def check_releases():
    p = "/var/lib/nv-release-check/available"
    avail = [l.strip() for l in open(p)] if os.path.exists(p) else []
    avail = [a for a in avail if a]
    add("releases", "software", "New releases", "warn" if avail else "ok",
        ("available: " + ", ".join(avail) + " (read the release notes, then upgrade)") if avail else "everything current (weekly check)")


@guard
def check_google():
    src = SITE.get("google", {}).get("sources", [])
    if not src or not os.path.exists("/var/lib/nv-fetch/state.db"):
        return
    c = sqlite3.connect("file:/var/lib/nv-fetch/state.db?mode=ro", uri=True, timeout=30)
    has_pass = c.execute("select 1 from sqlite_master where name='pass'").fetchone()
    week = (NOW - datetime.timedelta(days=7)).isoformat(timespec="seconds")
    for s in src:
        name = s["name"]
        if not s.get("enabled", True):
            add(f"pull-{name}", "google", f"Pull {name}", "ok", "paused (enabled: false)"); continue
        ok_at, err = None, ""
        if has_pass:
            row = c.execute("select ok_at, err_at, err from pass where src=?", (name,)).fetchone()
            if row:
                ok_at = datetime.datetime.fromisoformat(row[0]) if row[0] else None
                if row[1] and (not row[0] or row[1] > row[0]): err = row[2] or ""
        age = hours_since(ok_at)
        skipped = c.execute("select count(*) from done where src=? and result in ('rejected','fetch-failed') and at>?",
                            (name, week)).fetchone()[0]
        state = "crit" if age is None or age > 6 else "warn" if age > 0.5 or err or skipped else "ok"
        summary = (f"last good check {age * 60:.0f} min ago" if age is not None else "no successful check recorded") + \
                  (f"; last error: {err[:120]}" if err else "") + (f"; {skipped} message(s) skipped this week (alerted)" if skipped else "")
        add(f"pull-{name}", "google", f"Pull {name}", state, summary, round(age * 60, 1) if age is not None else None, "min",
            critical=True)
    for unit, title in (("nv-spam-mirror.service", "Spam mirror"), ("nv-google-trim.service", "Trim")):
        res, at = unit_result(unit)
        add(unit.split(".")[0], "google", title, "warn" if at and res != "success" else "ok",
            (f"last run: {res}, {at:%Y-%m-%d %H:%M} UTC" if at else "not run yet"))
    if c.execute("select 1 from sqlite_master where name='spam_mirror'").fetchone():
        n = c.execute("select count(*) from spam_mirror where status='skipped' and at>?", (week,)).fetchone()[0]
        if n:
            add("spam-skipped", "google", "Spam mirror skips", "warn", f"{n} message(s) not mirrored this week (still in Gmail's Spam)")


@guard
def check_junk():
    accts = {a["id"]: a["name"] for a in jmap([["x:Account/get", {"properties": ["name"]}, "a"]], using=ADMIN)[0][1]["list"]
             if a["name"] != "admin"}
    day = NOW - datetime.timedelta(days=1)
    iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
    for acct, name in sorted(accts.items(), key=lambda x: x[1]):
        mb = jmap([["Mailbox/get", {"accountId": acct, "properties": ["role"]}, "m"]])[0][1]["list"]
        junk = [m["id"] for m in mb if m.get("role") == "junk"]
        if not junk: continue
        q = lambda after, before: jmap([["Email/query", {"accountId": acct, "filter": {"inMailbox": junk[0], "after": iso(after),
                                          "before": iso(before)}, "calculateTotal": True, "limit": 0}, "q"]])[0][1]["total"]
        last = q(day, NOW)
        avg = q(NOW - datetime.timedelta(days=8), day) / 7
        spike = last > max(10, 3 * avg)
        add(f"junk-{name}", "mail", f"Junk {name}", "warn" if spike else "ok",
            f"{last} in 24 h (7-day avg {avg:.1f})" + (": SPIKE, look in Junk for wrongly caught mail" if spike else ""), last, "msgs")


@guard
def check_bans():
    since = NOW - datetime.timedelta(days=1)
    n = {"auth": 0, "other": 0}
    for f in sorted(glob.glob("/var/log/stalwart/stalwart.log.*"))[-2:]:
        for line in open(f, errors="replace"):
            if "-ban)" not in line: continue
            try:
                t = datetime.datetime.strptime(line[:20], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
            except ValueError:
                continue
            if t >= since:
                n["auth" if "(security.auth-ban)" in line else "other"] += 1
    add("bans", "mail", "Bans (24 h)", "warn" if n["auth"] else "ok",
        f"{n['auth']} for failed logins" + (" (a device with an old password? unban in the WebUI)" if n["auth"] else "") +
        f", {n['other']} scanners/abuse", n["auth"], "bans")


def main():
    os.umask(0o077)   # the status mentions accounts and errors: root only
    os.makedirs(DIR, mode=0o700, exist_ok=True)
    for fn in (check_stalwart, check_disk, check_memory, check_certs, check_os, check_backup, check_releases,
               check_google, check_junk, check_bans):
        fn()
    db = sqlite3.connect(os.path.join(DIR, "status.db"), timeout=30)
    db.execute("create table if not exists m (ts text, id text, value real, state text)")
    db.execute("create table if not exists alerted (id text primary key, state text, at text)")
    ts = NOW.isoformat(timespec="seconds")
    db.executemany("insert into m values (?,?,?,?)", [(ts, k["id"], k["value"], k["state"]) for k in checks])
    db.execute("delete from m where ts < ?", ((NOW - datetime.timedelta(days=90)).isoformat(timespec="seconds"),))
    since = (NOW - datetime.timedelta(days=14)).isoformat(timespec="seconds")
    for k in checks:   # 14 days of history, thinned to ~ one point per 2 h, for the trend lines
        rows = db.execute("select ts, value from m where id=? and ts>? and value is not null order by ts", (k["id"], since)).fetchall()
        k["series"] = rows[::8][-168:] if len(rows) > 8 else rows
    # alerts: critical checks only, once per change of state
    for k in (k for k in checks if k["critical"]):
        prev = (db.execute("select state from alerted where id=?", (k["id"],)).fetchone() or ("ok",))[0]
        bad, was_bad = k["state"] == "crit", prev == "crit"
        if bad != was_bad and not PRINT:
            subject = f"{'ATTENTION' if bad else 'recovered'}: {k['title']}"
            body = f"{k['title']}: {k['summary']}\n\nAll checks: ./nv status (on your computer)\n"
            if subprocess.run(["/usr/local/sbin/nv-alert", subject], input=body.encode()).returncode != 0:
                continue   # not delivered (Stalwart itself may be down): leave it unmarked, so the next run tries again
        if not PRINT:   # a --print run looks only; it must not mark anything as already alerted
            db.execute("insert or replace into alerted values (?,?,?)", (k["id"], "crit" if bad else "ok", ts))
    db.commit()
    order = {"crit": 0, "warn": 1, "ok": 2}
    out = {"generated": ts, "host": SITE["server"]["hostname"],
           "attention": sum(1 for k in checks if k["state"] != "ok"),
           "checks": sorted(checks, key=lambda k: (order[k["state"]], k["group"], k["title"]))}
    tmp = os.path.join(DIR, "status.json.new")
    with open(tmp, "w") as f:
        json.dump(out, f, indent=1)
    os.chmod(tmp, 0o600); os.replace(tmp, os.path.join(DIR, "status.json"))
    if PRINT:
        for k in out["checks"]:
            print(f"{k['state'].upper():4}  {k['title']:24} {k['summary']}")


if __name__ == "__main__":
    main()
