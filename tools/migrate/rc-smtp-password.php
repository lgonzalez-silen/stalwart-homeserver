<?php
// Set the outgoing (identity_smtp) password of one Roundcube identity, typed without echo, stored encrypted with
// Roundcube's des_key exactly as the plugin's own form does. Then tests an SMTP login with it.
// Run interactively:  ssh -t root@<server> sudo -u nginx php rc-smtp-password.php alice alice@school.example.edu
define('INSTALL_PATH', '/var/www/roundcube/');
require INSTALL_PATH . 'program/include/clisetup.php';
[$_, $user, $email] = $argv;
$rc = rcmail::get_instance();
$host = parse_url($rc->config->get('imap_host'), PHP_URL_HOST);
$u = rcube_user::query($user, $host) or die("no Roundcube user $user\n");
$rc->user = $u;
$ident = null;
foreach ($u->list_identities() as $i) if (strtolower($i['email']) === strtolower($email)) $ident = $i;
$ident or die("$user has no identity $email\n");
$prefs = $u->get_prefs(); $is = $prefs['identity_smtp'] ?? [];
$s = $is[$ident['identity_id']] ?? null;
($s && $s['smtp_host']) or die("identity $email has no SMTP server set (run rc-port-user.php first)\n");

fwrite(STDERR, "App password for {$s['smtp_user']} (spaces are fine): ");
system('stty -echo'); $pw = trim(fgets(STDIN)); system('stty echo'); fwrite(STDERR, "\n");
$pw = str_replace(' ', '', $pw);
if (!preg_match('/^[a-zA-Z]{16}$/', $pw)) die("that doesn't look like a Google app password (16 letters); nothing saved\n");

// test the login first (STARTTLS on 587), so a typo isn't saved
$smtp = new rcube_smtp();
if (!$smtp->connect($s['smtp_host'], null, $s['smtp_user'], $pw)) {
    $err = $smtp->get_error(); die("SMTP login to {$s['smtp_host']} as {$s['smtp_user']} FAILED: " . json_encode($err) . "\nnothing saved\n");
}
$smtp->disconnect();

$is[$ident['identity_id']]['smtp_pass'] = $rc->encrypt($pw);
$u->save_prefs(['identity_smtp' => $is]);
echo "$user / $email: SMTP login OK as {$s['smtp_user']} via {$s['smtp_host']}; password saved (encrypted)\n";
