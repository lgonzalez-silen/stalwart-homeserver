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
# Not cloud-init? Some images (OpenNebula's one-context) also reset the hostname and /etc/resolv.conf at every
# boot: check both after recipe 01's reboot. For one-context, move net-15-hostname and loc-10-network out of
# /etc/one-context.d (renaming isn't enough: it runs every file in there).
[ -n "${NV_SERVER_PROVIDER_HOSTNAME:-}" ] && sed -i "/$NV_SERVER_PROVIDER_HOSTNAME/d" /etc/hosts
add_line /etc/hosts "$PUBLIC_IP	$HOST $SHORT"
[ -n "$PUBLIC_IP6" ] && add_line /etc/hosts "$PUBLIC_IP6	$HOST $SHORT"   # IPv6 only if the server has it

echo "== packages + updates"
# --nobest: when EPEL briefly ships an update that needs a newer AlmaLinux package than exists yet (seen with
# python3-pyOpenSSL), upgrade everything else and keep that one at its current version instead of failing
dnf -y -q upgrade --nobest
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
nmcli con mod "$CON" ipv4.dns "127.0.0.1" ipv4.ignore-auto-dns yes ipv4.dns-search ""
# IPv6 resolver settings only where IPv6 is on (NetworkManager refuses them when ipv6.method=ignore)
[ "$(nmcli -g ipv6.method con show "$CON")" != ignore ] && \
  nmcli con mod "$CON" ipv6.dns "::1" ipv6.ignore-auto-dns yes ipv6.dns-search ""
nmcli con up "$CON" >/dev/null
# fallback if NM keeps stale search domains
sed -i '/^search /d' /etc/resolv.conf
# Some providers' context tools write /etc/resolv.conf themselves, bypassing NetworkManager (OpenNebula's
# one-context does). Then: NetworkManager keeps out of DNS, the file is written here, and the tool's periodic
# reconfigure (which would rewrite it) is switched off. First-boot setup by the tool is unaffected.
if live && ! grep -q '^nameserver 127.0.0.1' /etc/resolv.conf; then
  printf '[main]\ndns=none\n' | put /etc/NetworkManager/conf.d/90-nv-dns.conf
  systemctl reload NetworkManager
  printf 'nameserver 127.0.0.1\n' | put /etc/resolv.conf
  systemctl disable --now one-context-reconfigure.timer 2>/dev/null || true
  echo "resolv.conf was managed by something else: now fixed to the local resolver"
fi

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
# Refuse to switch password login off unless root can log in with a key (or you'd be left with the provider console)
live && { [ -s /root/.ssh/authorized_keys ] && grep -qE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys || {
  echo "no SSH key in /root/.ssh/authorized_keys: add yours first (provider panel or ssh-copy-id), then re-run"; exit 1; }; }
# sshd uses the FIRST value it reads, and provider images drop their own files in here (00-togglebox.conf with
# "PasswordAuthentication yes" on one, 50-cloud-init.conf on others). Ours sorts first, and the effective settings
# are checked below, so a file that still wins can't leave password login on silently.
rm -f /etc/ssh/sshd_config.d/10-hardening.conf   # this file's old name
put /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
# Read before the provider's files (first match applies); recipe/01 checks the result with sshd -T
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 4
EOF
sshd -t
systemctl reload sshd
if live; then
  eff=$(sshd -T 2>/dev/null)
  if ! grep -qx "passwordauthentication no" <<<"$eff" || ! grep -qxE "permitrootlogin (prohibit-password|without-password)" <<<"$eff"; then
    echo "SSH is NOT keys-only: another file wins. Files that set it:"
    grep -HnE "^\s*(PasswordAuthentication|PermitRootLogin)" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf
    echo "Remove or rename the overriding file (keep a fresh SSH session open), then re-run."; exit 1
  fi
  echo "SSH effective: $(grep -E '^(passwordauthentication|permitrootlogin)' <<<"$eff" | tr '\n' ' ')"
fi

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
# Relabel whenever SELinux is off right now, even if the config already says enforcing (an image can boot with
# selinux=0 on the kernel line): enforcing on an unlabeled disk can lock everyone out, sshd included.
if [ "$(getenforce)" = "Disabled" ]; then touch /.autorelabel; NEED_REBOOT=yes; fi
grep -q '^SELINUX=enforcing' /etc/selinux/config 2>/dev/null || NEED_REBOOT=yes
put /etc/selinux/config <<'EOF'
SELINUX=enforcing
SELINUXTYPE=targeted
EOF
[ "$(getenforce)" = "Permissive" ] && setenforce 1 || true
grubby --update-kernel ALL --remove-args selinux >/dev/null 2>&1 || true

echo "== summary"
hostnamectl --static
grep -E '^(nameserver|search)' /etc/resolv.conf
SPAMHAUS=$(dig +short +time=10 +tries=3 @127.0.0.1 2.0.0.127.zen.spamhaus.org A | head -1)
echo "spamhaus test (expect 127.0.0.x): ${SPAMHAUS:-NO ANSWER (right after a resolver restart that can be normal: run the dig again in a minute)}"
firewall-cmd --zone=public --list-services
sshd -T | grep -E '^(passwordauthentication|permitrootlogin) '
swapon --show --noheadings
echo "reboot needed: $NEED_REBOOT"
