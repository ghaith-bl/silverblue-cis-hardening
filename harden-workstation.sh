#!/usr/bin/env bash
# =============================================================================
# harden-workstation.sh
# CIS Fedora Benchmark L2 (Workstation) - tailored for:
#   Fedora Silverblue 44, KVM/libvirt, Steam (Flatpak), Mullvad VPN (WireGuard)
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
#   - rp_filter = 1 (strict)    -> can drop WireGuard VPN traffic (using 2)
#   - forced password expiry    -> NIST SP 800-63B advises against it
#   - auditd HALT               -> a full disk would halt the laptop
#   - auditd KEEP_LOGS          -> no limit, /var also holds /var/home (ROTATE, 40 x 32 MiB)
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Decisions - review before running
# -----------------------------------------------------------------------------
DISABLE_USB_STORAGE="no"     # "yes" = USB flash drives / external disks stop working
DISABLE_BLUETOOTH="no"       # "yes" = no Bluetooth headsets / game controllers
DISABLE_AVAHI="yes"          # "no"  if you use network printers or mDNS discovery
ENABLE_NOISY_AUDIT="no"      # "yes" = log every chmod/chown/delete/denied-open by users (very noisy with Steam/Brave)
MAKE_AUDIT_IMMUTABLE="yes"   # "yes" = audit rules locked until reboot (-e 2): a rule change needs a reboot
SSH_SERVER="off"             # "on" = keep sshd usable (hardened) so other machines can SSH INTO this laptop.
                             # Outgoing ssh from this laptop to VMs / homelab works either way.
FINGERPRINT="disable"        # "keep" if you use a fingerprint reader ("disable" avoids fast faillock lockouts)
MIC_DISABLE="internal"       # "internal" = laptop mic + 3.5mm jack mic off (USB/Bluetooth mics still work)
                             # "all" = every mic off | "no" = leave microphones alone
IDLE_LOCK_SECONDS=900        # screen locks after 15 minutes idle
MAC_MODE="random"            # "random" = new MAC on every connect (Wi-Fi + cable)
                             # "stable-ssid" = same random MAC per Wi-Fi network (Fedora default)
GENERIC_HOSTNAME="localhost" # hostname every network may see; "" = keep the current one
KERNEL_ARGS=(initcall_blacklist=af_alg_init page_alloc.shuffle=1 rd.shell=0 rd.emergency=halt)
                             # kargs section; () = add none
MULLVAD_SOCKET_GROUP="mullvad"  # mullvad section: only this group may use the Mullvad CLI / GUI
                             # "" = any local user (Mullvad's default)
MULLVAD_VM_BRIDGES=(virbr0)  # kvmlan section: libvirt bridges outside Mullvad's LAN block (Allow LAN
                             # stays off; same names as if_vm in firewall/hostfw.nft); () = none
USBGUARD_BLOCK_BLUETOOTH="yes" # usbguard section: USB Bluetooth adapters blocked in the rules
                             # generated from the devices present ("no" = allowed like the rest)
APP_UNITS=(brave-browser)    # appunit section: desktop ids started as their own service (launcher
                             # forks before GNOME moves it: Chromium family); () = none
ADMIN_USER="${ADMIN_USER:-}" # accounts section: CLI-only admin (wheel, text console, hidden
                             # from GDM); "" = one account, the section does nothing
DAILY_USER="${DAILY_USER:-}" # accounts section: GNOME daily user, no sudo. Also the user of
                             # the desktop steps (cron.allow, shell rc files, mic, appunit)
                             # Names stay out of git: sudo ADMIN_USER=<a> DAILY_USER=<d> ./...
                             # (sudoers (ALL) ALL implies SETENV)
# desktop steps act on the daily user when it exists; one account: the sudo user
if [[ -n $DAILY_USER ]] && id "$DAILY_USER" >/dev/null 2>&1; then
  TARGET_USER=$DAILY_USER
else
  TARGET_USER="${SUDO_USER:-}"
fi

BACKUP_ROOT="/var/backups/hardening/$(date +%Y%m%d-%H%M%S)"
SECTIONS=(sysctl modules coredump journald gnome sudo pam su accounts services cron sshd auditd audit-rules perms mic netprivacy mullvad kvmlan usbguard appunit time kargs)

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

unit_exists() { systemctl list-unit-files --no-legend "$1" 2>/dev/null | grep . >/dev/null; }
# no 'cmd | grep -q' under pipefail: grep -q quits at the first match, the writer can get
# SIGPIPE and the pipe fails although the line was there (docs/lessons-learned.md)
in_group() { [[ " $(id -nG "$1" 2>/dev/null) " == *" $2 "* ]]; }

mask_units() {
  local u
  for u in "$@"; do
    if unit_exists "$u"; then
      if systemctl mask --now "$u" >/dev/null 2>&1; then log "masked $u"; else warn "could not mask $u"; fi
    fi
  done
}

user_home() { getent passwd "$1" | cut -d: -f6; }

# add_karg <arg>...   rpm-ostree: one new deployment for all missing args, used from the
# next boot; the deployment booted now stays in GRUB (rollback)
add_karg() {
  local karg have
  local -a missing=()
  if ! command -v rpm-ostree >/dev/null; then
    warn "no rpm-ostree: add kernel args yourself: $*"; return 0
  fi
  have=" $(rpm-ostree kargs) "
  for karg in "$@"; do
    if [[ $have == *" $karg "* ]]; then log "kernel arg $karg already set"
    else missing+=("--append=$karg"); fi
  done
  (( ${#missing[@]} )) || return 0
  if rpm-ostree kargs "${missing[@]}" >/dev/null; then
    log "kernel args added (used from the next boot): ${missing[*]#--append=}"
  else
    warn "rpm-ostree kargs ${missing[*]} failed"
  fi
}

# -----------------------------------------------------------------------------
# Sections
# -----------------------------------------------------------------------------
sec_sysctl() {
  write_file /etc/sysctl.d/90-hardening.conf 0644 <<'EOF'
# ---- Kernel ----
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
# 2 = admin-only attach: only CAP_SYS_PTRACE may trace (gdb / strace need sudo).
# CIS RHEL 9 v3.0.0 accepts 1, 2 or 3 and recommends 2; RHEL 9 STIG wants 1.
# 3 cannot be lowered until reboot.
kernel.yama.ptrace_scope = 2
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
# 2 = loose mode. CIS asks for 1 (strict), which can drop WireGuard (VPN) traffic.
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
  if sysctl --system >/dev/null; then log "sysctl applied"; else warn "some sysctl keys failed - run: sudo sysctl --system"; fi
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
    warn "gdm dconf profile not found - skipped hiding the login user list"
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
      die "full sudoers check failed - removed /etc/sudoers.d/90-cis"
    fi
  else
    warn "sudoers snippet failed validation - not installed"
  fi
  rm -f "$tmp"
}

sec_pam() {
  local profile feat
  if ! authselect check >/dev/null 2>&1; then
    warn "authselect reports manual PAM edits - skipping PAM section"
    return 0
  fi
  profile=$(authselect current --raw | awk '{print $1}')
  if authselect current --raw | grep -w with-fingerprint >/dev/null; then
    if [[ $FINGERPRINT == disable ]]; then
      authselect disable-feature with-fingerprint >/dev/null && log "authselect: disabled with-fingerprint"
    else
      warn "with-fingerprint is enabled: failed fingerprint reads can count toward faillock lockouts"
    fi
  fi
  for feat in with-faillock with-pwhistory without-nullok; do
    if authselect list-features "$profile" | grep -x "$feat" >/dev/null; then
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
    warn "group sugroup has members - su rule not added"
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
    warn "pam_rootok line not found in /etc/pam.d/su - nothing changed"
  fi
}

## Not CIS as a rule, CIS Controls v8 5.4 / NIST SP 800-53 AC-6(2) / NSA-CISA AA23-278A #2:
## admin work from an account used for nothing else. ADMIN_USER: wheel, text console only
## (hidden from GDM, GDM login refused). DAILY_USER: GNOME, browsers, no sudo.
## Run 1 (any sudo user): admin account + GDM + homes. Its password is set by hand on a
## text console. Run 2 from the admin itself (its sudo is the proof it works): the daily
## user leaves wheel, the Mullvad group and sectop's reader group. Never the other way: root is locked, a daily
## user out of wheel before the admin's sudo works = no sudo left.
sec_accounts() {
  local a=$ADMIN_USER d=$DAILY_USER as f pam=/etc/pam.d/gdm-password g
  local line="auth       requisite   pam_succeed_if.so user != ${ADMIN_USER} quiet_success"
  if [[ -z $a || -z $d ]]; then log "ADMIN_USER / DAILY_USER empty: one account, nothing to do"; return 0; fi
  for f in "$a" "$d"; do
    [[ $f =~ ^[a-z_][a-z0-9_-]{0,31}$ && $f != root ]] || { warn "bad user name '$f' - skipped"; return 0; }
  done
  [[ $a != "$d" ]] || { warn "ADMIN_USER = DAILY_USER - skipped"; return 0; }
  id "$d" >/dev/null 2>&1 || { warn "no daily user $d - skipped"; return 0; }

  # --- admin account: wheel, own group, bash
  if id "$a" >/dev/null 2>&1; then
    in_group "$a" wheel || { usermod -aG wheel "$a"; log "$a added to wheel"; }
    log "admin $a: $(id "$a")"
  else
    useradd -m -U -G wheel -s /bin/bash -c "admin (text console)" "$a"
    log "admin $a created (wheel, password locked until set)"
  fi
  as=$(passwd -S "$a" 2>/dev/null | awk '{print $2}')
  if [[ $as != P && $as != PS ]]; then
    warn "$a has no password: on a text console (Ctrl+Alt+F3), as $d: sudo passwd $a"
    warn "  never type the admin password inside the GNOME session"
  fi

  # --- GDM: not listed, login refused (text console only)
  f=/var/lib/AccountsService/users/$a
  if [[ -f $f ]] && grep -qx 'SystemAccount=true' "$f"; then
    log "$f: SystemAccount=true"
  elif [[ -f $f ]]; then
    backup "$f"
    if grep -qx '\[User\]' "$f"; then sed -i '/^\[User\]$/a SystemAccount=true' "$f"
    else printf '[User]\nSystemAccount=true\n' >> "$f"; fi
    chmod 0600 "$f"; restorecon -F "$f" 2>/dev/null || true
    log "$f: SystemAccount=true added (GDM list: after a reboot)"
  else
    printf '[User]\nSystemAccount=true\n' | write_file "$f" 0600
    log "GDM list: $a hidden after a reboot"
  fi
  if grep -qE "^auth[[:space:]]+requisite[[:space:]]+pam_succeed_if\.so[[:space:]]+user[[:space:]]+!=[[:space:]]+$a([[:space:]]|$)" "$pam" 2>/dev/null; then
    log "$pam: $a refused"
  elif [[ -f $pam ]]; then
    backup "$pam"
    sed -i "1i $line" "$pam"
    restorecon -F "$pam" 2>/dev/null || true
    log "$pam: line 1 refuses $a (GDM password login)"
  else
    warn "$pam missing (no GDM?) - GDM line skipped"
  fi

  # --- homes: owner only
  for f in "$a" "$d"; do
    chmod 0700 "$(user_home "$f")" && log "home of $f -> 0700"
  done
  [[ $(passwd -S root 2>/dev/null | awk '{print $2}') == L* ]] || warn "root password not locked"

  # --- run 2: only from the admin (sudo from it works = safe to take the daily user's)
  if [[ ${SUDO_USER:-} == "$a" && $as != P && $as != PS ]]; then
    warn "run 2 needs the admin's password set first: daily user keeps wheel"; return 0
  fi
  if [[ ${SUDO_USER:-} != "$a" ]]; then
    log "next: log in as $a on a text console (Ctrl+Alt+F3), sudo -v, then there:"
    log "  sudo ADMIN_USER=$a DAILY_USER=$d ./harden-workstation.sh accounts"
    log "  (takes wheel, ${MULLVAD_SOCKET_GROUP:-the Mullvad group} and sectop from $d)"
    return 0
  fi
  for g in wheel ${MULLVAD_SOCKET_GROUP:+"$MULLVAD_SOCKET_GROUP"}; do
    getent group "$g" >/dev/null || continue
    if [[ $g != wheel ]] && ! in_group "$a" "$g"; then
      usermod -aG "$g" "$a"; log "$a added to $g"
    fi
    if in_group "$d" "$g"; then
      gpasswd -d "$d" "$g" >/dev/null; log "$d removed from $g"
    fi
  done
  # sectop's reader group: the daily user runs only the user helper (install.sh warns,
  # sysusers never removes a member). Found 2026-11-06: still a member after the split
  if getent group sectop >/dev/null && in_group "$d" sectop; then
    gpasswd -d "$d" sectop >/dev/null; log "$d removed from sectop"
  fi
  log "$d: log out (or reboot): running processes keep the old groups"
  log "sectop: from $a: sudo ./install.sh --desktop-user $d"
  log "check: sudo tools/check-accounts.sh $a $d   (0 FAIL)"
}

sec_services() {
  mask_units rpcbind.socket rpcbind.service nfs-server.service
  if [[ $DISABLE_AVAHI == yes ]]; then mask_units avahi-daemon.socket avahi-daemon.service; fi
  if [[ $DISABLE_BLUETOOTH == yes ]]; then mask_units bluetooth.service; fi
  # nftables.service must NOT be stopped live: its stop action flushes the whole
  # ruleset (firewalld, hostfw, Mullvad kill switch). Disable + mask only.
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
      warn "sshd -t failed - removed 40-cis.conf"
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
## CIS L2 workstation audit rules - file watches (-w) cover 32-bit and
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
    echo "## setuid/setgid programs under /usr - regenerate after major upgrades"
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

  # -e 2 (DISA STIG RHEL 9 V-258229): no rule change and no `auditctl -e 0` until
  # reboot, root included. augenrules puts -e last, after every other file.
  if [[ $MAKE_AUDIT_IMMUTABLE == yes ]]; then
    printf '## Lock audit rules until reboot\n-e 2\n' | write_file "$d/99-finalize.rules" 0640
  elif [[ -e $d/99-finalize.rules ]]; then
    backup "$d/99-finalize.rules"; rm -f "$d/99-finalize.rules"; log "removed 99-finalize.rules (unlocked from the next boot)"
  fi

  # Not CIS (my design, 2026-11-01): who opens an AF_ALG socket (family 38). Measured
  # before the kargs section blocked it; after it, every try fails (EAFNOSUPPORT).
  write_file "$d/70-af-alg.rules" 0640 <<'EOF'
## AF_ALG sockets (kernel crypto API from user space), not CIS.
## With kernel arg initcall_blacklist=af_alg_init (kargs section) every try fails:
## a program that needs it, or a probe. 32-bit programs that call socketcall
## (old i386 glibc) are not matched by family; the kernel arg blocks them anyway.
-a always,exit -F arch=b64 -S socket -F a0=38 -k af-alg
-a always,exit -F arch=b32 -S socket -F a0=38 -k af-alg
EOF

  chmod 0640 "$d"/*.rules
  if [[ $(auditctl -s | awk '$1 == "enabled" {print $2}') == 2 ]]; then
    # Locked: the kernel refuses every change. Write audit.rules, load it at boot.
    if ! augenrules >/dev/null; then warn "augenrules reported an error - check the files in $d"; fi
    log "audit rules are locked (-e 2): the new rules load at the next reboot"
    return 0
  fi
  if ! augenrules --load >/dev/null; then
    warn "augenrules reported an error - run: sudo augenrules --load"
  fi
  n=$(auditctl -l | grep -vc '^No rules' || true)
  log "audit rules loaded in kernel: $n"
  if (( n < 40 )); then warn "fewer rules than expected - check the files in $d"; fi
  if [[ $MAKE_AUDIT_IMMUTABLE == yes ]]; then log "audit rules locked now (-e 2): next change needs a reboot"; fi
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

# Not CIS: what a network I join can learn about this laptop. No real MAC, no hostname.
sec_netprivacy() {
  local ethmac
  case $MAC_MODE in
    random)      ethmac=random ;;
    stable-ssid) ethmac=stable ;;
    *) die "MAC_MODE must be random or stable-ssid" ;;
  esac
  write_file /etc/NetworkManager/conf.d/90-privacy.conf 0644 <<EOF
# Defaults for profiles that leave these properties unset (NetworkManager.conf(5)).
# dhcp-send-hostname here is not used by NetworkManager 1.56.1 (tested 2026-10-27):
# set per profile below, plus a generic hostname for profiles made later.
# Read after Fedora's /usr/lib/NetworkManager/conf.d/22-wifi-mac-addr.conf
# (wifi.cloned-mac-address=stable-ssid): later files win.
[device.90-privacy]
wifi.scan-rand-mac-address=yes

[connection.90-privacy]
# MAC: never the real one (random = new one on every connect)
wifi.cloned-mac-address=${MAC_MODE}
ethernet.cloned-mac-address=${ethmac}
# DHCP: no hostname, ids from the current (cloned) MAC, not machine-id
ipv4.dhcp-send-hostname=false
ipv6.dhcp-send-hostname=false
ipv4.dhcp-client-id=mac
ipv6.dhcp-duid=ll
ipv6.ip6-privacy=2
EOF
  # LLMNR / mDNS answer and announce the hostname on the LAN (avahi: services section)
  write_file /etc/systemd/resolved.conf.d/90-privacy.conf 0644 <<'EOF'
[Resolve]
LLMNR=no
MulticastDNS=no
EOF
  if systemctl reload NetworkManager; then log "NetworkManager config reloaded"; else warn "reload NetworkManager failed - reboot"; fi
  # existing Wi-Fi / cable profiles, written in the profile:
  # - no hostname in DHCP
  # - no DNS servers (static or from DHCP): only the tunnel has one. With a server on the
  #   uplink, resolved falls back to it while the tunnel has none (connect / reconnect)
  #   and queries go out unencrypted (seen 2026-10-31, blocked by hostfw out_dns).
  #   ignore-auto-dns has no global default in NetworkManager.conf(5): per profile only.
  backup /etc/NetworkManager/system-connections
  local uuid type n=0
  while IFS=: read -r uuid type; do
    case $type in 802-11-wireless|802-3-ethernet) ;; *) continue ;; esac
    if nmcli connection modify "$uuid" ipv4.dhcp-send-hostname no ipv6.dhcp-send-hostname no \
         ipv4.dns "" ipv4.ignore-auto-dns yes ipv6.dns "" ipv6.ignore-auto-dns yes; then
      n=$((n + 1))
    else
      warn "profile $uuid: not changed"
    fi
  done < <(nmcli -g UUID,TYPE connection show)
  log "no hostname in DHCP, no DNS servers on $n Wi-Fi / cable profiles"
  # live connections: reapply (no reconnect, same MAC and lease)
  local dev state
  while IFS=: read -r dev type state; do
    case $type in wifi|ethernet) ;; *) continue ;; esac
    [[ $state == connected ]] || continue
    if nmcli device reapply "$dev" >/dev/null; then log "reapplied $dev"; else warn "reapply $dev failed - reconnect it"; fi
  done < <(nmcli -g DEVICE,TYPE,STATE device)
  log "a network joined later gets DHCP DNS again: run netprivacy after joining it"
  # profiles made later (a new network) send the hostname on their first connect
  if [[ -n $GENERIC_HOSTNAME ]]; then
    hostnamectl set-hostname --static "$GENERIC_HOSTNAME"
    hostnamectl set-hostname --pretty ""     # pretty name = Bluetooth / GNOME device name
    # static "localhost" counts as unset: hostnamed then shows the distro fallback
    # ("fedora") as transient hostname. Same name as fallback (systemd.io ENVIRONMENT).
    write_file /etc/systemd/system/systemd-hostnamed.service.d/90-privacy.conf 0644 <<EOF
[Service]
Environment=SYSTEMD_DEFAULT_HOSTNAME=${GENERIC_HOSTNAME}
EOF
    systemctl daemon-reload
    systemctl try-restart systemd-hostnamed.service || true
    # The initramfs comes with the image (no /etc/hostname in it): its systemd set the
    # fallback "fedora" for the first ~12 s of boot. The kernel hands KEY=value args it
    # does not know to PID 1 as environment, in the initramfs too (tested 2026-10-27).
    add_karg "SYSTEMD_DEFAULT_HOSTNAME=${GENERIC_HOSTNAME}"
    log "hostname: $GENERIC_HOSTNAME (log out and in: X11 apps keep the old name in Xauthority)"
  fi
  # reload, not restart: a restart drops the DNS servers Mullvad set on its link
  if systemctl reload systemd-resolved; then log "resolved config reloaded"; else warn "reload systemd-resolved failed - reboot"; fi
  log "new MAC on the next connect: reconnect Wi-Fi / cable, or reboot"
}

# CIS: chrony with configured servers. Beyond CIS: authenticated time only (NTS, RFC 8915).
# Plain NTP can be changed on the way (certificates, log times); a pool or DHCP servers let
# the network pick my clock. Two national time labs, both NTS, free, no sign-up:
#   Netnod (SE) https://www.netnod.se/netnod-time/how-to-use-nts
#   PTB (DE)    https://www.ptb.de -> Time synchronization ... NTP (ptbtime4: other site)
# NTS-KE tcp 4460, then NTP (Netnod: udp 4123): both via the tunnel (hostfw out_new).
# DNS only via the tunnel (netprivacy): no time sync without Mullvad, the RTC keeps time.
## Not CIS. Mullvad management socket (/var/run/mullvad-vpn): any local user can
## connect, disconnect and change settings by default. MULLVAD_MANAGEMENT_SOCKET_GROUP
## limits it to one group (mullvadvpn-app README, environment variables).
sec_mullvad() {
  local dropin=/etc/systemd/system/mullvad-daemon.service.d/50-socket-group.conf
  local line="Environment=\"MULLVAD_MANAGEMENT_SOCKET_GROUP=${MULLVAD_SOCKET_GROUP}\""
  if [[ -z $MULLVAD_SOCKET_GROUP ]]; then
    log "MULLVAD_SOCKET_GROUP empty: any local user may use the Mullvad daemon"; return 0
  fi
  if ! unit_exists mullvad-daemon.service; then
    warn "mullvad-daemon.service not found - skipped"; return 0
  fi
  groupadd -r -f "$MULLVAD_SOCKET_GROUP"
  # socket = full daemon control: the admin when there is one (accounts section)
  local who=${ADMIN_USER:-$TARGET_USER}
  if [[ -n $ADMIN_USER ]] && ! id "$ADMIN_USER" >/dev/null 2>&1; then
    warn "no admin $ADMIN_USER yet (accounts section): group left as it is"; who=""
  fi
  if [[ -z $who ]]; then
    warn "no user: add the admin yourself: usermod -aG $MULLVAD_SOCKET_GROUP <user>"
  elif in_group "$who" "$MULLVAD_SOCKET_GROUP"; then
    log "$who already in $MULLVAD_SOCKET_GROUP"
  else
    usermod -aG "$MULLVAD_SOCKET_GROUP" "$who"
    log "$who added to $MULLVAD_SOCKET_GROUP (log out and in, then mullvad works again)"
  fi
  if [[ -f $dropin ]] && grep -qxF "$line" "$dropin"; then
    log "$dropin already set"; return 0
  fi
  write_file "$dropin" 0644 <<EOF
## harden-workstation.sh mullvad: only group ${MULLVAD_SOCKET_GROUP} may use the
## management socket (mullvad CLI / GUI). Default without it: any local user.
[Service]
${line}
EOF
  systemctl daemon-reload
  # package unit: RestartKillSignal=SIGUSR1 = the daemon blocks all traffic before it
  # stops; auto-connect reconnects after the start
  if systemctl restart mullvad-daemon.service; then log "mullvad-daemon restarted"
  else warn "mullvad-daemon restart failed: systemctl status mullvad-daemon"; fi
}

## Not CIS. Mullvad with Allow LAN off also blocks the libvirt bridge: no DHCP lease in the
## VMs, host -> VM ssh refused (host 2026-11-04, Mullvad 2026.5, lockdown on). Allow LAN
## would open every private range on every network. Instead Mullvad's documented marks
## (ct mark 0xf41 + mark 0x6d6f6c65, "Split tunneling with Linux (advanced)") on host <-> VM
## packets of MULLVAD_VM_BRIDGES only, own table inet kvmlan: marks only, no accept / drop,
## Mullvad's own table not touched. Mark chains between -200 and 0 (Mullvad: lower leaks the
## tunnel address); here -100. VM internet is forwarded traffic, never marked: tunnel only.
## firewalld zone libvirt still decides what a VM may reach on the host.
sec_kvmlan() {
  local nft=/etc/kvmlan.nft unit=/etc/systemd/system/kvmlan.service
  local br list="" rules unit_text lan
  if (( ${#MULLVAD_VM_BRIDGES[@]} == 0 )); then
    log "MULLVAD_VM_BRIDGES empty: nothing to do (remove: README Rollback)"; return 0
  fi
  if ! unit_exists mullvad-daemon.service; then
    warn "mullvad-daemon.service not found - skipped"; return 0
  fi
  for br in "${MULLVAD_VM_BRIDGES[@]}"; do
    [[ $br =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || { warn "invalid bridge name '$br' - skipped"; return 0; }
    list+="${list:+, }\"$br\""
  done
  rules=$(cat <<EOF
#!/usr/sbin/nft -f
# harden-workstation.sh kvmlan: libvirt bridges outside Mullvad's LAN block.
# Marks only (no accept / drop): Mullvad's chains (priority 0) pass marked packets.
# https://mullvad.net/help/split-tunneling-with-linux-advanced
table inet kvmlan
delete table inet kvmlan

table inet kvmlan {
	chain kvm_in {
		type filter hook input priority -100; policy accept;
		iifname { $list } ct mark set 0x00000f41 meta mark set 0x6d6f6c65
	}
	chain kvm_out {
		type route hook output priority -100; policy accept;
		oifname { $list } ct mark set 0x00000f41 meta mark set 0x6d6f6c65
	}
}
EOF
)
  nft -c -f - <<<"$rules" || { warn "nft syntax check failed - nothing written"; return 0; }
  if [[ -f $nft ]] && [[ $(cat "$nft") == "$rules" ]]; then
    log "$nft up to date"
  else
    write_file "$nft" 0644 <<<"$rules"
  fi
  unit_text=$(cat <<'EOF'
[Unit]
Description=kvmlan - libvirt bridges outside Mullvad's LAN block (nftables table inet kvmlan)
Documentation=https://mullvad.net/help/split-tunneling-with-linux-advanced
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/kvmlan.nft
ExecReload=/usr/sbin/nft -f /etc/kvmlan.nft
ExecStop=/usr/sbin/nft delete table inet kvmlan

[Install]
WantedBy=multi-user.target
EOF
)
  if [[ -f $unit ]] && [[ $(cat "$unit") == "$unit_text" ]]; then
    log "$unit up to date"
  else
    write_file "$unit" 0644 <<<"$unit_text"
    systemctl daemon-reload
  fi
  systemctl enable kvmlan.service >/dev/null 2>&1 && log "kvmlan.service enabled"
  if systemctl reload-or-restart kvmlan.service; then log "table inet kvmlan loaded: ${MULLVAD_VM_BRIDGES[*]}"
  else warn "kvmlan.service failed: journalctl -u kvmlan"; fi
  lan=$(mullvad lan get 2>/dev/null || true)
  case $lan in
    *block*) log "Mullvad Allow LAN: off (only the bridges are open)" ;;
    *allow*) warn "Mullvad Allow LAN is on: whole LAN open, this table is not needed (mullvad lan set block)" ;;
    *)       warn "could not read: mullvad lan get" ;;
  esac
  log "test: in the VM nmcli device status (connected), curl https://am.i.mullvad.net/connected"
  log "VM without a lease: in the VM sudo nmcli connection up <profile>"
}

## Not CIS. USBGuard: only devices in rules.conf work, locked or not, before login too.
## A flash drive: sudo usb-allow-storage (installed here) allows ONE blocked device whose
## every interface is mass storage, until it is unplugged. GNOME usb-protection off (it
## allows every new device while unlocked); usbguard-dbus not needed (masked).
## Package layered by hand first (rpm-ostree install usbguard, reboot).
## Run 1 starts the daemon, NOT enabled (a reboot turns it off again): test, then run 2
## enables it. The internal keyboard of many laptops is a USB device.
sec_usbguard() {
  local rules=/etc/usbguard/rules.conf conf=/etc/usbguard/usbguard-daemon.conf
  local pk=/etc/polkit-1/rules.d/70-usbguard-gnome.rules tool=/usr/local/sbin/usb-allow-storage
  local src gen changed=0
  src="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/usbguard/usb-allow-storage.sh"
  if ! rpm -q usbguard >/dev/null 2>&1; then
    warn "usbguard not installed: rpm-ostree install usbguard, reboot, run again"
    return 0
  fi
  [[ -f $src ]] || { warn "$src missing: run the script from the repo"; return 0; }

  # rules: from the devices present now, only while the file has no rule (mine stays mine)
  if grep -Eq '^[[:space:]]*(allow|block|reject)[[:space:]]' "$rules" 2>/dev/null; then
    log "$rules has rules: kept"
  else
    gen="$(usbguard generate-policy)" || { warn "usbguard generate-policy failed"; return 0; }
    if [[ $USBGUARD_BLOCK_BLUETOOTH == yes ]]; then
      # only devices whose every interface is Bluetooth (e0:01:01)
      gen="$(sed -E '/ with-interface (e0:01:01|\{ (e0:01:01 )+\}) /s/^allow /block /' <<<"$gen")"
    fi
    grep -q ' 03:01:01' <<<"$gen" || warn "no USB keyboard in the rules (fine if the keyboard is not USB)"
    write_file "$rules" 0600 <<<"$gen"
    log "$(grep -c '^allow ' "$rules") allow / $(grep -c '^block ' "$rules") block rules from the devices present now"
    changed=1
  fi

  # IPC (usbguard CLI) for root only; Fedora default also lets wheel change rules without
  # a password
  if grep -qx 'IPCAllowedGroups=' "$conf"; then
    log "usbguard IPC: root only"
  else
    backup "$conf"
    sed -i -E 's/^IPCAllowedGroups=.*/IPCAllowedGroups=/' "$conf"
    grep -qx 'IPCAllowedGroups=' "$conf" || printf 'IPCAllowedGroups=\n' >> "$conf"
    restorecon -F "$conf" 2>/dev/null || true
    log "usbguard IPC: root only (usbguard CLI needs sudo)"
    changed=1
  fi

  # flash drives: a root owned copy, a root tool never runs from my home
  if cmp -s "$src" "$tool"; then
    log "$tool up to date"
  else
    backup "$tool"
    install -o root -g root -m 0755 "$src" "$tool"
    restorecon -F "$tool" 2>/dev/null || true
    log "installed $tool (flash drive: sudo usb-allow-storage)"
  fi

  # GNOME usb-protection off + locked (GNOME default is on)
  if [[ -e $pk ]]; then
    backup "$pk"
    rm -f "$pk"
    log "removed $pk"
  fi
  grep -qs 'system-db:local' /etc/dconf/profile/user || warn "no system-db:local in /etc/dconf/profile/user: run the gnome section first"
  write_file /etc/dconf/db/local.d/90-usbguard 0644 <<'EOF'
[org/gnome/desktop/privacy]
usb-protection=false
EOF
  write_file /etc/dconf/db/local.d/locks/90-usbguard 0644 <<'EOF'
/org/gnome/desktop/privacy/usb-protection
EOF
  dconf update && log "dconf updated"
  if rpm -q usbguard-dbus >/dev/null 2>&1; then
    systemctl disable --now usbguard-dbus.service >/dev/null 2>&1 || true
    systemctl mask usbguard-dbus.service >/dev/null 2>&1 && log "usbguard-dbus masked"
    warn "usbguard-dbus not needed: rpm-ostree uninstall usbguard-dbus, reboot"
  fi

  if systemctl is-enabled -q usbguard.service; then
    if (( changed )); then systemctl restart usbguard.service && log "usbguard restarted"; fi
    log "usbguard enabled"
  elif systemctl is-active -q usbguard.service; then
    if (( changed )); then
      systemctl restart usbguard.service
      warn "config changed: usbguard restarted, still NOT enabled - test again, then run again"
      return 0
    fi
    systemctl enable usbguard.service && log "usbguard enabled (from the next boot too)"
  else
    systemctl start usbguard.service
    log "usbguard started, NOT enabled (a reboot turns it off again)"
    log "test: keyboard + touchpad, a new device stays blocked, sudo usb-allow-storage; then run this section again"
  fi
}

sec_appunit() {
  local tool=/usr/local/bin/app-unit dir=/usr/local/share/applications
  local src id from to home
  src="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/appunit/app-unit.sh"
  [[ -f $src ]] || { warn "$src missing: run the script from the repo"; return 0; }
  if cmp -s "$src" "$tool"; then
    log "$tool up to date"
  else
    backup "$tool"
    install -o root -g root -m 0755 "$src" "$tool"
    restorecon -F "$tool" 2>/dev/null || true
    log "installed $tool"
  fi
  home=""
  [[ -n $TARGET_USER ]] && home=$(user_home "$TARGET_USER")
  for id in "${APP_UNITS[@]}"; do
    from=/usr/share/applications/$id.desktop
    to=$dir/$id.desktop
    if [[ ! -f $from ]]; then warn "$from missing: $id not installed, skipped"; continue; fi
    if grep -q '^DBusActivatable=true' "$from"; then
      warn "$id is D-Bus activated (Exec not used): skipped"; continue
    fi
    # same desktop id, earlier in XDG_DATA_DIRS: GNOME, default browser, MIME use this one
    { printf '# Generated by harden-workstation.sh (appunit) from %s.
' "$from"
      printf '# Run the section again after an update of %s.
' "$id"
      sed -E "s#^Exec=#Exec=$tool $id #" "$from"
    } | write_file "$to" 0644
    if [[ -n $home && -e $home/.local/share/applications/$id.desktop ]]; then
      warn "$home/.local/share/applications/$id.desktop wins over $to: remove it"
    fi
  done
  log "close the apps, then log out and in once: started from the menu they run in app-<id>@<pid>.service"
}

sec_time() {
  write_file /etc/chrony.conf 0644 <<'EOF'
# harden-workstation.sh time: NTS only, no pool, no servers from DHCP
server sth1.nts.netnod.se iburst nts
server sth2.nts.netnod.se iburst nts
server ptbtime1.ptb.de iburst nts
server ptbtime2.ptb.de iburst nts
server ptbtime4.ptb.de iburst nts

# only authenticated sources; at least 2 must agree before the clock is set
authselectmode require
minsources 2

driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
ntsdumpdir /var/lib/chrony
leapseclist /usr/share/zoneinfo/leap-seconds.list
logdir /var/log/chrony
EOF
  if systemctl restart chronyd; then log "chronyd restarted"; else warn "restart chronyd failed: journalctl -u chronyd"; fi
  log "check in a minute: chronyc -N authdata (Mode NTS, KE > 0), chronyc -n sources"
}

# Not CIS: kernel args (KERNEL_ARGS). Used from the next boot; the deployment before it
# stays in GRUB (rollback: pick it there, then sudo rpm-ostree rollback).
#   initcall_blacklist=af_alg_init: AF_ALG (kernel crypto API from user space) never
#   starts. Upstream deprecated it (attack surface); CVE-2026-31431 (Copy Fail) was in
#   algif_aead, part of it. The usual mitigation blocks algif_aead_init only;
#   af_alg_init blocks the whole family. Before: 2 days of audit (key af-alg), no
#   program used it; LUKS2 aes-xts-plain64 + argon2id unlocks without it (cryptsetup
#   >= 2.8.7 falls back to a userspace library). Test 2026-11-01: boot + unlock OK,
#   socket(AF_ALG) -> errno 97. Not for: Adiantum / Serpent / Twofish LUKS volumes,
#   BlueZ mesh, iwd.
#   page_alloc.shuffle=1: page allocator free lists in random order (built in with
#   CONFIG_SHUFFLE_PAGE_ALLOCATOR, off by default): harder to predict where an object
#   lands in memory. Check: /sys/module/page_alloc/parameters/shuffle = Y.
#   rd.shell=0 rd.emergency=halt: a failure in the initramfs halts the machine instead of
#   a root shell (dracut.cmdline(7); rd.emergency needs rd.shell=0). That shell may run
#   after the LUKS unlock. Only worth it with a GRUB password (grub2-setpassword, by
#   hand): without one anyone at the menu removes these args. Rollback still works:
#   boot entries stay unrestricted, only edit / command line / firmware entry ask.
#   Idea source: secureblue default kargs, minus what the Fedora kernel config already
#   does (init_on_alloc, slab_nomerge, randomize_kstack_offset).
sec_kargs() {
  if (( ${#KERNEL_ARGS[@]} == 0 )); then log "KERNEL_ARGS empty: nothing to add"; return; fi
  add_karg "${KERNEL_ARGS[@]}"
  log "new args work from the next boot; boot or unlock fails: previous entry in GRUB (Esc / Shift)"
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
  if [[ -z $TARGET_USER ]]; then warn "SUDO_USER is empty - user-specific steps will be skipped"; fi

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
      accounts)    sec_accounts ;;
      services)    sec_services ;;
      cron)        sec_cron ;;
      sshd)        sec_sshd ;;
      auditd)      sec_auditd ;;
      audit-rules) sec_audit_rules ;;
      perms)       sec_perms ;;
      mic)         sec_mic ;;
      netprivacy)  sec_netprivacy ;;
      mullvad)     sec_mullvad ;;
      kvmlan)      sec_kvmlan ;;
      usbguard)    sec_usbguard ;;
      appunit)     sec_appunit ;;
      time)        sec_time ;;
      kargs)       sec_kargs ;;
      *)           warn "unknown section: $s" ;;
    esac
  done

  printf '\nBackups: %s\nReboot recommended (kernel modules, sysctl one-way switches, PAM).\n' "$BACKUP_ROOT"
}

main "$@"
