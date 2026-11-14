#!/bin/bash
# recipe/01-base.sh — base OS setup (AlmaLinux 10 VPS)
# Run from your computer:  ./nv run recipe/01-base.sh
# Idempotent: safe to re-run. Reboot afterwards if SELinux was just enabled.
#
# Prereqs (your provider's panel): plain AlmaLinux 10 image, your SSH key attached, root password stored in your
# password manager, reverse DNS (PTR) of both IPs -> server.hostname, provider firewall (if it has one):
# TCP 22,25,80,443,465,587,993 + ICMP accept, drop rest.
# Settings: server.hostname, server.ipv4, server.ipv6, server.provider_hostname (optional: the hostname the
# provider's image put in /etc/hosts, removed here).

HOST=$NV_SERVER_HOSTNAME
SHORT=${HOST%%.*}
PUBLIC_IP=$NV_SERVER_IPV4
PUBLIC_IP6=$NV_SERVER_IPV6

echo "== hostname + hosts (and stop cloud-init from reverting them)"
hostnamectl set-hostname "$HOST"
put /etc/cloud/cloud.cfg.d/99-local.cfg <<'EOF'
# Keep our hostname and /etc/hosts across reboots
preserve_hostname: true
manage_etc_hosts: false
EOF
# cloud-init otherwise re-renders the NetworkManager profile (DNS servers, search
# "localhost") on every boot. The static IP/gateway it wrote on first boot stays.
put /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF
[ -n "${NV_SERVER_PROVIDER_HOSTNAME:-}" ] && sed -i "/$NV_SERVER_PROVIDER_HOSTNAME/d" /etc/hosts
add_line /etc/hosts "$PUBLIC_IP	$HOST $SHORT"
add_line /etc/hosts "$PUBLIC_IP6	$HOST $SHORT"

echo "== packages + updates"
dnf -y -q upgrade
dnf -y -q install epel-release
dnf -y -q install firewalld dnf-automatic unbound bind-utils policycoreutils-python-utils \
  vim-enhanced tar rsync jq lsof tmux

echo "== automatic security updates (apply; reboot only when an update needs it, e.g. a new kernel)"
mkdir -p /etc/dnf/automatic.conf.d 2>/dev/null || true
put /etc/dnf/automatic.conf <<'EOF'
[commands]
upgrade_type = security
download_updates = yes
apply_updates = yes
# kernel/glibc/systemd fixes only take effect after a reboot; the timer runs ~06:35 UTC
reboot = when-needed
reboot_command = "shutdown -r +1 'Rebooting after security updates'"

[emitters]
emit_via = stdio

[base]
debuglevel = 1
EOF
systemctl enable --now dnf-automatic.timer

echo "== local DNS resolver (DNSBLs like Spamhaus refuse public resolvers)"
put /etc/unbound/conf.d/local.conf <<'EOF'
server:
    interface: 127.0.0.1
    interface: ::1
    access-control: 127.0.0.0/8 allow
    access-control: ::1/128 allow
    prefetch: yes
    qname-minimisation: yes
EOF
systemctl enable --now unbound
systemctl restart unbound
CON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: '$2=="eth0"{print $1}')
nmcli con mod "$CON" ipv4.dns "127.0.0.1" ipv4.ignore-auto-dns yes ipv4.dns-search "" \
                     ipv6.dns "::1" ipv6.ignore-auto-dns yes ipv6.dns-search ""
nmcli con up "$CON" >/dev/null
# fallback if NM keeps stale search domains
sed -i '/^search /d' /etc/resolv.conf

echo "== firewalld (mirror of the provider's firewall)"
systemctl enable --now firewalld
firewall-cmd -q --permanent --zone=public --set-target=default
for s in ssh smtp http https smtps smtp-submission imaps; do
  firewall-cmd -q --permanent --zone=public --add-service=$s
done
for s in cockpit dhcpv6-client; do
  firewall-cmd -q --permanent --zone=public --remove-service=$s 2>/dev/null || true
done
firewall-cmd -q --reload

echo "== SSH: keys only"
put /etc/ssh/sshd_config.d/10-hardening.conf <<'EOF'
# Loaded before 50-cloud-init.conf, so these win (first match applies)
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 4
EOF
sshd -t
systemctl reload sshd

echo "== persistent journal (keep history across reboots)"
mkdir -p /var/log/journal /etc/systemd/journald.conf.d
put /etc/systemd/journald.conf.d/10-persistent.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=1G
EOF
systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald

echo "== 2G swapfile"
if ! swapon --show | grep -q /swapfile; then
  [ -f /swapfile ] || { fallocate -l 2G /swapfile; chmod 600 /swapfile; mkswap -q /swapfile; }
  swapon /swapfile
  add_line /etc/fstab '/swapfile none swap defaults 0 0'
fi

echo "== SELinux enforcing (needs reboot + relabel if it was disabled)"
# Write the whole file: on some provider images it ends up empty (0 bytes) after
# the first dnf upgrade, and an empty config silently means permissive.
NEED_REBOOT=no
if ! grep -q '^SELINUX=enforcing' /etc/selinux/config 2>/dev/null; then
  [ "$(getenforce)" = "Disabled" ] && touch /.autorelabel
  NEED_REBOOT=yes
fi
put /etc/selinux/config <<'EOF'
SELINUX=enforcing
SELINUXTYPE=targeted
EOF
[ "$(getenforce)" = "Permissive" ] && setenforce 1 || true
grubby --update-kernel ALL --remove-args selinux >/dev/null 2>&1 || true

echo "== summary"
hostnamectl --static
grep -E '^(nameserver|search)' /etc/resolv.conf
dig +short +time=10 +tries=3 @127.0.0.1 2.0.0.127.zen.spamhaus.org A | head -1 | sed 's/^/spamhaus test (expect 127.0.0.x): /'
firewall-cmd --zone=public --list-services
sshd -T | grep -E '^(passwordauthentication|permitrootlogin) '
swapon --show --noheadings
echo "reboot needed: $NEED_REBOOT"
