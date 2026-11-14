# stalwart-homeserver

Recipes and small tools for running your own mail server for a household or a small group: **Stalwart** (mail,
IMAP, JMAP, calendars, contacts) and **Roundcube** (webmail) behind **nginx**, on one AlmaLinux 10 VPS, with
Cloudflare DNS, nightly encrypted backups to Backblaze B2, and alerts that mail you only when something fails.
Optional: pull mail from Google accounts (Gmail, Google Workspace) into the server, and serve a few static websites.

It's opinionated on purpose: one way of doing each thing, written down, and tested on a real server that a family
uses every day. Everything specific to your site lives in one file, `site.json`.

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

## First build

Order matters. Each recipe's header says what it needs and what to check afterwards.

1. **Provider panel:** AlmaLinux 10 image with your SSH key; PTR records for both IPs → your server name; the
   provider firewall (if any) allowing TCP 22, 25, 80, 443, 465, 587, 993.
2. **DNS:** A/AAAA for the server name, a wildcard under it for webmail, and for every mail domain the helper
   CNAMEs (`mta-sts`, `autoconfig`, `autodiscover`, `ua-auto-config` → the server): recipe 06 needs them for its
   certificate. Copy [`dns/dnsconfig.example.js`](dns/dnsconfig.example.js) and fill in your values; the rest of the
   mail records (MX, SPF, DKIM, ...) come in step 6.
3. `cp site.example.json site.json` and fill it in (reference below).
4. In this order: `./nv run recipe/01-base.sh` (reboot if it says so), `02-certs.sh`, `03-stalwart.sh`, then
   Stalwart's setup wizard and its few manual steps ([`recipe/03-stalwart-wizard.md`](recipe/03-stalwart-wizard.md)),
   then `04-nginx.sh` (installs nginx, doesn't start it), `05-stalwart-settings.sh` (settings, and the switch of
   port 443 from Stalwart to nginx), `06-mail-domain-certs.sh`, `07-roundcube.sh`.
5. Backups and operations: `08-backup.sh` (create the B2 bucket and key first, see its header), then `09-ops.sh`.
   **Test a restore** ([`docs/restore.md`](docs/restore.md)) before you move real mail in.
6. **Mail DNS** for each domain: MX, SPF, DKIM (values from Stalwart's WebUI), DMARC, MTA-STS and TLS-RPT TXT
   records, the SRV records and `_ua-auto-config`, then DNSSEC. Checklist and tests: [`docs/deliverability.md`](docs/deliverability.md).
7. Accounts in Stalwart's WebUI; passwords with `nv-set-password` ([operations guide](docs/operations.md)).
   Optional: `10-websites.sh`, `11-google.sh`, `07b-roundcube-skin.sh`.
8. Move mail in ([`tools/migrate/`](tools/migrate/README.md)), then switch your MX records.

## `site.json` reference

| Key | Meaning |
|---|---|
| `server.hostname`, `ipv4`, `ipv6` | the server's name and addresses |
| `server.timezone` | e.g. `America/Chicago`; when migrating mbox files, set it to the OLD server's zone first |
| `server.provider_hostname` | optional: the name the provider's image put in `/etc/hosts`, removed by recipe 01 |
| `certs.extra_names` | more names on the main certificate (e.g. `mail.example.com` if your MX uses it) |
| `mail.helper_domains` | every domain you host mail for (each gets mta-sts/autoconfig/autodiscover names) |
| `mail.mx_hosts` | every MX hostname your domains use (listed in the MTA-STS policy) |
| `mail.max_message_mb` | largest message accepted (default 25, like Gmail; Roundcube attachments ~3/4 of it) |
| `admin.allow` | optional IPs/CIDRs allowed to open the WebUI at `/admin` (the admin account has TOTP either way) |
| `webmail.hostname`, `product_name` | Roundcube's address and the name on its login page |
| `webmail.local_plugins`, `local_skins`, `compact_skin_source` | the optional skin and its plugins (recipe 07b) |
| `alerts.to`, `from`, `account` | who gets alerts, the sender shown, and the Stalwart account id of `to` |
| `websites[]` | `name`, `cert` (`dns` or `http`), `source` (folder on your computer), `webmail_redirect` |
| `google.sources[]` | `name`, `user`, `account`, `own`, optional `enabled`, `spam_mirror`, `keep_days` ([details](tools/google/README.md)) |
| `junk_report.detail_accounts`, `keep_days` | accounts whose Junk is listed message by message, and pruned |

## Running it

Most days you do nothing: updates, backups, certificate renewals and checks run on timers. `./nv status` shows
everything that could need attention in one place (with `--html`, a local page with trend lines), and you get mail
only when something needs action soon. The [operations guide](docs/operations.md) covers what runs when, what each alert means,
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
