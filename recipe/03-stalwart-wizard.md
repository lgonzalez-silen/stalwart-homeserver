# Stalwart setup wizard (after `03-stalwart.sh`)

The wizard runs only in bootstrap mode on :8080, which both firewalls block, so reach it
through an SSH tunnel.

## 1. Tunnel + temporary password

```bash
ssh -L 8080:127.0.0.1:8080 root@<server.hostname>
# in that session:
journalctl -u stalwart -n 300 | grep -A8 'bootstrap mode' | tail -9
```

Open <http://localhost:8080/admin> and log in as `admin` with the **most recent** temporary
password (it changes on every bootstrap start).

## 2. Wizard choices

**Leave every value not mentioned here at its default.**

| Setting | Choice | Why |
|---|---|---|
| Server hostname, domain | already filled in from `stalwart.env`: check they show your `server.hostname` and your first domain | They match the PTR, the certificate and every domain's MX |
| Automatically Obtain TLS Certificate | **turn it Off** (it starts On) | certbot owns the certificate; Stalwart loads its files (step 3) |
| Generate Email Signing Keys | **leave it On** | Creates the DKIM keys you publish in DNS |
| Final admin `admin@…` password | **save it in your password manager** | It isn't written to the log |

When the wizard finishes it shows the admin account and password and asks for a restart: run
`ssh root@<server.hostname> systemctl restart stalwart`. Bootstrap mode ends; from now on you sign in as shown in step 3.

The DNS records Stalwart wants (MX, SPF, DKIM, MTA-STS, ...) aren't part of the wizard: find them afterwards under
WebUI → Domains → your domain → DNS records, and copy them into your DNS file (see `docs/deliverability.md`).

## 3. After the wizard (WebUI → Settings)

Log in at **https://<server.hostname>/admin**, through Stalwart's own 443 listener for now (it has a self-signed
placeholder certificate, so the browser says "Your connection is not private": that's expected here, choose
Advanced → Proceed; it goes away once you load the real certificate, the first item below). The SSH tunnel to port 8080 stops working after the
wizard ("Unknown client id"): the admin login only works on the public HTTPS address.

After signing in, open **Settings**: the middle icon in the bar at the bottom of the screen. The items below are
all under it.

- **TLS › Certificates:** add a new certificate:
  - Certificate: type **"Text value read from file"**, path `/etc/stalwart/tls/fullchain.pem`
  - Private key: type **"Secret read from file"**, path `/etc/stalwart/tls/privkey.pem`

  certbot's deploy hook refreshes those files and restarts Stalwart on renewal.
- **TLS › ACME Providers:** make sure none is active (certbot handles certificates).
- **Two-factor for admin:** your account (person icon in the bottom bar) › Credentials › **Password** →
  **Set up TOTP**. Scan the code with your authenticator and keep the secret in your password manager. To save,
  fill in **only "Current Password"** (your admin password) and the 6-digit code; leave "New Password" alone. Without
  the current password the page says "Current secret must be provided to change the password or OTP auth".
- **The API key the recipes and tools use:** your account › Credentials › **API Keys**: create one
  with allowed IPs `127.0.0.1` and `::1` only. Copy it once into the server, **from your own terminal** so it never
  passes through a chat or a log:
  ```bash
  ssh root@<server.hostname> 'umask 077; mkdir -p /root/.secrets; cat > /root/.secrets/laptop-api.key'
  # paste the key, press Enter, then Ctrl-D
  ```
  and keep a copy in your password manager.

**That's all by hand.** Listeners (587, sieve on 127.0.0.1, POP3 off), allowed IPs, the log format and the
cutover from Stalwart's own 443 to nginx are done by `recipe/07-stalwart-settings.sh` through the API, with the
key you just made: run `04-nginx.sh`, then `07-stalwart-settings.sh` (`NV_SHOW=1` first to see what it will do).
Don't change listeners by hand: deleting 443 before nginx runs locks you out of this console.

Menu names can differ between Stalwart versions: if one isn't where this says, the settings search finds it. Write
down where you found it (and fix this guide).
