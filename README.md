# stalwart-homeserver

Recipes and small tools for running your own mail server for a household or a small group: **Stalwart** (mail,
IMAP, JMAP, calendars, contacts) and **Roundcube** (webmail) behind **nginx**, on one AlmaLinux 10 VPS, with
Cloudflare DNS, nightly encrypted backups to Backblaze B2, and alerts that mail you only when something fails.
Optional: pull mail from Google accounts (Gmail, Google Workspace) into the server, and serve a few static websites.

It's opinionated on purpose: one way of doing each thing, written down, and tested on a real server that a family
uses every day. Everything specific to your site lives in one file, `site.json`.

**These are choices, not the only ones.** Stalwart can do much more than this setup uses, and many of its defaults
are fine to change: read [its documentation](https://stalw.art/docs) and look around the WebUI. Most settings live in
Stalwart's database, so you can change them in the WebUI at any time after setup. One catch: the settings
`recipe/05-stalwart-settings.sh` manages (listed in its header: listeners, ban rates, spam threshold, DKIM mode, and a
few more) are put back to this setup's values every time recipe 05 runs. Change those in `site.json` where there's a
setting for it, or in the recipe; everything else stays as you set it. Write down why in your `DECISIONS.md`.

> **Read this first: you are taking on your own mail.**
> Running a mail server means you are responsible for every message your people send and receive. Mail can be lost
> (a mistaken cleanup, a disk failure without a working backup), delayed or rejected (a DNS or reputation problem
> you may not notice for days), or exposed (an unpatched server). This repo tries hard to make the safe path the easy
> one, but it comes with no warranty (see [LICENSE](LICENSE)): you use it at your own risk.
> Before you rely on it: keep your old mail provider until everything is verified, try things on copies, check that
> you can restore a backup, and keep the logins you need to recover on your own (see "What you must hold").

## Who this is for

- **Someone comfortable on a command line**, or willing to work with an AI coding agent that is (see
  [Working with an agent](#working-with-an-agent)), who wants their family's mail on a server they control.
- **Moving off an old server** (Dovecot, Postfix, hosting control panels): [`tools/migrate/`](tools/migrate/README.md).
- **Living in several Google accounts**: [`tools/google/`](tools/google/README.md) pulls them all into one mailbox,
  so each phone needs only one account.
- **Fixing deliverability on any mail server**: [`docs/deliverability.md`](docs/deliverability.md) and the DNS
  example in [`dns/`](dns/dnsconfig.example.js).

Not for: a business that needs an uptime guarantee, or anyone who never wants to think about their mail again.

## What you get

| Piece | How | Recipe |
|---|---|---|
| Base OS | AlmaLinux 10, SELinux enforcing, firewalld, SSH keys only, automatic security updates (reboots when needed) | 01 |
| TLS | one Let's Encrypt wildcard via Cloudflare DNS-01, used by nginx and Stalwart | 02 |
| Mail | Stalwart 1.x (official binary); SMTP 25/465/587, IMAPS 993; HTTP behind nginx | 03, 05 |
| Front door | nginx owns 80/443, rate limits, security headers, config tested before every reload | 04 |
| Per-domain helpers | MTA-STS policy, autoconfig/autodiscover for mail apps, and their certificates | 06 |
| Webmail | Roundcube on its own subdomain, SQLite, signature-checked release; optional compact skin | 07, 07b |
| Backups | restic to Backblaze B2: nightly, encrypted, with a key that cannot delete; monthly verify | 08 |
| Quiet operations | alerts only on failure; weekly release check; junk-spike watch | 09 |
| Websites | static sites, no PHP | 10 |
| Google accounts | pull Gmail/Workspace mail in, mirror Google's Spam, trim accounts that have a quota | 11 |

## Before you start

You need:

- **A VPS that allows outgoing port 25** (many cloud providers block it; check first), with a fixed IPv4 and IPv6,
  **reverse DNS (PTR)** you can set to your server's name, and 4 GB of RAM (Stalwart alone used about 1.3 GB with
  ~200,000 messages). Plain AlmaLinux 10 image.
- **A domain on Cloudflare DNS.** Other DNS providers work with small changes; the certificate recipe and the DNS
  wrappers assume Cloudflare.
- **A Backblaze B2 account** for backups.
- **A password manager.** Every secret here is typed by you at a no-echo prompt or read from it.
- **Your computer** (macOS or Linux) with `ssh`, `python3`, bash 4+ (`brew install bash` on macOS), `jq`, and
  optionally `dnscontrol`, and `node` to build the optional skin.

### What you must hold (not the agent, not this repo)

The registrar and DNS logins, the hosting provider's console (your way back in if SSH breaks), the password
manager, the backup credentials (without the restic password the backups are unreadable), and an offline copy of
[`docs/restore.md`](docs/restore.md).

## How it works

```
site.json                            your settings (start from site.example.json; never committed)
./nv run    recipe/<nn>-*.sh         run a recipe on the server (as root, over SSH)
./nv render recipe/<nn>-*.sh <dir>   run it HERE with nothing executed: the files it would install and the
                                     commands it would run land in <dir>
./nv diff   <dir>                    compare a render with the live server (reads only)
./nv sh     <script>                 run a script on your computer with the settings (e.g. tools/publish-sites.sh)
./nv env                             print the settings as the recipes see them
```

Recipes are plain bash, safe to re-run, and take every site-specific value from `site.json`. The habit that keeps
this safe: **render and diff before every run.** The diff shows exactly which lines on the server would change.

### Your site repo

This repo holds no site data: nothing in it names your server, your domains or your people. Keep yours in a second,
**private** repo (or at least a folder you back up), next to this one:

```
my-mail/                     private
  site.json                  your settings: ./nv --site ../my-mail/site.json run ...  (or export NV_SITE=...)
  dns/                       dnsconfig.js (from dns/dnsconfig.example.js), creds.json, and copies of
                             dns/preview + dns/push (they work on the folder they're in)
  STATUS.md                  what is true now: what's done, what's open, what to check next
  DECISIONS.md               why things are the way they are (dated), so nobody re-argues them later
  secrets/                   git-ignored, if you keep local copies at all (your password manager is better)
```

STATUS and DECISIONS are what let a fresh agent session (or you, a year later) pick up where things stand instead
of guessing. Ask the agent to update them as it goes, and read the diff before you commit. When you find something
this repo gets wrong, fix it here (a pull request, or your fork) rather than in your site repo, so the next build
gets it too.

## First build

Order matters. Each recipe's header says what it needs and what to check afterwards. Steps marked **(you)** are
yours to do, not your agent's: they need your accounts, your password manager or your eyes.

0. **Your site repo (you + agent):** create the private repo or folder described above, with `site.json`,
   `dns/`, `STATUS.md` and `DECISIONS.md`, and run every command with `--site` pointing at it. Nothing about your
   server goes into this repo.
1. **Provider panel (you):** AlmaLinux 10 image with your SSH key; PTR records for both IPs → your server name; the
   provider firewall (if any) allowing TCP 22, 25, 80, 443, 465, 587, 993. Many providers unblock outgoing port 25
   only on request (a support ticket). Then, from your own terminal, connect once (`ssh root@<server ip>`) and check
   that the fingerprint it shows matches the one in the provider's console before you accept it.
2. **DNS, the names only:** A/AAAA for the server name and for the webmail name (`webmail.hostname`, e.g.
   `rc.mail.example.com`), and for every mail domain the helper CNAMEs (`mta-sts`, `autoconfig`, `autodiscover`,
   `ua-auto-config` → the server): recipe 06 needs them for its certificate. Copy
   [`dns/dnsconfig.example.js`](dns/dnsconfig.example.js) and fill in your values. **If a domain already receives
   mail somewhere else, leave its MX, SPF and DMARC records as they are:** changing them moves your mail to a server
   that has no accounts yet. They change in step 8.
3. `cp site.example.json <your site repo>/site.json` and fill it in (reference below).
4. In this order: `./nv run recipe/01-base.sh` (reboot if it says so), `02-certs.sh`, `03-stalwart.sh` (installs
   Stalwart and does its first setup, no wizard), `04-nginx.sh` (installs nginx, doesn't start it),
   `05-stalwart-settings.sh` (settings, and the switch of port 443 from Stalwart to nginx). Recipe 01 changes SSH and
   the firewall: after it, and after its reboot, test a fresh login in a separate terminal
   (`ssh -o ControlMaster=no -o ControlPath=none root@<server> true`) before going on.
   Then **(you)** save the admin password and turn on two-factor
   ([`recipe/03-stalwart-admin.md`](recipe/03-stalwart-admin.md)). Then `06-mail-domain-certs.sh`, `07-roundcube.sh`.
5. Backups and operations. **(you)** `./nv sh tools/b2-setup.sh` (the B2 bucket, its key and `restic.env`; settings
   `backup.*`, see the tool's header). Then
   `08-backup.sh` (it finds or creates the account that receives alerts, `alerts.to`) and
   `09-ops.sh`. **Test a restore** ([`docs/restore.md`](docs/restore.md), "Test a restore") before you move real mail in.
6. **Mail DNS** for each domain: DKIM (values from Stalwart's WebUI, Domains › DNS records: they're public, so they
   can be pasted into a chat), MTA-STS and TLS-RPT TXT records, the SRV records and `_ua-auto-config`, then
   **(you)** DNSSEC. MX, SPF and DMARC too, but only for a domain that has no mail anywhere yet. Checklist and tests:
   [`docs/deliverability.md`](docs/deliverability.md).
7. **(you)** Accounts in Stalwart's WebUI; passwords with `nv-set-password` ([operations guide](docs/operations.md)).
   Optional: `10-websites.sh`, `11-google.sh`, and the skin with `./nv sh recipe/07b-roundcube-skin.sh`.
8. Move mail in ([`tools/migrate/`](tools/migrate/README.md)), then switch each domain's MX, SPF and DMARC to the new
   server, and keep the old provider until mail has arrived on the new one for a few days.

## `site.json` reference

| Key | Meaning |
|---|---|
| `server.hostname`, `ipv4`, `ipv6` | the server's name and addresses |
| `server.timezone` | e.g. `America/Chicago`; when migrating mbox files, set it to the OLD server's zone first |
| `server.provider_hostname` | optional: the name the provider's image put in `/etc/hosts`, removed by recipe 01 |
| `certs.extra_names` | more names on the main certificate (e.g. `mail.example.com` if your MX uses it) |
| `mail.helper_domains` | every domain you host mail for (each gets mta-sts/autoconfig/autodiscover names) |
| `mail.mx_hosts` | every MX hostname your domains use (listed in the MTA-STS policy) |
| `mail.default_domain` | optional: Stalwart's default domain, if it isn't the hostname without its first label |
| `mail.max_message_mb` | largest message accepted (default 25, like Gmail; Roundcube attachments ~3/4 of it) |
| `mail.pyzor` | optional, default false: ask public.pyzor.org whether each incoming message is known spam (sends a hash of it, not the content; recipe 05) |
| `admin.allow` | optional IPs/CIDRs allowed to open the WebUI at `/admin`. Empty: open to the internet, protected by the admin password and two-factor (once you've turned it on: `recipe/03-stalwart-admin.md`) |
| `webmail.hostname`, `product_name` | Roundcube's address and the name on its login page |
| `webmail.identity_smtp` | optional, default false: let each webmail identity send through its own outside SMTP server (third-party plugin; recipe 07) |
| `webmail.local_plugins`, `local_skins`, `compact_skin_source` | the optional skin and its plugins (recipe 07b) |
| `backup.bucket`, `path`, `b2_master_key_id`, `b2_master_key`, `restic_password` | for `tools/b2-setup.sh`: the B2 bucket, the folder in it, and where the master key and the restic password come from: any password manager (`cmd:<command>`), 1Password (`op://…`), or a hidden prompt (empty) |
| `alerts.to`, `from`, `account` | who gets alerts and the sender shown; `account` is optional: the Stalwart account id to deliver to, when recipe 08 shouldn't pick the owner of `to` |
| `websites[]` | `name`, `cert` (`dns` or `http`), `source` (folder on your computer), `webmail_redirect` |
| `google.sources[]` | `name`, `user`, `account`, `own`, optional `enabled`, `spam_mirror`, `keep_days` ([details](tools/google/README.md)) |
| `junk_report.detail_accounts`, `keep_days` | accounts whose Junk is listed message by message, and whose Junk older than `keep_days` is deleted for good |

## Running it

Most days you do nothing: updates, backups, certificate renewals and checks run on timers. `./nv status` shows
everything that could need attention in one place (with `--html`, a local page with trend lines), and you get mail
only when something needs action soon. Alerts are sent by the server itself, so a server that is completely down
can't tell you: look at `./nv status` now and then, or point a free outside uptime monitor at `https://<server>/`. The [operations guide](docs/operations.md) covers what runs when, what each alert means,
everyday tasks (users, passwords, domains), upgrades and restores. [`docs/stalwart-notes.md`](docs/stalwart-notes.md)
collects Stalwart behaviour worth knowing.

## Working with an agent

This repo is written so that an AI coding agent (Claude Code, Codex, ...) can help you build and run the server:
**agent-assisted, human-approved.** That's not a claim that anyone can now run a mail server without understanding
it.

What makes that workable:

- Plain bash recipes run from your computer over SSH: no hidden state, no web panels to click through.
- Every change can be shown before it happens: `./nv render` + `./nv diff`, a dry run on every tool that moves or
  deletes mail, a DNS preview before any DNS push.
- Undo is built in: Google keeps trimmed mail in its Trash for 30 days, upgrades start from an instant snapshot,
  restic keeps 12 months of history, and nginx config that fails its test is put back automatically.
- Secrets never pass through the agent: you type passwords at no-echo prompts; tools read keys from root-only files.
- Your own site repo keeps `STATUS.md` (what is true now) and `DECISIONS.md` (why), so a fresh session starts with
  the context instead of guessing.

[`AGENTS.md`](AGENTS.md) holds the rules an agent must follow here: show first, never delete mail or change DNS
without your OK, test a fresh SSH login before touching access, never weaken a check, verify twice before anything
irreversible. Point your agent at it at the start of every session.

Honest caveats: agents can be confidently wrong, so ask "how do you know?" and expect a second, independent check.
On the server this came from, a search reported thousands of messages missing that were in fact present, and a
message logged as "refused" by Google had in fact been moved. Two code reviews found real data-loss bugs in tools
that were already running. Mail punishes mistakes quietly. Stay in the loop.

## Related

- [roundcube-elastic-compact](https://github.com/lgonzalez-silen/roundcube-elastic-compact): the optional denser
  Roundcube skin used by recipe 07b.

## License

MIT, see [LICENSE](LICENSE). No warranty: use at your own risk.
