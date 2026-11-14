<?php
// Apply ported identities + chosen prefs to one Roundcube user (run on the server as the web server user, e.g. nginx; back up the Roundcube DB first).
// Usage: sudo -u nginx php rc-apply-identities.php <username> <bcc> < ids.json   (from tools/rc-old-identities.py)
// Prefs set: reply above indented quote, HTML when replying/forwarding HTML, sort by date desc, 200 per page.
[$_, $user, $bcc] = $argv;
$ids = json_decode(stream_get_contents(STDIN), true);
$db = new PDO('sqlite:/var/lib/roundcube/roundcube.db'); $db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$st = $db->prepare('select user_id, preferences from users where username = ?'); $st->execute([$user]);
$u = $st->fetch(PDO::FETCH_ASSOC) or die("no such user\n");
$uid = $u['user_id'];
$db->beginTransaction();
$emails = array_column($ids, 'email');
$in = implode(',', array_fill(0, count($emails), '?'));
$db->prepare("delete from identities where user_id = ? and email in ($in)")->execute(array_merge([$uid], $emails));
if (array_sum(array_column($ids, 'standard'))) $db->prepare('update identities set standard = 0 where user_id = ?')->execute([$uid]);
$ins = $db->prepare('insert into identities (user_id, changed, del, standard, name, organization, email, "reply-to", bcc, signature, html_signature) values (?, datetime("now"), 0, ?, ?, ?, ?, ?, ?, ?, ?)');
foreach ($ids as $i) $ins->execute([$uid, $i['standard'], $i['name'], $i['organization'], $i['email'], $i['replyto'], $bcc, $i['signature'], $i['html_signature']]);
$p = $u['preferences'] ? unserialize($u['preferences']) : [];
$p = array_merge($p, ['reply_mode' => 1, 'htmleditor' => 3, 'message_sort_col' => 'date', 'message_sort_order' => 'DESC', 'mail_pagesize' => 200]);
$db->prepare('update users set preferences = ? where user_id = ?')->execute([serialize($p), $uid]);
$db->commit();
$n = $db->query("select count(*) from identities where user_id = $uid and del = 0")->fetchColumn();
echo "user $user: $n identities now; prefs set: reply_mode=1 htmleditor=3 sort=date DESC pagesize=200 (skin kept: " . ($p['skin'] ?? 'default') . ")\n";
