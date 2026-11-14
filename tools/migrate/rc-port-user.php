<?php
// Port one user's old Roundcube identities to the new server BEFORE their first webmail login, without
// touching their other prefs. Run on the server as the web server user (nginx), after a DB backup:
//   sudo -u nginx php rc-port-user.php <username> <smtp-json> [--force] < ids.json      (ids.json from tools/rc-old-identities.py)
//   smtp-json: per-identity outgoing server, e.g. '{"alice@school.example.edu":{"host":"tls://smtp.gmail.com:587","user":"alice@school.example.edu"}}'
//              or '{}' for none. Passwords are NOT set here: use rc-smtp-password.php (prompts, no echo).
// - creates the Roundcube user (as a first login would) if it doesn't exist yet
// - replaces the auto-created placeholder identity with the ported ones (exact email/name/signature/default)
// - writes identity_smtp settings (smtp_standard=false, host, user; password left empty)
define('INSTALL_PATH', '/var/www/roundcube/');
require INSTALL_PATH . 'program/include/clisetup.php';
$force = in_array('--force', $argv); $argv = array_values(array_diff($argv, ['--force']));
[$_, $user, $smtpJson] = $argv;
$smtp = json_decode($smtpJson, true); if (!is_array($smtp)) die("bad smtp-json\n");
$ids = json_decode(stream_get_contents(STDIN), true); if (!$ids) die("no identities on stdin\n");
$rc = rcmail::get_instance();
$host = parse_url($rc->config->get('imap_host'), PHP_URL_HOST);   // 127.0.0.1, as in existing users rows
$u = rcube_user::query($user, $host);
if (!$u) { $u = rcube_user::create($user, $host) or die("create failed\n"); echo "created Roundcube user $user\n"; }
else {
    // an existing user may have real identities: replacing them is only safe on a never-used account
    $n = $rc->get_dbh()->fetch_array($rc->get_dbh()->query('select count(*) from ' . $rc->get_dbh()->table_name('identities') . ' where user_id = ? and del = 0', $u->ID))[0];
    if (($n > 1 || !empty($u->data['last_login'])) && !$force)
        die("$user already has $n identities / has logged in: use rc-apply-identities.php, or --force to replace them all\n");
}
$rc->user = $u;
$db = $rc->get_dbh();
$uid = $u->ID;
// remove every current identity (only the auto-created placeholder on a fresh user), then insert the ported ones
$db->query('update ' . $db->table_name('identities') . ' set del = 1 where user_id = ?', $uid);
foreach ($ids as $i) {
    $db->query('insert into ' . $db->table_name('identities') .
        ' (user_id, changed, del, standard, name, organization, email, "reply-to", bcc, signature, html_signature)' .
        ' values (?, ' . $db->now() . ', 0, ?, ?, ?, ?, ?, ?, ?, ?)',
        $uid, (int)$i['standard'], $i['name'], $i['organization'], $i['email'], $i['replyto'] ?? '', '',
        $i['signature'], (int)$i['html_signature']);
}
$prefs = $u->get_prefs();
$is = $prefs['identity_smtp'] ?? [];
foreach ($u->list_identities() as $ident) {
    $e = strtolower($ident['email']);
    if (isset($smtp[$e])) {
        $is[$ident['identity_id']] = ['smtp_standard' => false, 'smtp_host' => $smtp[$e]['host'],
                                      'smtp_user' => $smtp[$e]['user'], 'smtp_pass' => $is[$ident['identity_id']]['smtp_pass'] ?? ''];
    }
}
$u->save_prefs(['identity_smtp' => $is]);
foreach ($u->list_identities() as $ident) {
    $s = $is[$ident['identity_id']] ?? null;
    printf("%s  %s  default=%d  signature=%d chars  smtp=%s\n", $user, $ident['email'], $ident['standard'],
           strlen($ident['signature'] ?? ''), $s ? $s['smtp_host'] . ' as ' . $s['smtp_user'] . ($s['smtp_pass'] ? ' (password set)' : ' (password NOT set)') : 'this server (default)');
}
