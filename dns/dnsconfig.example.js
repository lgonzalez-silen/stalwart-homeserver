// DNS for a mail domain served by this setup, as DNSControl config (https://dnscontrol.org).
// Copy to dnsconfig.js, replace the example values, then:
//   ./preview        shows what would change at your DNS provider (changes nothing)
//   ./push           shows the preview again, asks for "yes", backs up the zone, applies
// Records NOT listed here are deleted on push, so start from your live zone instead of a blank file:
//   dnscontrol get-zones --format=js --out=imported.js cloudflare - all
// and merge the mail records below into it. The first preview should then show only what you meant to change.
//
// DKIM and _ua-auto-config values: Stalwart WebUI › Domains › <domain> › DNS records.
// Every domain listed in site.json mail.helper_domains needs the mta-sts, autoconfig, autodiscover and
// ua-auto-config CNAMEs below before recipe/05 runs (it gets one certificate for all of them).
// Quote TXT values exactly as shown; DNSControl splits long ones (>255 chars) for you.

var REG_NONE = NewRegistrar("none");
var DSP = NewDnsProvider("cloudflare");   // name from creds.json

var SERVER = "mail.example.com.";          // server.hostname in site.json, with a trailing dot
var IPV4 = "192.0.2.10";                   // server.ipv4
var IPV6 = "2001:db8::10";                 // server.ipv6

D("example.com", REG_NONE, DnsProvider(DSP),
    DefaultTTL(3600),

    // The server itself. On Cloudflare keep these DNS-only (no orange cloud): mail ports can't be proxied.
    A("mail", IPV4),
    AAAA("mail", IPV6),

    // Receiving
    MX("@", 10, SERVER),

    // Sending: SPF (only the MX may send), DKIM (from Stalwart), DMARC (reject what fails, reports to you)
    TXT("@", "v=spf1 mx -all"),
    TXT("v1-ed25519-20260101._domainkey", "v=DKIM1; k=ed25519; h=sha256; p=REPLACE_FROM_STALWART"),
    TXT("v1-rsa-20260101._domainkey", "v=DKIM1; k=rsa; h=sha256; p=REPLACE_FROM_STALWART"),
    TXT("_dmarc", "v=DMARC1; p=reject; adkim=s; aspf=s; rua=mailto:postmaster@example.com"),

    // TLS for mail between servers: MTA-STS policy (served by recipe/05) + TLS reports.
    // Change the id whenever the policy changes (any new number). Start the policy in mode "testing".
    CNAME("mta-sts", SERVER),
    TXT("_mta-sts", "v=STSv1; id=20260101"),
    TXT("_smtp._tls", "v=TLSRPTv1; rua=mailto:postmaster@example.com"),

    // Mail app setup: autoconfig (Thunderbird and others), autodiscover (Outlook), SRV records (RFC 6186/8314)
    CNAME("autoconfig", SERVER),
    CNAME("autodiscover", SERVER),
    CNAME("ua-auto-config", SERVER),
    TXT("_ua-auto-config", "v=UAAC1; a=sha256; d=REPLACE_FROM_STALWART"),   // Stalwart WebUI › Domains › DNS records
    SRV("_submissions._tcp", 0, 1, 465, SERVER),
    SRV("_submission._tcp", 0, 1, 587, SERVER),
    SRV("_imaps._tcp", 0, 1, 993, SERVER),
    SRV("_jmap._tcp", 0, 1, 443, SERVER),
    SRV("_caldavs._tcp", 0, 1, 443, SERVER),
    SRV("_carddavs._tcp", 0, 1, 443, SERVER),

    // Only Let's Encrypt may issue certificates for this domain
    CAA("@", "issue", "letsencrypt.org"),
    CAA("@", "issuewild", "letsencrypt.org"),
    CAA("@", "iodef", "mailto:postmaster@example.com")
);

// A domain you own that must NOT send or receive mail: tell the world so, which stops spoofing.
D("example.net", REG_NONE, DnsProvider(DSP),
    MX("@", 0, "."),                        // null MX: accepts no mail
    TXT("@", "v=spf1 -all"),                // sends no mail
    TXT("_dmarc", "v=DMARC1; p=reject;"),
    TXT("*._domainkey", "v=DKIM1; p="),     // no valid DKIM keys
    CAA("@", "issue", ";")                  // no certificates (remove if the domain has a website)
);
