# Restoring from backup

Keep an offline copy of this page with your password manager. You'll need it on the day nothing else works.

**What the backups hold** (nightly restic snapshots on Backblaze B2, `recipe/08-backup.sh`): Stalwart's database
(all mail, accounts, settings, DKIM keys) and Roundcube's database. No configuration and no secrets: the recipes
rebuild the configuration, and your password manager holds the secrets.

**What you need:** the restic password and your B2 master key, in your password manager (`tools/b2-setup.sh` put
the password there). **Without the restic password the backups can't be read by anyone, including you.**

For scale: on the server this came from, restoring an 8 GB snapshot took about a minute and a half.

## Whole server

1. A fresh AlmaLinux 10 on the VPS (keep the same IP if you can: it keeps your reverse DNS and reputation), then run
   recipes 01 to 07 as for a first build (and 09, 10, 11 if you use them: the Google module must be installed
   before its state is put back in step 4). Recipe 03 does Stalwart's first setup: it writes
   `/etc/stalwart/config.json` (where the data lives), which isn't in the backup. Everything else you set up comes
   back with the data, except the API key the tools use (step 5). Skip `recipe/03-stalwart-admin.md`: the restored
   admin account keeps its password and two-factor.
2. `./nv sh tools/b2-setup.sh` (a new key for the new server, the same restic password), then run recipe 08. It
   installs restic, the timers and `nv-restore`, and it won't re-create an existing repository.
3. On the server, `ssh root@<server> nv-restore` lists the snapshots. Pick one **by its ID** (its date and size must
   be the old server's: a backup made after the rebuild would be the empty new server).
4. `ssh root@<server> nv-restore <snapshot-id>`. It stops the backups (so the empty new server can't become the newest
   snapshot), the Google module, Stalwart and webmail; restores that snapshot; puts Stalwart's data, Roundcube's
   database and the Google module's state in place (the data it replaces is kept in `/var/lib/stalwart-empty`); and
   starts Stalwart and webmail again. Backups and the Google module stay stopped until step 6.
5. What wasn't in the backup, on purpose:
   - TLS certificates: recipe 02 issues new ones.
   - Roundcube's `des_key`: recipe 07 makes a new one, so outgoing-server passwords saved per identity (the
     `identity_smtp` plugin, if you use it) can't be read. Re-enter them under Settings → Identities, or with
     `tools/migrate/rc-smtp-password.php`.
   - The tools' API key: `/root/.secrets/laptop-api.key` holds the fresh install's key, which the restored database
     doesn't know. Make a new one: `ssh root@<server> rm /root/.secrets/laptop-api.key /root/.secrets/stalwart-admin`,
     then `./nv run recipe/03-stalwart.sh` (it creates a key for the restored admin account). Until then the tools
     fail. The old key from before is still in the database: delete it in the WebUI (your account › Credentials ›
     API Keys) if you no longer have it.
   - SSH host keys are new: on your computer, `ssh-keygen -R <server>` and accept the new fingerprint once.
6. Check: log in to webmail, send and receive a test message, open a few old folders. Then
   `ssh root@<server> nv-restore --done`: it starts the backups and the Google module again and deletes the replaced
   data and the scratch copy.

## One mailbox, or a few messages

Don't restore over the live server. Restore the snapshot to a scratch folder, run a second Stalwart on it in
recovery mode on another port, and copy out what you need over IMAP or JMAP:

```sh
set -a; . /root/.secrets/restic.env; set +a
restic restore latest --target /var/tmp/r --include /var/lib/stalwart-snap
# a copy of /etc/stalwart/config.json with its data path set to /var/tmp/r/var/lib/stalwart-snap, then:
STALWART_RECOVERY_MODE=1 STALWART_RECOVERY_MODE_PORT=18080 /usr/local/bin/stalwart --config /var/tmp/r-config.json
```

Then, for example, export the account with Vandelay from the scratch server and import just the folder you need
into the live one. Stop the scratch server and delete `/var/tmp/r` afterwards.

## Test a restore

After the first build, and again after big changes. On a new server there's no backup until the first nightly run
(03:15 UTC): make one now with `ssh root@<server> 'systemctl start nv-backup && journalctl -u nv-backup -n 5'`.
Then do the "one mailbox" steps without copying anything out, and compare the scratch server's message and folder
counts with the live server's (in the WebUI, or ask your agent to count both through the API). A backup you've never restored is a
hope, not a backup.

## If a backup ever leaked

The backups are encrypted, but if you believe the restic password and the repository both leaked: rotate the DKIM
keys (and publish the new DNS records), reset the admin account's TOTP, revoke and re-create the API keys, and have
everyone change their password.
