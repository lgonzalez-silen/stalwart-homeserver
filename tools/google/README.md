# Google module: Gmail and Google Workspace accounts in your own mailbox

Optional (`recipe/11-google.sh`). The server pulls new mail from one or more Google accounts (a personal Gmail, a
school or work Google Workspace account) into a Stalwart account. You read and reply to everything in one place.

## Why pull instead of forward

Forwarding from Google to your own server works, but:

- Forwarded mail arrives from Google's servers, so the original sender's SPF fails and the `To:` doesn't match. Your
  spam filter sees a stream of "suspicious" mail. Untrained, Stalwart flagged most forwarded mail; trained, it's
  still worse than for direct mail.
- Google has already spam-filtered this mail, well. Pulled mail skips a second filter.
- If your server is down, pulled mail simply waits at Google. Forwarded mail queues or bounces.

## Why this split works well: the server checks many, your phone checks one

Let the **server** check all the Google accounts, and point your **phone and laptop at your own server only**:

- One inbox, one search, one set of folders and filters, on every device.
- Each device holds one account instead of three or four. Fewer passwords on phones, fewer apps polling Google.
- Replying as the right address still works: Roundcube identities (with `identity_smtp`, each identity sends through
  its own Google SMTP server) or your mail app's "send as" setting.
- Your history stays complete on your server even when a school or work account is closed or has a storage limit.

## What it does

| Piece | Runs | Does |
|---|---|---|
| `nv-fetch` | always on (IMAP IDLE) | New mail at Google → the Stalwart account. Everything except Sent, Trash and Spam. |
| `nv-spam-mirror` | every 5 min | A **"Google Spam"** folder showing what Google filtered, so you notice what to rescue. |
| `nv-google-trim` | weekly, only for sources with `keep_days` | Moves Google mail older than `keep_days` to that account's Trash, **only when the same message is on your server**. |
| `nv-fetch-secret` | once per source | Stores the source's app password (typed without echo, tested with a real login). |

Failures go to `nv-alert` (the same alert mail as backups): a revoked app password, for example, after you change
your Google password.

### Safety rules (the pull must never undo your filing)

- **Starts from "now".** On first run it records where each Google folder is and only fetches mail after that. No
  backfill: if you were forwarding before, your history is already on the server.
- **Duplicates are checked against the whole account** (every folder), by Message-ID, not just the Inbox.
- **It remembers everything it delivered,** so mail you moved or deleted on the server is never delivered again.
- **It only adds.** It never moves, flags or deletes anything on your server, and it opens Google folders read-only.
- **Mail from your own addresses** (`own` in site.json) arrives already read, like a "my own Bcc copies" filter.

### The "Google Spam" folder

- New spam at Google is copied in (unread), once per message across all your Google accounts.
- When Google drops it (after 30 days), it disappears here too.
- **Move a message out of "Google Spam"** (to Inbox or any folder): it's a rescue. The mirror also moves it out of
  Spam at Google, which is Gmail's "Not spam". This is the only change the module ever makes at Google.
- Delete it or move it to Trash/Junk: confirmed spam. Nothing happens at Google, and it's never mirrored again.
- Rescued directly in Gmail instead: the server's copy moves to your Inbox.

### Trimming accounts with a storage limit

School and work Google accounts often have a quota. With `keep_days` set, the weekly trim moves older mail to that
account's Trash, but only messages whose Message-ID is somewhere on your server. Google empties Trash after 30
days, so a mistake can be undone for a month. Messages without a Message-ID, Spam, Drafts and Chats are never
touched. Accounts without `keep_days` are never touched.

## Setup

1. For each Google account, create an **app password** (Google Account → Security → 2-Step Verification → App
   passwords). Name it after the server so you can revoke just this one. Workspace admins sometimes disable app
   passwords; ask.
2. Make sure **IMAP is on** (Gmail settings → Forwarding and POP/IMAP).
3. Add the sources to `site.json`:

   ```json
   "google": {
     "sources": [
       {"name": "gmail-alice", "user": "alice.example@gmail.com", "account": "c",
        "own": ["alice.example@gmail.com", "alice@example.com"]},
       {"name": "work-alice", "user": "alice@school.example.edu", "account": "c",
        "own": ["alice@school.example.edu", "alice@example.com"], "keep_days": 365}
     ]
   }
   ```

   `account` is the Stalwart account id (a short letter code). To list them on the server:

   ```sh
   curl -s -H @<(printf 'Authorization: Bearer %s\n' "$(</root/.secrets/laptop-api.key)") -H "Content-Type: application/json" \
     http://127.0.0.1:8080/jmap/ \
     -d '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Account/get",{"properties":["name"]},"a"]]}' \
     | jq -r '.methodResponses[0][1].list[] | "\(.id)  \(.name)"'
   ```

   Optional per source: `enabled` (false pauses it), `spam_mirror` (false hides its spam), `keep_days`.
4. `./nv run recipe/09-ops.sh` (installs `/etc/nv/site.json`), then `./nv run recipe/11-google.sh`.
5. Per source: `ssh -t root@<server> nv-fetch-secret <name>`.
6. **Test with forwarding still on**, for a day or two: both paths deliver, and duplicates are dropped. Then turn
   forwarding off at Google. To roll back, turn it back on.

Check it: `systemctl status nv-fetch`, `journalctl -u nv-fetch`, and `nv-spam-mirror --dry` /
`nv-google-trim --dry` (report only, change nothing).
