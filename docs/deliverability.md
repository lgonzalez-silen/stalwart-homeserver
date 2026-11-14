# Deliverability: getting your mail accepted, and receiving it safely

A checklist for any self-hosted mail server, not just this one. Do it per domain. The DNS lines below are in
[DNSControl](https://dnscontrol.org) form; [`dns/dnsconfig.example.js`](../dns/dnsconfig.example.js) has them all in
one file, and `dns/preview` shows what would change before `dns/push` applies it.

## The server itself

- [ ] **Outgoing port 25 is open** at your provider (`nc -vz gmail-smtp-in.l.google.com 25` from the server).
- [ ] **Reverse DNS (PTR)** for both the IPv4 and the IPv6 address returns the server's name, and that name's A/AAAA
      point back to the same addresses. Set it in the provider's panel. Without it, big providers reject or junk you.
- [ ] **The server's IPs aren't on blocklists**: check https://mxtoolbox.com/blacklists.aspx before you start. A
      recycled VPS address can arrive listed.
- [ ] **TLS certificate valid** for the server name (recipe 02 does it) and offered on 25, 465, 587, 993.

## Per domain

- [ ] **MX** → your server: `MX("@", 10, "mail.example.com.")`
- [ ] **SPF**: only your MX may send: `TXT("@", "v=spf1 mx -all")`. If anything else sends as your domain (a
      newsletter service, a printer), add it explicitly; never `+all` or `?all`.
- [ ] **DKIM**: Stalwart generates the keys (WebUI → Domains → your domain → DNS records). Publish both selectors,
      Ed25519 and RSA: Gmail ignores Ed25519 signatures, so the RSA one is what passes there. Quote TXT values exactly.
      Turn Stalwart's automatic DKIM rotation **off** if your DNS isn't managed by Stalwart: rotation publishes new
      selectors that your DNS doesn't have, and DKIM starts failing.
- [ ] **DMARC**: `TXT("_dmarc", "v=DMARC1; p=reject; adkim=s; aspf=s; rua=mailto:postmaster@example.com")`. Start
      with `p=none` for a week if other systems send as your domain, read the reports, then move to `reject`.
- [ ] **MTA-STS**: `CNAME("mta-sts", "mail.example.com.")`, `TXT("_mta-sts", "v=STSv1; id=<any new number>")`, and
      the policy served at `https://mta-sts.<domain>/.well-known/mta-sts.txt` (recipe 05 serves it; its `mx:` lines
      come from `mail.mx_hosts`). Start in `testing`; switch Stalwart's policy to `enforce` after about two weeks of
      clean TLS reports, and change the `id` whenever the policy changes.
- [ ] **TLS-RPT**: `TXT("_smtp._tls", "v=TLSRPTv1; rua=mailto:postmaster@example.com")`. Google and Microsoft then
      mail a daily report of TLS problems reaching you.
- [ ] **Mail-app setup**: CNAMEs `autoconfig`, `autodiscover`, `ua-auto-config` → your server, the SRV records for
      `_submissions._tcp` (465), `_submission._tcp` (587), `_imaps._tcp` (993), and Stalwart's `_ua-auto-config` TXT.
      Add the domain to `mail.helper_domains` so recipe 05 gets certificates for these names.
- [ ] **CAA**: only your CA may issue: `CAA("@", "issue", "letsencrypt.org")` (+ `issuewild`, + `iodef`).
- [ ] **DNSSEC** on (at Cloudflare: one switch; if it's also your registrar, the DS record is added for you). Check
      with `dig +dnssec MX example.com @1.1.1.1`: the answer's flags should include `ad`.

**Domains you own that don't do mail:** say so, which stops others from spoofing them: null MX `MX("@", 0, ".")`,
`TXT("@", "v=spf1 -all")`, `TXT("_dmarc", "v=DMARC1; p=reject;")`, `TXT("*._domainkey", "v=DKIM1; p=")`.

## Testing

- **mail-tester.com**: send a message to the address it shows; aim for 10/10.
- **A real Gmail account**: send to it, open the message, "Show original": SPF, DKIM and DMARC should all say PASS.
  Reply from Gmail, and check on your server that the reply arrived over TLS (Stalwart's log shows the handshake).
- **A real Microsoft account** (outlook.com): the same. Microsoft is the strictest about new senders.
- **Policies from outside**: `curl https://mta-sts.example.com/.well-known/mta-sts.txt`, and the autoconfig XML at
  `https://autoconfig.example.com/mail/config-v1.1.xml?emailaddress=you@example.com`.

## Expect this, and don't "fix" it

- **A new domain or IP lands in spam at first**, even with everything passing. Reputation builds over weeks of
  normal mail. Ask the first few recipients to mark "Not spam".
- **Your own test messages score oddly** (two-word test bodies look like spam). Test with real-looking mail.
- **Outgoing DMARC and TLS reports** (the ones your server sends to others) are optional. They were most of the mail
  this setup's server sent, some bounced, and failure reports go mostly to spammers' addresses, so recipe 07 turns
  them off. Reports *about your domains* still arrive.

## When mail goes missing

1. Stalwart's log (`/var/log/stalwart/`): search for the address or the Message-ID. It shows whether the message
   arrived, what the spam filter scored, and where it was delivered.
2. The sender's bounce message, if there was one: the error text names the problem (SPF, DKIM, a blocklist, a full
   mailbox).
3. Your DMARC aggregate reports: which IPs sent as your domain, and whether they passed.
4. Junk: the spam filter learns when you move a wrongly caught message out of it.
