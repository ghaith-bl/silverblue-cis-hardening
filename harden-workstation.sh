#!/usr/bin/env bash
# =============================================================================
# harden-workstation.sh
# CIS Fedora Benchmark L2 (Workstation) — tailored for:
#   Fedora Silverblue 44 · KVM/libvirt · Steam (Flatpak) · ProtonVPN (WireGuard)
#
# Usage:
#   ./harden-workstation.sh --list                 show sections
#   sudo ./harden-workstation.sh sysctl modules    run selected sections
#   sudo ./harden-workstation.sh all               run every section
#
# Every file this script replaces is copied first to:
#   /var/backups/hardening/<timestamp>/<original path>
#
# Deliberately NOT applied (would break this machine):
#   - overlay module blacklist  -> Silverblue composefs, podman/toolbox
#   - XWayland disabled         -> Steam client and most games run on X11
#   - ip_forward = 0 / remove dnsmasq -> libvirt NAT network for KVM, rootful podman
#   - rp_filter = 1 (strict)    -> can drop ProtonVPN WireGuard traffic (using 2)
#   - forced password expiry    -> NIST SP 800-63B advises against it
#   - auditd HALT               -> a full disk would halt the laptop
#   - auditd KEEP_LOGS          -> no limit, /var also holds /var/home (ROTATE, 40 x 32 MiB)
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Decisions — review before running
# -----------------------------------------------------------------------------
DISABLE_USB_STORAGE="no"     # "yes" = USB flash drives / external disks stop working
DISABLE_BLUETOOTH="no"       # "yes" = no Bluetooth headsets / game controllers
DISABLE_AVAHI="yes"          # "no"  if you use network printers or mDNS discovery
ENABLE_NOISY_AUDIT="no"      # "yes" = log every chmod/chown/delete/denied-open by users (very noisy with Steam/Brave)
MAKE_AUDIT_IMMUTABLE="no"    # "yes" = audit rules locked until reboot (-e 2). Enable after a week of testing.
SSH_SERVER="off"             # "on" = keep sshd usable (hardened) so other machines can SSH INTO this laptop.
                             # Outgoing ssh from this laptop to VMs / homelab works either way.
FINGERPRINT="disable"        # "keep" if you use a fingerprint reader ("disable" avoids fast faillock lockouts)
MIC_DISABLE="internal"       # "internal" = laptop mic + 3.5mm jack mic off (USB/Bluetooth mics still work)
                             # "all" = every mic off | "no" = leave microphones alone
IDLE_LOCK_SECONDS=900        # screen locks after 15 minutes idle
TARGET_USER="${SUDO_USER:-}" # your login user (taken from sudo)

BACKUP_ROOT="/var/backups/hardening/$(date +%Y%m%d-%H%M%S)"
SECTIONS=(sysctl modules coredump journald gnome sudo pam su services cron sshd auditd audit-rules perms mic)

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log()  { printf '\e[32m[+]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[!]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[31m[x]\e[0m %s\n' "$*" >&2; exit 1; }

backup() {
  local f
  for f in "$@"; do
    if [[ -e "$f" || -L "$f" ]]; then
      mkdir -p "${BACKUP_ROOT}$(dirname "$f")"
      cp -a "$f" "${BACKUP_ROOT}${f}"
    fi
  done
}

# write_file <path> <mode>   (content comes from stdin)
write_file() {
  local path="$1" mode="$2"
  backup "$path"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  chmod "$mode" "$path"
  restorecon -F "$path" 2>/dev/null || true
  log "wrote $path"
}

# set_kv <file> <key> <value>   ->   "key = value" (replaces commented or existing line)
set_kv() {
  local file="$1" key="$2" val="$3"
  if grep -Eq "^[#[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$file"
  else
    printf '%s = %s\n' "$key" "$val" >> "$file"
  fi
  restorecon -F "$file" 2>/dev/null || true
}

unit_exists() { systemctl list-unit-files --no-legend "$1" 2>/dev/null | grep -q .; }

mask_units() {
  local u
  for u in "$@"; do
    if unit_exists "$u"; then
      if systemctl mask --now "$u" >/dev/null 2>&1; then log "masked $u"; else warn "could not mask $u"; fi
    fi
  done
}

user_home() { getent passwd "$1" | cut -d: -f6; }

# -----------------------------------------------------------------------------
# Sections
# -----------------------------------------------------------------------------
sec_sysctl() {
  write_file /etc/sysctl.d/90-hardening.conf 0644 <<'EOF'
# ---- Kernel ----
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
kernel.randomize_va_space = 2
kernel.kexec_load_disabled = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1

# ---- IPv4 ----
# net.ipv4.ip_forward is intentionally NOT set to 0: libvirt NAT (KVM) needs it.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
# 2 = loose mode. CIS asks for 1 (strict), which can drop WireGuard (ProtonVPN) traffic.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1

# ---- IPv6 ----
# NetworkManager processes Router Advertisements itself, so the kernel does not need to.
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
# No IPv6 consumer here (libvirt default network is IPv4-only, podman default
# network has no IPv6). If you later create an IPv6 podman/libvirt network,
# remove these two lines.
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0
EOF
  if sysctl --system >/dev/null; then log "sysctl applied"; else warn "some sysctl keys failed — run: sudo sysctl --system"; fi
}

sec_modules() {
  local m mods=(cramfs freevxfs hfs hfsplus jffs2 squashfs udf atm can dccp rds sctp tipc firewire-core)
  if [[ $DISABLE_USB_STORAGE == yes ]]; then mods+=(usb-storage); fi
  {
    echo "# CIS: unused filesystems and network protocols"
    echo "# overlay is NOT listed on purpose (Silverblue composefs, podman/toolbox)"
    for m in "${mods[@]}"; do
      printf 'install %s /bin/false\nblacklist %s\n' "$m" "$m"
    done
  } | write_file /etc/modprobe.d/90-cis-blacklist.conf 0644
  log "modules blocked (already-loaded ones go away after reboot)"
}

sec_coredump() {
  write_file /etc/systemd/coredump.conf.d/90-cis.conf 0644 <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
  write_file /etc/security/limits.d/90-cis-coredump.conf 0644 <<'EOF'
*    hard    core    0
EOF
  systemctl daemon-reload
}

sec_journald() {
  write_file /etc/systemd/journald.conf.d/90-cis.conf 0644 <<'EOF'
[Journal]
Storage=persistent
Compress=yes
ForwardToSyslog=no
EOF
  systemctl restart systemd-journald && log "journald restarted"
}

sec_gnome() {
  local profile_src content
  if ! grep -qs 'system-db:local' /etc/dconf/profile/user /usr/share/dconf/profile/user; then
    profile_src=/etc/dconf/profile/user
    [[ -e $profile_src ]] || profile_src=/usr/share/dconf/profile/user
    if [[ -e $profile_src ]]; then content=$(cat "$profile_src"); else content="user-db:user"; fi
    printf '%s\nsystem-db:local\n' "$content" | write_file /etc/dconf/profile/user 0644
  fi

  write_file /etc/dconf/db/local.d/90-cis-hardening 0644 <<EOF
[org/gnome/desktop/media-handling]
automount=false
automount-open=false
autorun-never=true

[org/gnome/desktop/screensaver]
lock-enabled=true
lock-delay=uint32 5

[org/gnome/desktop/session]
idle-delay=uint32 ${IDLE_LOCK_SECONDS}
EOF

  write_file /etc/dconf/db/local.d/locks/90-cis-hardening 0644 <<'EOF'
/org/gnome/desktop/media-handling/automount
/org/gnome/desktop/media-handling/automount-open
/org/gnome/desktop/media-handling/autorun-never
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/lock-delay
/org/gnome/desktop/session/idle-delay
EOF

  if grep -qs 'system-db:gdm' /etc/dconf/profile/gdm /usr/share/dconf/profile/gdm; then
    write_file /etc/dconf/db/gdm.d/90-cis-hardening 0644 <<'EOF'
[org/gnome/login-screen]
disable-user-list=true
EOF
  else
    warn "gdm dconf profile not found — skipped hiding the login user list"
  fi
  dconf update && log "dconf databases updated (log out/in to see changes)"
}

sec_sudo() {
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
Defaults use_pty
Defaults logfile="/var/log/sudo.log"
Defaults timestamp_timeout=5
EOF
  if visudo -cqf "$tmp"; then
    write_file /etc/sudoers.d/90-cis 0440 < "$tmp"
    if ! visudo -cq; then
      rm -f /etc/sudoers.d/90-cis
      die "full sudoers check failed — removed /etc/sudoers.d/90-cis"
    fi
  else
    warn "sudoers snippet failed validation — not installed"
  fi
  rm -f "$tmp"
}

sec_pam() {
  local profile feat
  if ! authselect check >/dev/null 2>&1; then
    warn "authselect reports manual PAM edits — skipping PAM section"
    return 0
  fi
  profile=$(authselect current --raw | awk '{print $1}')
  if authselect current --raw | grep -qw with-fingerprint; then
    if [[ $FINGERPRINT == disable ]]; then
      authselect disable-feature with-fingerprint >/dev/null && log "authselect: disabled with-fingerprint"
    else
      warn "with-fingerprint is enabled: failed fingerprint reads can count toward faillock lockouts"
    fi
  fi
  for feat in with-faillock with-pwhistory without-nullok; do
    if authselect list-features "$profile" | grep -qx "$feat"; then
      authselect enable-feature "$feat" >/dev/null && log "authselect: enabled $feat"
    else
      warn "authselect profile '$profile' has no feature '$feat'"
    fi
  done
  authselect apply-changes >/dev/null

  backup /etc/security/faillock.conf /etc/security/pwhistory.conf
  set_kv /etc/security/faillock.conf deny 5
  set_kv /etc/security/faillock.conf fail_interval 900
  set_kv /etc/security/faillock.conf unlock_time 900
  set_kv /etc/security/pwhistory.conf remember 24
  log "faillock: 5 failures -> locked 15 min | pwhistory: last 24 passwords"

  # Written to the main pwquality.conf (the scanner only checks that file).
  local pq=/etc/security/pwquality.conf kv
  backup "$pq"
  for kv in minlen=14 minclass=4 difok=2 maxrepeat=3 maxsequence=3 dictcheck=1; do
    set_kv "$pq" "${kv%%=*}" "${kv#*=}"
  done
  grep -qx 'enforce_for_root' "$pq" || echo 'enforce_for_root' >> "$pq"
  if [[ -e /etc/security/pwquality.conf.d/90-cis.conf ]]; then
    backup /etc/security/pwquality.conf.d/90-cis.conf
    rm -f /etc/security/pwquality.conf.d/90-cis.conf
  fi
  log "pwquality: min 14 chars, 4 character classes"
}

sec_su() {
  groupadd -f sugroup
  if [[ -n "$(getent group sugroup | cut -d: -f4)" ]]; then
    warn "group sugroup has members — su rule not added"
    return 0
  fi
  if grep -Eq '^auth[[:space:]]+required[[:space:]]+pam_wheel\.so.*group=sugroup' /etc/pam.d/su; then
    log "su already restricted"
    return 0
  fi
  backup /etc/pam.d/su
  sed -i -E '/^auth[[:space:]]+sufficient[[:space:]]+pam_rootok\.so/a auth            required        pam_wheel.so use_uid group=sugroup' /etc/pam.d/su
  if grep -q 'group=sugroup' /etc/pam.d/su; then
    log "su restricted to the empty group sugroup (use sudo instead)"
  else
    warn "pam_rootok line not found in /etc/pam.d/su — nothing changed"
  fi
}

sec_services() {
  mask_units rpcbind.socket rpcbind.service nfs-server.service
  if [[ $DISABLE_AVAHI == yes ]]; then mask_units avahi-daemon.socket avahi-daemon.service; fi
  if [[ $DISABLE_BLUETOOTH == yes ]]; then mask_units bluetooth.service; fi
  # nftables.service must NOT be stopped live: its stop action flushes the whole
  # ruleset (firewalld + ProtonVPN kill switch). Disable + mask only.
  if unit_exists nftables.service; then
    systemctl disable nftables.service >/dev/null 2>&1 || true
    systemctl mask nftables.service >/dev/null 2>&1 && log "nftables.service masked (firewalld manages nftables)"
  fi
}

sec_cron() {
  local f
  for f in /etc/crontab /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.yearly; do
    if [[ -e $f ]]; then chown root:root "$f"; chmod og-rwx "$f"; fi
  done
  if [[ -e /etc/cron.deny ]]; then backup /etc/cron.deny; rm -f /etc/cron.deny; fi
  if [[ -n $TARGET_USER ]]; then
    printf 'root\n%s\n' "$TARGET_USER" | write_file /etc/cron.allow 0640
  else
    echo root | write_file /etc/cron.allow 0640
  fi
  echo root | write_file /etc/at.allow 0640
  log "cron/at access limited to cron.allow / at.allow"
}

sec_sshd() {
  write_file /etc/ssh/sshd_config.d/40-cis.conf 0600 <<'EOF'
# Loaded before Fedora's 50-redhat.conf, so these values win.
PermitRootLogin no
PermitEmptyPasswords no
HostbasedAuthentication no
IgnoreRhosts yes
PermitUserEnvironment no
GSSAPIAuthentication no
DisableForwarding yes
LogLevel VERBOSE
MaxAuthTries 4
MaxSessions 10
MaxStartups 10:30:60
LoginGraceTime 60
ClientAliveInterval 15
ClientAliveCountMax 3
EOF
  if command -v sshd >/dev/null && compgen -G '/etc/ssh/ssh_host_*_key' >/dev/null; then
    if ! sshd -t; then
      rm -f /etc/ssh/sshd_config.d/40-cis.conf
      warn "sshd -t failed — removed 40-cis.conf"
    fi
  fi
  # Only the SSH *server* is affected; the ssh client (outgoing connections) is untouched.
  if [[ $SSH_SERVER == off ]]; then
    mask_units sshd.socket sshd.service
  else
    log "SSH server left available (hardened config applied)"
  fi
}

sec_auditd() {
  local f=/etc/audit/auditd.conf
  backup "$f"
  set_kv "$f" disk_error_action SYSLOG
  set_kv "$f" space_left_action SYSLOG
  set_kv "$f" admin_space_left_action SUSPEND
  set_kv "$f" disk_full_action SUSPEND
  # ROTATE, not CIS KEEP_LOGS: KEEP_LOGS has no limit and /var also holds /var/home.
  # Ring 40 x 32 MiB = 1280 MiB: >= 1 week of records at the worst rate estimated
  # 2026-10-20 (sectop polling as root every 6 s). DISA STIG RHEL 9 V-258155.
  set_kv "$f" max_log_file_action ROTATE
  set_kv "$f" max_log_file 32
  set_kv "$f" num_logs 40
  chmod 0640 "$f"
  if auditctl --signal reload >/dev/null 2>&1; then log "auditd configuration reloaded"; else warn "reload auditd manually or reboot"; fi
}

sec_audit_rules() {
  local d=/etc/audit/rules.d n
  # The earlier 50-watch.rules used b64-only rules, which miss 32-bit programs (Steam).
  if [[ -e $d/50-watch.rules ]]; then backup "$d/50-watch.rules"; rm -f "$d/50-watch.rules"; log "removed old 50-watch.rules (backed up)"; fi

  write_file "$d/01-continue.rules" 0640 <<'EOF'
## Keep loading the remaining rules if one fails (e.g. a path that does not exist yet)
-c
EOF

  write_file "$d/50-cis-workstation.rules" 0640 <<'EOF'
## =====================================================================
## CIS L2 workstation audit rules — file watches (-w) cover 32-bit and
## 64-bit programs; syscall rules list both arches explicitly.
## =====================================================================

## ---- Time changes (chronyd excluded: it adjusts the clock all the time) ----
-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -F subj_type!=chronyd_t -k time-change
-a always,exit -F arch=b32 -S adjtimex,settimeofday,clock_settime -F subj_type!=chronyd_t -k time-change
-w /etc/localtime -p wa -k time-change

## ---- Hostname and network environment ----
-a always,exit -F arch=b64 -S sethostname,setdomainname -k system-locale
-a always,exit -F arch=b32 -S sethostname,setdomainname -k system-locale
-w /etc/issue -p wa -k system-locale
-w /etc/issue.net -p wa -k system-locale
-w /etc/hosts -p wa -k system-locale
-w /etc/hostname -p wa -k system-locale
-w /etc/NetworkManager -p wa -k system-locale

## ---- SELinux policy ----
-w /etc/selinux -p wa -k MAC-policy
-w /usr/share/selinux -p wa -k MAC-policy
-w /var/lib/selinux -p wa -k MAC-policy

## ---- Users, groups, authentication ----
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity
-w /etc/nsswitch.conf -p wa -k identity
-w /etc/pam.conf -p wa -k identity
-w /etc/pam.d -p wa -k identity

## ---- sudo ----
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d -p wa -k scope
-w /var/log/sudo.log -p wa -k sudo_log_file

## ---- Logins and sessions ----
-w /var/run/faillock -p wa -k logins
-w /var/log/lastlog -p wa -k logins
-w /var/lib/lastlog -p wa -k logins
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session

## ---- Programs run with another user's privileges (setuid) ----
-a always,exit -F arch=b64 -C euid!=uid -F auid!=unset -S execve -k user_emulation
-a always,exit -F arch=b32 -C euid!=uid -F auid!=unset -S execve -k user_emulation

## ---- Commands you run as root through sudo ----
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k root_cmds
-a always,exit -F arch=b32 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k root_cmds

## ---- Permission / account tools ----
-a always,exit -F path=/usr/bin/chcon -F perm=x -F auid>=1000 -F auid!=unset -k perm_chng
-a always,exit -F path=/usr/bin/setfacl -F perm=x -F auid>=1000 -F auid!=unset -k perm_chng
-a always,exit -F path=/usr/bin/chacl -F perm=x -F auid>=1000 -F auid!=unset -k perm_chng
-a always,exit -F path=/usr/bin/usermod -F perm=x -F auid>=1000 -F auid!=unset -k usermod

## ---- Kernel modules (every load, including by system daemons) ----
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k kernel_modules
-a always,exit -F arch=b32 -S init_module,finit_module,delete_module -k kernel_modules
-a always,exit -F path=/usr/bin/kmod -F perm=x -F auid>=1000 -F auid!=unset -k kernel_modules

## ---- Mounts by real users (copying to media) ----
## Flatpak (bubblewrap) and rootless podman mount on every app/container start,
## so expect a burst of events per launch.
-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=unset -k mounts
-a always,exit -F arch=b32 -S mount -F auid>=1000 -F auid!=unset -k mounts
EOF

  {
    echo "## setuid/setgid programs under /usr — regenerate after major upgrades"
    find /usr -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | sort |
      awk '{print "-a always,exit -F path=" $0 " -F perm=x -F auid>=1000 -F auid!=unset -k privileged"}'
  } | write_file "$d/55-privileged.rules" 0640

  if [[ $ENABLE_NOISY_AUDIT == yes ]]; then
    write_file "$d/60-cis-noisy.rules" 0640 <<'EOF'
## Permission changes
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat,fchmodat2 -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b32 -S chmod,fchmod,fchmodat,fchmodat2 -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b64 -S chown,fchown,lchown,fchownat -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b32 -S chown,fchown,lchown,fchownat -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b64 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b32 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=unset -k perm_mod
## File deletion / rename
-a always,exit -F arch=b64 -S rename,unlink,unlinkat,renameat,renameat2 -F auid>=1000 -F auid!=unset -k delete
-a always,exit -F arch=b32 -S rename,unlink,unlinkat,renameat,renameat2 -F auid>=1000 -F auid!=unset -k delete
## Denied file access
-a always,exit -F arch=b64 -S creat,open,openat,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=unset -k access
-a always,exit -F arch=b64 -S creat,open,openat,truncate,ftruncate -F exit=-EPERM -F auid>=1000 -F auid!=unset -k access
-a always,exit -F arch=b32 -S creat,open,openat,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=unset -k access
-a always,exit -F arch=b32 -S creat,open,openat,truncate,ftruncate -F exit=-EPERM -F auid>=1000 -F auid!=unset -k access
EOF
  fi

  if [[ $MAKE_AUDIT_IMMUTABLE == yes ]]; then
    printf '## Lock audit rules until reboot\n-e 2\n' | write_file "$d/99-finalize.rules" 0640
  fi

  chmod 0640 "$d"/*.rules
  if ! augenrules --load >/dev/null; then
    warn "augenrules reported an error — run: sudo augenrules --load"
  fi
  n=$(auditctl -l | grep -vc '^No rules' || true)
  log "audit rules loaded in kernel: $n"
  if (( n < 40 )); then warn "fewer rules than expected — check the files in $d"; fi
}

sec_perms() {
  local home f
  chmod 0640 /etc/audit/auditd.conf /etc/audit/audit.rules /etc/audit/rules.d/*.rules 2>/dev/null || true
  log "audit config files -> 0640"

  for f in /boot/grub2/grub.cfg /boot/grub2/user.cfg; do
    if [[ -f $f ]]; then chmod 0600 "$f"; log "$f -> 0600"; fi
  done

  if [[ -n $TARGET_USER ]]; then
    home=$(user_home "$TARGET_USER")
    for f in .bashrc .bash_profile .bash_logout .profile .zshrc .zprofile; do
      if [[ -f $home/$f ]]; then chmod g-wx,o-rwx "$home/$f"; fi
    done
    log "shell init files in $home -> 0740 or stricter"
  fi
}

sec_mic() {
  local conf=/etc/wireplumber/wireplumber.conf.d/90-disable-mic.conf alsa_match
  case $MIC_DISABLE in
    internal) alsa_match='~alsa_input.pci-.*' ;;
    all)      alsa_match='~alsa_input.*' ;;
    *) log "microphones left enabled (MIC_DISABLE=$MIC_DISABLE)"; return 0 ;;
  esac
  {
    cat <<EOF
## Disable microphone capture in PipeWire/WirePlumber; speakers and headphones keep working.
## Undo: delete this file, then run (as your user):  systemctl --user restart wireplumber
monitor.alsa.rules = [
  {
    matches = [ { node.name = "${alsa_match}" } ]
    actions = { update-props = { node.disabled = true } }
  }
]
EOF
    if [[ $MIC_DISABLE == all ]]; then
      cat <<'EOF'
monitor.bluez.rules = [
  {
    matches = [ { node.name = "~bluez_input.*" } ]
    actions = { update-props = { node.disabled = true } }
  }
]
EOF
    fi
  } | write_file "$conf" 0644

  if [[ -n $TARGET_USER ]] && systemctl --user -M "${TARGET_USER}@" restart wireplumber >/dev/null 2>&1; then
    log "WirePlumber restarted for $TARGET_USER"
  else
    warn "restart WirePlumber yourself (not with sudo): systemctl --user restart wireplumber"
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  echo "Sections: ${SECTIONS[*]}"
}

main() {
  local s
  local -a list
  if [[ $# -eq 0 || ${1:-} == --list || ${1:-} == -h ]]; then usage; exit 0; fi
  [[ $EUID -eq 0 ]] || die "run with sudo"
  if [[ -z $TARGET_USER ]]; then warn "SUDO_USER is empty — user-specific steps will be skipped"; fi

  list=("$@")
  if [[ ${list[0]} == all ]]; then list=("${SECTIONS[@]}"); fi
  mkdir -p "$BACKUP_ROOT"

  for s in "${list[@]}"; do
    printf '\n\e[1m== %s ==\e[0m\n' "$s"
    case $s in
      sysctl)      sec_sysctl ;;
      modules)     sec_modules ;;
      coredump)    sec_coredump ;;
      journald)    sec_journald ;;
      gnome)       sec_gnome ;;
      sudo)        sec_sudo ;;
      pam)         sec_pam ;;
      su)          sec_su ;;
      services)    sec_services ;;
      cron)        sec_cron ;;
      sshd)        sec_sshd ;;
      auditd)      sec_auditd ;;
      audit-rules) sec_audit_rules ;;
      perms)       sec_perms ;;
      mic)         sec_mic ;;
      *)           warn "unknown section: $s" ;;
    esac
  done

  printf '\nBackups: %s\nReboot recommended (kernel modules, sysctl one-way switches, PAM).\n' "$BACKUP_ROOT"
}

main "$@"
