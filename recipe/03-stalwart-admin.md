# Stalwart admin account (after recipes 03, 04 and 05)

There's no setup wizard to click through: `03-stalwart.sh` saves the wizard's settings through Stalwart's API
(hostname, default domain, certificate from certbot instead of ACME, DKIM keys on) and makes the API key the other
recipes use. Two things stay by hand, because they're yours: the admin password, and two-factor.

## 1. Save the admin password

Stalwart generated it at the first setup. Copy it into your password manager **from your own terminal**, so it
never passes through a chat or a log:

```bash
ssh root@<server.hostname> cat /root/.secrets/stalwart-admin     # prints admin@<domain>:<password>
```

(On a Mac, add `| pbcopy` to put it on the clipboard instead of the screen.)

## 2. Sign in and turn on two-factor

Open **https://<server.hostname>/admin** (only this address works: port 8080, the bare IP or an SSH tunnel answer
"Unknown client id") and sign in as `admin@<domain>`.

- **Two-factor:** your account (person icon in the bar at the bottom) › Credentials › **Password** → **Set up
  TOTP**. Scan the code with your authenticator and keep the secret in your password manager. To save, fill in
  **only "Current Password"** (the admin password) and the 6-digit code; leave "New Password" alone. Without the
  current password the page says "Current secret must be provided to change the password or OTP auth".
- Then delete the server's copy of the password: `ssh root@<server.hostname> rm /root/.secrets/stalwart-admin`.
  Nothing needs it: the recipes and tools use the API key (`/root/.secrets/laptop-api.key`, allowed from the server
  itself only), and recipe 03 makes a new key whenever that file is missing.

## 3. Have a look (nothing to change)

Settings is the middle icon in the bottom bar. Worth knowing where things are:

- **Domains › your domain › DNS records:** the records Stalwart wants (MX, SPF, DKIM, MTA-STS, ...). Copy them into
  your DNS file (see `docs/deliverability.md`).
- **TLS › Certificates:** one certificate, read from `/etc/stalwart/tls/` (recipe 05 loads it; certbot's deploy hook
  refreshes the files and restarts Stalwart on renewal).
- **Network › Listeners:** 25, 465, 587, 993, sieve on 127.0.0.1:4190 and http on 127.0.0.1:8080 (nginx owns 443).
  Recipe 05 keeps them that way; change them there, not here.

Menu names can differ between Stalwart versions: if one isn't where this says, the settings search finds it. Write
down where you found it (and fix this guide).
