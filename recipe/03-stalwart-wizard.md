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

| Screen | Choice | Why |
|---|---|---|
| Server hostname | your `server.hostname` | Matches PTR, the cert, and MX targets for every domain |
| First domain | a test domain you can afford to break | Pilot first; move real domains later |
| TLS / "Automatically obtain certificate" | **Off** | certbot owns the cert; Stalwart loads files (step 3) |
| Storage | Default (RocksDB in `/var/lib/stalwart`) | Single box; no need for the old data/blob split |
| Directory | Internal | Accounts live in Stalwart |
| DNS records shown | Copy them into a file in your site repo; apply later | Review before touching DNS |
| Final admin `admin@…` password | **Save it in your password manager** | Not written to the log |

## 3. After the wizard (WebUI → Settings)

- **TLS › Certificates:** new certificate with `certificate` = File `/etc/stalwart/tls/fullchain.pem`
  and `privateKey` = File `/etc/stalwart/tls/privkey.pem`. certbot's deploy hook refreshes those
  files and restarts Stalwart on renewal.
- **Listeners:** keep SMTP 25, submissions 465, submission 587, IMAPS 993. **Delete** Stalwart's
  HTTPS 443 listener (nginx owns 443). Delete POP3/POP3S; plain IMAP 143 and ManageSieve 4190 are
  optional (firewalled anyway). HTTP listener: bind to **127.0.0.1:8080** once nginx is in front.
- **ACME:** make sure no ACME provider is active.
