# Moving mail from an old server

The importer is [Vandelay](https://github.com/stalwartlabs/vandelay), Stalwart's own migration tool. It reads a
source (IMAP, Maildir, JMAP, Exchange, Google Takeout) into a local SQLite archive, then writes the archive into a
Stalwart account. The tools here cover the gaps around it.

Pick a route:

| Your situation | Route |
|---|---|
| Old server still running, mailboxes of normal size | **A.** `vandelay import imap` straight from the old server |
| Old server still running, very large mailboxes | **B.** Run Vandelay **on the old server** against its own IMAP (`imaps://127.0.0.1`), copy the archive file over, export on the new server |
| Only the old mbox files are left (server gone, or IMAP not usable) | **C.** `migrate-user.sh`: mbox → Maildir → Vandelay |
| Mail kept arriving at the old server after the first copy | **D.** `delta-import.py` for a catch-up |

B is usually the best. The old server's own IMAP software reads its mbox files correctly (read/answered/flagged
state, nested folders, odd `From ` lines), and a single archive file moves much faster than hundreds of thousands of
messages over IMAP. It needs a Vandelay build that runs on the old OS (there are static `musl` builds) and either
each user's password or an IMAP master user.

Why C exists: Vandelay's own mbox reader (`import takeout`) is built for Google Takeout. On mbox files written by a
mail server it drops read/answered/flagged state and flattens nested folders (reported upstream; until that's
fixed, use `mbox2maildir.py` first).

## Tools

| Tool | What it does |
|---|---|
| `mbox2maildir.py` | Dovecot/UW-style mbox tree → Maildir++ for `vandelay import maildir`. Keeps flags (`Status`/`X-Status`/`X-Keywords`), folder nesting and the delivery date; uses `Content-Length` so unescaped `From ` lines don't split messages; drops the old server's bookkeeping headers. Writes `manifest.tsv` (expected counts per folder). |
| `migrate-user.sh` | Route C for one user, end to end, including the checks below. |
| `vandelay-fix-folders.py` | Vandelay keeps one copy per Message-ID, so a message that sat in two folders lands in one. This adds the missing folder memberships (no copies). Run it after every import. |
| `cmpacct.py` | Per-folder message counts: the Stalwart account vs `manifest.tsv`. Counts only. |
| `delta-import.py` | Route D: imports only messages whose Message-ID isn't in the account yet. `--since=` skips mail the user already dealt with on the new server. Dry run unless `--apply`. |
| `rc-old-identities.py` | Old Roundcube identities (names, addresses, signatures) from a MySQL dump, as JSON. |
| `rc-port-user.php` | Puts those identities into the new Roundcube before the user's first login. Per-identity outgoing servers go through the `identity_smtp` plugin. |
| `rc-apply-identities.php` | Same for a user who has already logged in, plus a few display preferences. |
| `rc-smtp-password.php` | Sets an identity's outgoing-server password, typed without echo, and tests the login. |

## Time zone

mbox `From ` lines carry the delivery time in the **old server's** local time, with no zone. Set
`server.timezone` in site.json to that zone before converting (or pass `--tz Europe/Lisbon`), or every message's
received time shifts by the UTC offset. It can't be corrected afterwards without re-importing.

## Checks worth doing (every route)

1. **Counts per folder** (`cmpacct.py`). The only differences should be ones you can explain: deleted messages,
   folders you dropped on purpose.
2. **Read/answered/flagged counts per folder**, old vs new. Counts alone miss a migration that brought every message
   across as unread.
3. **Second-folder memberships** (`vandelay-fix-folders.py`).
4. **Leftovers**: old IMAP servers keep pseudo-messages like Dovecot's `DON'T DELETE THIS MESSAGE -- FOLDER INTERNAL
   DATA`. `mbox2maildir.py` keeps them, so delete them after checking (subject, `MAILER-DAEMON` sender, tiny size).
5. **Addresses**: every address in the old server's alias map (Postfix `virtual`, `/etc/aliases`, per-user
   `.forward`) should deliver to the same person on the new server, or be dropped on purpose.

Keep the old server, unchanged, until all five pass. Then wipe it before handing it back to the provider.

## Notes

- Import into the right place: with a folder prefix (e.g. `archive/old-accounts/bob`), use
  `vandelay import maildir --noautomap`. Otherwise Vandelay maps any folder named like a special folder (`Sent`,
  `Trash`, `Archive`, case-insensitive, even under the prefix) onto the account's own special folders.
- `migrate-user.sh` exports over `https://<server.hostname>` with the user's own login. In the original run, export
  used an admin API key limited to localhost through a private network-namespace relay instead; the user-login form
  here is simpler but was not the one exercised there.
