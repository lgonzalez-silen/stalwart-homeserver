# Restoring from backup

Keep an offline copy of this page with your password manager. You'll need it on the day nothing else works.

**What the backups hold** (nightly restic snapshots on Backblaze B2, `recipe/08-backup.sh`): Stalwart's database
(all mail, accounts, settings, DKIM keys) and Roundcube's database. No configuration and no secrets: the recipes
rebuild the configuration, and your password manager holds the secrets.

**What you need:** the contents of `/root/.secrets/restic.env` (RESTIC_REPOSITORY, RESTIC_PASSWORD, B2_ACCOUNT_ID,
B2_ACCOUNT_KEY), kept in your password manager. **Without RESTIC_PASSWORD the backups can't be read by anyone,
including you.**

For scale: on the server this came from, restoring an 8 GB snapshot took about a minute and a half.

## Whole server

1. A fresh AlmaLinux 10 on the VPS (keep the same IP if you can: it keeps your reverse DNS and reputation), then run
   recipes 01 to 07 as for a first build (and 09, 10, 11 if you use them: the Google module must be installed
   before its state is put back in step 4), including Stalwart's setup wizard: it writes `/etc/stalwart/config.json`
   (where the data lives), which isn't in the backup. Everything you set up after the wizard comes back with the data,
   except one thing: the API key the tools use (see step 5).
2. Stop the services that use the data: `ssh root@<server> 'systemctl stop stalwart php-fpm'`
3. Put `/root/.secrets/restic.env` back (mode 0600, fields from your password manager), then run recipe 08. It
   installs restic and the timers, and it won't re-create an existing repository.
4. Restore, on the server:

   ```sh
   set -a; . /root/.secrets/restic.env; set +a
   restic snapshots --compact | tail -5          # pick one; "latest" is last night
   restic restore latest --target /var/tmp/r
   mv /var/lib/stalwart /var/lib/stalwart-empty
   mv /var/tmp/r/var/lib/stalwart-snap /var/lib/stalwart && chown -R stalwart:stalwart /var/lib/stalwart
   install -o nginx -g nginx -m 640 /var/tmp/r/var/backups/nv/roundcube.db /var/lib/roundcube/roundcube.db
   # Google module only: where each pull stopped, so mail since the backup is still fetched.
   # (recipe 11 must have run first; if this says "not found", run it, then repeat these three lines)
   systemctl stop nv-fetch nv-spam-mirror.timer nv-google-trim.timer
   install -m 600 /var/tmp/r/var/backups/nv/nv-fetch-state.db /var/lib/nv-fetch/state.db
   ls -l /var/lib/nv-fetch/state.db
   restorecon -R /var/lib/stalwart /var/lib/roundcube
   systemctl start stalwart php-fpm
   ```

5. What wasn't in the backup, on purpose:
   - TLS certificates: recipe 02 issues new ones.
   - Roundcube's `des_key`: recipe 06 makes a new one, so outgoing-server passwords saved per identity (the
     `identity_smtp` plugin) can't be read. Re-enter them under Settings → Identities, or with
     `tools/migrate/rc-smtp-password.php`.
   - The tools' API key: the restored database has the API key you made before, but `/root/.secrets/laptop-api.key`
     holds the one from the fresh install. Either put the old key back from your password manager, or make a new
     one in the WebUI (allowed IPs 127.0.0.1, ::1) and write it to that file (mode 0600). Until then the tools fail.
   - SSH host keys are new: on your computer, `ssh-keygen -R <server>` and accept the new fingerprint once.
6. Check: log in to webmail, send and receive a test message, open a few old folders, and
   `systemctl list-timers 'nv-backup*'`, and (Google module) `systemctl start nv-fetch nv-spam-mirror.timer nv-google-trim.timer`. Delete `/var/lib/stalwart-empty` and `/var/tmp/r` when you're happy.

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

After the first build, and again after big changes: do the "one mailbox" steps without copying anything out, and
compare the scratch server's message and folder counts with the live server's. A backup you've never restored is a
hope, not a backup.

## If a backup ever leaked

The backups are encrypted, but if you believe the restic password and the repository both leaked: rotate the DKIM
keys (and publish the new DNS records), reset the admin account's TOTP, revoke and re-create the API keys, and have
everyone change their password.
