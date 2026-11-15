# Operations guide

How a server built from these recipes runs day to day, what it tells you, and how to do the common jobs. The short
version: it looks after itself, `./nv status` shows you everything in one place, it mails you only when something
needs action soon, and every change you make goes through the repo (edit, render, diff, run).

## The dashboard: `./nv status`

Run it on your computer any time. It shows every check (backups, certificates, disk, Stalwart, OS updates, each
Google pull, Junk per account, login bans, new releases) as OK, WARN or CRIT, newest problems first.
`./nv status --html` opens the same as a page with 14-day trend lines. The data comes from `nv-status` on the server
(every 15 minutes, kept 90 days in `/var/lib/nv-status/`), fetched over SSH: nothing is published on the web.

Look at it now and then (weekly is plenty), and whenever something feels off.

## What runs on its own

| When (UTC) | What | You hear about it |
|---|---|---|
| every 5 min | `nv-spam-mirror` (Google module): keeps the "Google Spam" folder in step | no alert (see below); check `journalctl -u nv-spam-mirror` now and then |
| always on | `nv-fetch` (Google module): pulls new Google mail | after ~10 failures in a row, once a day |
| 03:15 nightly | `nv-backup`: Stalwart stopped ~2 s for a snapshot, then upload to B2; weekly prune on Sundays | only on failure |
| early morning | `dnf-automatic`: OS security updates, reboot when an update needs one | only on failure |
| twice a day | `certbot-renew`: certificates renew ~30 days before expiry; nginx and Stalwart reload | only on failure |
| every 15 min | `nv-status`: the dashboard's checks | when a critical check turns bad or recovers (below) |
| 13:00 daily | `nv-junk-report`: prunes Junk of `junk_report.detail_accounts` (spikes show on the dashboard) | only on failure |
| Sun 14:00 | `nv-google-trim` (Google module, only sources with `keep_days`) | on failure, or more than 20 messages Google refuses to move (fewer are logged and skipped), or a source with no dry run yet at its `keep_days` (run `nv-google-trim --dry <source>` and check it) |
| Mon 14:00 | `nv-release-check`: Stalwart, Roundcube, identity_smtp, restic | one mail per new version (also on the dashboard) |
| 1st, 05:00 | `nv-backup-check`: verifies the backup repository and re-reads 10% of it | only if it finds a problem |

A failed run of any of the timer jobs puts an alert straight into `alerts.to`'s Inbox (`OnFailure=nv-alert@...`,
delivered through Stalwart's API so it can't land in Junk; plain SMTP is the fallback). Two exceptions, on purpose:
the spam mirror runs every 5 minutes, so alerting on each failure would flood you (its usual failure, a revoked
Google app password, also stops the pull, which alerts once a day); and the pull itself alerts after ~10 failures
in a row, at most once a day.

## What an alert means, and what to do

| Subject | Meaning | Do |
|---|---|---|
| `[nv] FAILED: nv-backup.service` | last night's backup didn't finish | `journalctl -u nv-backup -n 50`; usually B2 or the network. Run `systemctl start nv-backup` once it's fixed. Two missed nights in a row is worth fixing the same day |
| `[nv] ATTENTION: <check>` | a critical check turned bad: Stalwart not running, disk over 90%, a certificate under 14 days, no good backup for 48 h, or a Google pull silent for 6 h | `./nv status` for the detail; the line tells you where to look |
| `[nv] recovered: <check>` | the same check is fine again | nothing |
| `[nv] monthly backup check: FAILED ...` | the monthly verify found a problem | read the report it contains; run `restic check` by hand on the server |
| `[nv] mail pull failing: <source>` | a Google account stopped pulling (often a revoked app password after a Google password change) | new app password, then `ssh -t root@<server> nv-fetch-secret <source>`. Mail waits at Google meanwhile |
| `[nv] mail pull skipped a message: <source>` | one message was refused (usually over `mail.max_message_mb`) | read it in Google's web mail; nothing else is blocked |
| `[nv] FAILED: dnf-automatic.service` | OS updates didn't install | `journalctl -u dnf-automatic -n 50`; often a mirror hiccup that fixes itself the next day |
| `[nv] FAILED: <unit>` (anything else) | that timer's run failed; the alert includes its last 40 log lines | read them, fix, then re-run it by hand: `systemctl start <unit>` |

Quiet is normal now. `./nv status` is how you check that quiet means "fine".

## Everyday jobs

**Add a person.** Stalwart WebUI (`https://<server>/admin`) → Accounts → new account with their address and any
aliases. Then set their password: `ssh -t root@<server> nv-set-password <login>`. They type nothing into any chat;
you (or they) type it at the prompt. The tool tests a real IMAP login before it says OK.

**Change a password.** Same command. Typing the same password again is fine: it re-stores it with a strong hash
(useful after a migration from an old server with weak hashes).

**Set up their phone or laptop.** With the mail-app setup records in DNS, most apps need only the address and
password. If an app asks for servers: incoming IMAP `<server>` port 993 SSL; outgoing SMTP `<server>` port 465 SSL
(or 587 STARTTLS); user name = the full address (needed for every domain except the default one).

**Add a domain.** DNS first (see [deliverability](deliverability.md)), then in the WebUI add the domain and copy its
DKIM records into your DNS file, then add it to `mail.helper_domains` in `site.json` and run
`./nv run recipe/06-mail-domain-certs.sh` (it needs the mta-sts/autoconfig CNAMEs to exist). Test with a message
from Gmail before telling anyone.

**Add a Google account to pull from.** See [`tools/google/README.md`](../tools/google/README.md).

**Publish website changes.** Edit the files in the site's `source` folder on your computer, then
`./nv sh tools/publish-sites.sh <site>`.

## Changing configuration

Every change goes through the repo, so the server never drifts from what the recipes describe:

1. Change `site.json` or the recipe.
2. `./nv render recipe/<nn>-*.sh /tmp/r && ./nv diff /tmp/r`: read the diff. It shows every line on the server that
   would change, and nothing else.
3. `./nv run recipe/<nn>-*.sh`.

If you ever have to change something by hand on the server, put it into the repo the same day.

## Upgrades

**OS:** automatic (dnf-automatic, daily, reboots when needed).

**Stalwart:** when the weekly release check mails you (new versions also show on `./nv status`). Read every release's notes between your version and the new one
(watch for "breaking" and migration steps). Upgrade right after the nightly backup, following the procedure in
`recipe/03-stalwart.sh`'s header: it takes an instant copy-on-write snapshot of the data directory first, so going
back is a rename, and the downtime is a couple of seconds.

**Roundcube:** bump `VER` in `recipe/07-roundcube.sh`, render + diff, run. The release's PGP signature is checked
against the Roundcube signing key; the old version's directory stays for rollback (`ln -sfn <old dir> /var/www/roundcube`). If
you use the compact skin, re-run `07b` afterwards.

**restic, identity_smtp:** bump the version in their recipe, render + diff, run.

## Backups and restores

Nightly to B2, encrypted on the server before upload, kept 14 daily / 8 weekly / 12 monthly. The B2 key can't delete
files, only hide them, and B2 removes hidden files after 30 days: someone with root on the server can't destroy
your history for 30 days, which is your window to notice and react (the monthly check is one signal). For more, keep
an occasional offline copy. What's backed up: Stalwart's data (all
mail, accounts, settings, DKIM keys) and Roundcube's database. Not backed up, on purpose: configuration (the recipes
rebuild it) and secrets (your password manager has them).

Restoring a whole server, one mailbox, or a single message: [restore.md](restore.md). Do a test restore once after
the first build and again after big changes. A backup you've never restored is a hope, not a backup.

## The household admin

If you run mail for other people, a few habits help:

- Tell people what to expect before you move them: the date, the new webmail address, that their phone may ask for
  the password once.
- Keep a short list of who uses which device and app. When a phone keeps asking for a password, it's almost always
  the user name (it must be the full address outside the default domain) or an old saved password.
- Auto-ban: Stalwart bans an address after repeated failed logins (here: 30 a day, banned for a day). One phone with
  a stale password can ban your whole home network for a day. The fix is the right password, then removing the ban
  in the WebUI if you can't wait.
- Big attachments and photo sets belong in a shared link, not in everyone's mailbox; the size limit
  (`mail.max_message_mb`, 25 MB by default) enforces it.
- Don't delete anyone's mail on their behalf without asking, even junk.

## Working with an agent, step by step

What a good session looks like (this is how the server this repo came from was built and is run):

1. Start the agent in your site repo, and point it at this repo's `AGENTS.md` and your `STATUS.md` / `DECISIONS.md`.
2. Say what you want in plain words ("add my sister's account", "the release check says Stalwart 1.2 is out").
3. The agent reads the relevant recipe and the release notes, then **shows** you the plan: the render and diff,
   the dry run, the DNS preview. Nothing has changed yet.
4. You say go (or ask "how do you know?"; a good answer is a second, independent check, not a repeat of the first).
5. It runs the change, then verifies it a different way than it made it (a fresh login, a real message, a count from
   another source), and writes a line in `STATUS.md`.
6. Passwords: when one is needed, it gives you a command to run in your own terminal. You type the password there.

Things to stay firm on: no mail deleted without your OK, no DNS or firewall change without seeing it first, and no
"I relaxed the check so it passes". If you ever notice the agent working around a safety check, stop and ask why.
