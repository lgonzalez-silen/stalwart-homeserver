# Stalwart notes

Behaviour of Stalwart 1.x worth knowing, learned running it (current as of 1.1.0). Each note says where the recipes
handle it.

## Configuration

- **Most settings live in Stalwart's database, not in files.** `/etc/stalwart/config.json` only says where the data
  store is. Everything else is set in the WebUI or through the admin API (`x:<Object>/set` JMAP methods). Recipe 05
  sets the ones this setup changes, so they're written down and re-appliable. That also means a WebUI change to
  one of those settings lasts only until recipe 05 runs again; any other setting stays as you set it.
- **The setup wizard is one API object.** In bootstrap mode (first start, no `config.json`) the wizard just saves
  `x:Bootstrap` (hostname, default domain, ACME on/off, DKIM keys on/off, stores, log). Recipe 03 saves it itself,
  signed in with `STALWART_RECOVERY_ADMIN=<user>:<password>` (a one-time value; Stalwart then doesn't print a
  temporary password); the answer carries the new admin account's generated password. The same credential works in
  normal mode, which is how recipe 03 makes the API key (`x:ApiKey/set` with the admin's `accountId`; the recovery
  login itself is a virtual account and can't own one). Remove it afterwards: it bypasses two-factor.
- **The admin account should have TOTP**, and then password login for scripts stops working (HTTP 402; in 1.1.0
  password+code over Basic auth isn't accepted either, tested). API keys keep working, so scripts use one limited
  to 127.0.0.1/::1 (`/root/.secrets/laptop-api.key`, made by recipe 03). TOTP can also be set through the API
  (`x:AccountPassword/set` with `currentSecret`, `otpAuth.otpUrl` and a current `otpCode`); the guide does it in the
  WebUI because you scan the code anyway.
- **Some settings apply only at the next restart** (the DMARC/TLS report settings, for example). The nightly backup
  restarts Stalwart (~2 s), so "tomorrow" is the usual answer.
- **The WebUI's OAuth sign-in works only on Stalwart's public URL**, so the admin console lives at
  `https://<server>/admin` rather than on its own subdomain.

## Mail flow

- **`Email/import` (JMAP) and IMAP `APPEND` skip the spam filter.** Right for migrations and for the Google pull;
  it also means alerts imported this way can't land in Junk (recipe 08's `nv-alert` relies on it).
- **Message-ID and Date headers**: Stalwart adds them only on port 25 by default. Recipe 05 adds them when missing
  on every port, so mail from scripts and old clients is well-formed (Gmail rejects mail without them).
- **Message size**: Stalwart's default limit is 100 MB. Recipe 05 sets `mail.max_message_mb` (25 by default).
- **Bare login names work only for the default domain.** Users on other domains log in with the full address.

## Spam filter

- The defaults are good. Before adding custom rules, wait for a real miss: old hand-written filters are a common
  way to damage someone's inbox.
- **The trained classifier is what makes it accurate.** Bulk-train it from mail people have kept (ham) and old Junk
  folders (spam): upload each message as a blob, create a `SpamTrainingSample`, then run a `SpamFilterMaintenance`
  train task.
- **Forwarded mail scores badly** (SPF fails for the original sender, recipients don't match). Pulling mail from the
  other provider (the Google module) avoids it instead of fighting it.
- **The `ClassifySpam` action can't express the null sender `<>`** (bounces), so such messages can't be tested
  through it. Reported upstream.

## Security

- **Auto-ban**: in 1.0.x an empty ban period meant permanent. Recipe 05 sets expiring bans (failed logins: 30 a day,
  then a 1-day ban), so a stale password on a home device can't lock the household out forever. Add the server's
  own addresses to the allowed IPs, or webmail's SMTP from the server can ban the server itself.
- **Client IP behind nginx**: set "Client IP source = X-Forwarded-For, 1 hop" in the WebUI, or every HTTP client
  looks like 127.0.0.1 to Stalwart's limits.

## DKIM and DNS

- **DKIM rotation: keep it manual** unless Stalwart manages your DNS. Automatic rotation publishes new selectors your
  DNS doesn't have.
- **Stalwart shows the DNS records it wants** per domain (WebUI → Domains → DNS records): use them as the reference
  for MX, SPF, DKIM, MTA-STS, TLS-RPT and the mail-app setup names.
- **MTA-STS `mx` lines**: Stalwart's default policy lists only the server's own name. If your MX records use another
  name too, recipe 05 sets them from `mail.mx_hosts`.

## Upgrades and migration

- **Read every release's notes between versions.** 1.0.2 had security fixes that mattered (2FA bypass at WebUI
  sign-in with app passwords or API keys).
- **Upgrade from a snapshot**: stop, reflink-copy `/var/lib/stalwart` (instant on XFS/Btrfs), swap the binary, start.
  Recipe 03's header has the tested procedure; rollback is a rename.
- **Vandelay** is the migration tool (the old `stalwart-cli import` is gone). See
  [`tools/migrate/`](../tools/migrate/README.md) for its gaps on server mbox files and how to check a migration.
