# stalwart-homeserver

An opinionated, low-maintenance mail server for a household or a small group: Stalwart (mail) + Roundcube
(webmail) + nginx on one AlmaLinux VPS, Cloudflare DNS, nightly encrypted backups to Backblaze B2, and alerts only
when something fails. Optional: pull mail from Google accounts (Gmail, Google Workspace) into the server.

Status: being prepared for sharing; documentation is still to come.

- `site.json` (yours, not in this repo; start from `site.example.json`) holds every site-specific value.
- `./nv run recipe/<nn>-*.sh` runs a recipe on the server; `./nv render` + `./nv diff` show what it would change first.
- `AGENTS.md`: rules for an AI agent helping you run the server.

License: MIT (see LICENSE).
