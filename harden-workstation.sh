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
#   /var/backups/hardening/<timestamp>/<original path>   (no folder when nothing changed)
# Each section ends with its changes or "no change"; a second run: no change anywhere.
# A failed command stops the run: section, line, command, then the summary.
#
# Deliberately NOT applied (would break this machine):
#   - overlay module blacklist  -> Silverblue composefs, podman/toolbox
#   - XWayland disabled         -> Steam client and most games run on X11
#   - ip_forward = 0 / remove dnsmasq -> libvirt NAT network for KVM, rootful podman
#   - rp_filter = 1 (strict)    -> can drop WireGuard VPN traffic (using 2)
#   - lock after password expiry -> root is locked: an expired admin = no sudo at all
#   - auditd HALT               -> a full disk would halt the laptop
#   - auditd KEEP_LOGS          -> no limit, /var also holds /var/home (ROTATE, 40 x 32 MiB)
# =============================================================================
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Decisions - review before running
# -----------------------------------------------------------------------------
DISABLE_USB_STORAGE="no"     # "yes" = USB flash drives / external disks stop working
DISABLE_BLUETOOTH="no"       # "yes" = no Bluetooth headsets / game controllers
DISABLE_AVAHI="yes"          # "no"  if you use network printers or mDNS discovery
GUEST_TOOLS=(open-vm-tools-desktop open-vm-tools virtualbox-guest-additions spice-vdagent)
                             # guesttools section: VM guest agents removed from the image (rpm-ostree
                             # override remove, next boot) when this machine is not a VM; () = keep
ENABLE_NOISY_AUDIT="no"      # "yes" = log every chmod/chown/delete/denied-open by users (very noisy with Steam/Brave)
MAKE_AUDIT_IMMUTABLE="yes"   # "yes" = audit rules locked until reboot (-e 2): a rule change needs a reboot
SSH_SERVER="off"             # "on" = keep sshd usable (hardened) so other machines can SSH INTO this laptop.
                             # Outgoing ssh from this laptop to VMs / homelab works either way.
FINGERPRINT="disable"        # "keep" if you use a fingerprint reader ("disable" avoids fast faillock lockouts)
MIC_DISABLE="internal"       # "internal" = laptop mic + 3.5mm jack mic off (USB/Bluetooth mics still work)
                             # "all" = every mic off | "no" = leave microphones alone
IDLE_LOCK_SECONDS=900        # screen locks after 15 minutes idle
PASS_MAX_DAYS=365            # pwage section: password max age (days) for new and existing accounts
PASS_MIN_DAYS=1              # pwage section: min days between changes (pwhistory counts: no 24
                             # changes in a row back to the old password); 0 = none
PASS_WARN_AGE=14             # pwage section: warning this many days before
MAC_MODE="random"            # "random" = new MAC on every connect (Wi-Fi + cable)
                             # "stable-ssid" = same random MAC per Wi-Fi network (Fedora default)
GENERIC_HOSTNAME="localhost" # hostname every network may see; "" = keep the current one
UPLINK_IPV6="off"            # netprivacy section: "off" = IPv6 off on every Wi-Fi / cable profile,
                             # a new network's on its first connect (dispatcher); "keep" = as set
KERNEL_ARGS=(initcall_blacklist=af_alg_init page_alloc.shuffle=1 rd.shell=0 rd.emergency=halt
             init_on_free=1 iommu.strict=1 hash_pointers=always proc_mem.force_override=never
             module.sig_enforce=1 intel_iommu=on debugfs=off bdev_allow_write_mounted=0)
                             # kargs section; () = add none
PTRACE_SCOPE=3               # sysctl section: 2 = only root may trace (gdb / strace need sudo);
                             # 3 = nobody, root included, one-way until reboot
MULLVAD_SOCKET_GROUP="mullvad"  # mullvad section: only this group may use the Mullvad CLI / GUI
                             # "" = any local user (Mullvad's default)
MULLVAD_VM_BRIDGES=(virbr0 virbr-browse)  # kvmlan section: libvirt bridges outside Mullvad's LAN
                             # block (Allow LAN stays off; same names as if_vm in firewall/hostfw.nft); () = none
BROWSEVM_BRIDGE="virbr-browse"  # browsevm section: bridge of libvirt network "browse" (same name as
                             # if_vm_iso in firewall/hostfw.nft and in MULLVAD_VM_BRIDGES)
BROWSEVM_NET="192.168.123"   # browsevm section: /24 of that network (host .1, DHCP .10-.20)
SVIRT_OFF_BOOLEANS=(virt_use_usb virt_use_nfs)  # svirt section: SELinux booleans turned off (what
                             # every VM process may reach on the host); () = leave them
USBGUARD_BLOCK_BLUETOOTH="yes" # usbguard section: USB Bluetooth adapters blocked in the rules
                             # generated from the devices present ("no" = allowed like the rest)
AUTO_UPDATE_POLICY="stage"   # autoupdate section: rpm-ostree automatic updates (daily timer): "stage" =
                             # download + prepare, applied at the next reboot; "check" = only look;
                             # "none" = off (manual rpm-ostree upgrade)
FLATPAK_AUTO_UPDATE="yes"    # autoupdate section: Flatpaks (system + every user's) updated daily; "no" = leave
FIRMWARE_METADATA_REFRESH="yes"  # autoupdate section: fwupd-refresh.timer on FIRMWARE_METADATA_CALENDAR
                             # (LVFS metadata through the tunnel; Fedora's own timer: every
                             # hour); fwupd never installs firmware by itself; "no" = leave
FIRMWARE_METADATA_CALENDAR="*-*-1/2"  # systemd OnCalendar of that timer: every second day
                             # (odd days of the month, 00:00 + up to 1 h random; missed while
                             # off: at boot)
FIRMWARE_REPORTS="no"        # autoupdate section: "no" = fwupd sends no reports to LVFS (no report
                             # address in /etc/fwupd/remotes.d, nothing automatic); other = leave
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

# created by the first backup of a run only: a run that replaces nothing leaves no folder
BACKUP_ROOT="/var/backups/hardening/$(date +%Y%m%d-%H%M%S)"
SECTIONS=(sysctl modules coredump journald gnome sudo pam pwage su accounts services guesttools loopback cron sshd auditd audit-rules perms mic netprivacy mullvad kvmlan browsevm svirt usbguard appunit time autoupdate kargs)
CUR_SECTION=""      # the section running now (error report, change list)
CHANGE_LOG=""       # file: one line "<section> TAB <what>" per change (pipelines run
                    # functions in a subshell: a variable would lose their changes)
DONE_SECTIONS=()    # sections run to the end

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log()  { printf '\e[32m[+]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[!]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[31m[x]\e[0m %s\n' "$*" >&2; exit 1; }

# changed <what>: one change on this machine by the running section (file content, mode,
# unit state, account, firewall / profile setting, kernel arg). Reloads and restarts that
# follow a change are not counted. Second run on the same machine: no change anywhere.
changed() {
  [[ -n $CHANGE_LOG ]] || return 0
  printf '%s\t%s\n' "${CUR_SECTION:--}" "$*" >> "$CHANGE_LOG"
}

# section_changes [section]: number of changes of that section (default: the running one;
# the same change twice, e.g. two keys of one file, counts once)
section_changes() {
  [[ -n $CHANGE_LOG && -f $CHANGE_LOG ]] || { echo 0; return 0; }
  awk -F '\t' -v s="${1:-$CUR_SECTION}" '$1 == s && !seen[$0]++ { n++ } END { print n + 0 }' "$CHANGE_LOG"
}

# backup <path>...: copy to BACKUP_ROOT before a change; the first copy of a run stays
# (a second change of the same file in one run keeps the original)
backup() {
  local f
  for f in "$@"; do
    [[ -e "${BACKUP_ROOT}${f}" || -L "${BACKUP_ROOT}${f}" ]] && continue
    if [[ -e "$f" || -L "$f" ]]; then
      mkdir -p "${BACKUP_ROOT}$(dirname "$f")"
      cp -a "$f" "${BACKUP_ROOT}${f}"
    fi
  done
}

# same_mode <path> <mode>: octal mode of the file is <mode>
same_mode() { [[ $(( 8#$(stat -c %a "$1") )) -eq $(( 8#$2 )) ]]; }

# write_file <path> <mode>   (content comes from stdin). Same content: file not touched
# (mode set when it differs), no backup, no change
write_file() {
  local path="$1" mode="$2" tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [[ -f $path && ! -L $path ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    if ! same_mode "$path" "$mode"; then
      chmod "$mode" "$path"; log "$path -> $mode"; changed "$path mode $mode"
    fi
    return 0
  fi
  backup "$path"
  mkdir -p "$(dirname "$path")"
  cat "$tmp" > "$path"
  rm -f "$tmp"
  chmod "$mode" "$path"
  restorecon -F "$path" 2>/dev/null || true
  log "wrote $path"
  changed "$path"
}

# commit_file <path> <tmp>: <tmp> = new content of <path>. Differs: backup, written in
# place (owner, mode and label of an existing file stay), change. <tmp> removed
commit_file() {
  local path="$1" tmp="$2"
  if [[ -f $path ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 0; fi
  backup "$path"
  cat "$tmp" > "$path"
  rm -f "$tmp"
  restorecon -F "$path" 2>/dev/null || true
  changed "$path"
}

# set_kv <file> <key> <value>   ->   "key = value" (replaces commented or existing line)
set_kv() {
  local file="$1" key="$2" val="$3" tmp
  tmp=$(mktemp)
  if [[ -f $file ]]; then cat "$file" > "$tmp"; fi
  if grep -Eq "^[#[:space:]]*${key}[[:space:]]*=" "$tmp"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$tmp"
  else
    printf '%s = %s\n' "$key" "$val" >> "$tmp"
  fi
  commit_file "$file" "$tmp"
}

# set_mode <mode> <path>...: only where it differs
set_mode() {
  local mode="$1" f
  shift
  for f in "$@"; do
    if ! same_mode "$f" "$mode"; then chmod "$mode" "$f"; changed "$f mode $mode"; fi
  done
}

# set_owner_mode <owner:group> <mode> <path>...: only where it differs
set_owner_mode() {
  local own="$1" mode="$2" f
  shift 2
  for f in "$@"; do
    if [[ $(stat -c %U:%G "$f") != "$own" ]]; then chown "$own" "$f"; changed "$f owner $own"; fi
    if ! same_mode "$f" "$mode"; then chmod "$mode" "$f"; changed "$f mode $mode"; fi
  done
}

unit_exists() { systemctl list-unit-files --no-legend "$1" 2>/dev/null | grep . >/dev/null; }
# no 'cmd | grep -q' under pipefail: grep -q quits at the first match, the writer can get
# SIGPIPE and the pipe fails although the line was there (docs/lessons-learned.md)
in_group() { [[ " $(id -nG "$1" 2>/dev/null) " == *" $2 "* ]]; }

# unit_state <unit>: systemctl is-enabled output (masked, enabled, disabled, static, ...)
unit_state() { systemctl is-enabled "$1" 2>/dev/null || true; }

mask_units() {
  local u
  for u in "$@"; do
    if unit_exists "$u"; then
      if [[ $(unit_state "$u") == masked* ]] && ! systemctl is-active -q "$u"; then continue; fi
      if systemctl mask --now "$u" >/dev/null 2>&1; then log "masked $u"; changed "masked $u"
      else warn "could not mask $u"; fi
    fi
  done
}

# enable_unit <unit> [now]: enabled (and started with now) unless it is already
enable_unit() {
  local u="$1" now="${2:-}"
  if [[ $(unit_state "$u") != enabled ]]; then
    systemctl enable "$u" >/dev/null 2>&1 || return 1
    changed "enabled $u"
  fi
  if [[ $now == now ]] && ! systemctl is-active -q "$u"; then
    systemctl start "$u" >/dev/null 2>&1 || return 1
    changed "started $u"
  fi
  return 0
}

user_home() { getent passwd "$1" | cut -d: -f6; }

# immutable <path>: chattr +i set (first lsattr field holds a lowercase i; no link followed)
immutable() { [[ ! -L $1 && $(lsattr -d -- "$1" 2>/dev/null) =~ ^[^[:space:]]*i ]]; }

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
    changed "kernel args ${missing[*]#--append=}"
  else
    warn "rpm-ostree kargs ${missing[*]} failed"
  fi
}

# -----------------------------------------------------------------------------
# Sections
# -----------------------------------------------------------------------------
sec_sysctl() {
  [[ $PTRACE_SCOPE =~ ^[123]$ ]] || die "PTRACE_SCOPE must be 1, 2 or 3"
  write_file /etc/sysctl.d/90-hardening.conf 0644 <<EOF
# ---- Kernel ----
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
# PTRACE_SCOPE: 2 = admin-only attach (only CAP_SYS_PTRACE may trace: gdb / strace need
# sudo); 3 = no attach for anyone, root included. CIS RHEL 9 v3.0.0 accepts 1, 2 or 3
# and recommends 2; RHEL 9 STIG wants 1; KSPP recommends 3. 3 cannot be lowered until reboot.
kernel.yama.ptrace_scope = ${PTRACE_SCOPE}
kernel.randomize_va_space = 2
kernel.kexec_load_disabled = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1

# ---- Kernel attack surface (not CIS: KSPP recommended settings, 2026-11-16) ----
# io_uring off for every process (RHEL >= 9.3 default; Google: most kernel exploits of
# its 2022 bounty). Audit rule io-uring logs every refused try (audit-rules section).
kernel.io_uring_disabled = 2
# no automatic load of tty line discipline modules by unprivileged programs
dev.tty.ldisc_autoload = 0
# no O_CREAT open of another user's FIFO / file in world- or group-writable sticky dirs
fs.protected_fifos = 2
fs.protected_regular = 2
# Magic SysRq keys off
kernel.sysrq = 0
# panic after 100 WARN / Oops in one boot: stops exploits that retry until they win
kernel.warn_limit = 100
kernel.oops_limit = 100
# most random bits for mmap addresses (kernel maximum: 64-bit 32, 32-bit programs 16)
vm.mmap_rnd_bits = 32
vm.mmap_rnd_compat_bits = 16

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
  (( $(section_changes) == 0 )) || systemctl daemon-reload
}

sec_journald() {
  local main=/etc/systemd/journald.conf tmp
  write_file /etc/systemd/journald.conf.d/90-cis.conf 0644 <<'EOF'
[Journal]
Storage=persistent
Compress=yes
ForwardToSyslog=no
EOF
  # also in the main file: the scanner reads only /etc/systemd/journald.conf (Fedora ships
  # the main file in /usr/lib, comments only; the drop-in above wins either way)
  if [[ ! -e $main ]]; then
    write_file "$main" 0644 <<'EOF'
# CIS: ForwardToSyslog also here for scanners; settings: journald.conf.d/90-cis.conf
[Journal]
ForwardToSyslog=no
EOF
  elif grep -Eq '^[#[:space:]]*ForwardToSyslog=' "$main"; then
    tmp=$(mktemp)
    sed -E 's/^[#[:space:]]*ForwardToSyslog=.*/ForwardToSyslog=no/' "$main" > "$tmp"
    commit_file "$main" "$tmp"
  else
    warn "$main has no ForwardToSyslog line: add ForwardToSyslog=no under [Journal] by hand"
  fi
  if (( $(section_changes) )); then
    if systemctl restart systemd-journald; then log "journald restarted"; else warn "restart journald failed"; fi
  fi
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
    # login screen: password only (review A-4). Switchable authentication (GDM 50: passkey
    # and web login ride on it, own keys; GDM 51 dropped those two) and smartcard off,
    # fingerprint too with FINGERPRINT=disable. Their PAM services (gdm-switchable-auth,
    # gdm-smartcard, gdm-fingerprint) use authselect stubs that refuse every user; the
    # locked keys keep GDM off them if a later profile gives them a real stack
    local -a gdm_off=(enable-switchable-authentication enable-passkey-authentication
                      enable-web-authentication enable-smartcard-authentication)
    if [[ $FINGERPRINT == disable ]]; then gdm_off+=(enable-fingerprint-authentication); fi
    {
      printf '[org/gnome/login-screen]\ndisable-user-list=true\n'
      printf '%s=false\n' "${gdm_off[@]}"
    } | write_file /etc/dconf/db/gdm.d/90-cis-hardening 0644
    printf '/org/gnome/login-screen/%s\n' disable-user-list "${gdm_off[@]}" |
      write_file /etc/dconf/db/gdm.d/locks/90-cis-hardening 0644
    log "GDM: password login only (off + locked: ${gdm_off[*]#enable-})"
    # disable-user-list again in db "distro" (also in GDM's profile): scap-security-guide
    # checks only there
    write_file /etc/dconf/db/distro.d/90-cis-hardening 0644 <<'EOF'
[org/gnome/login-screen]
disable-user-list=true
EOF
    write_file /etc/dconf/db/distro.d/locks/90-cis-hardening 0644 <<'EOF'
/org/gnome/login-screen/disable-user-list
EOF
  else
    warn "gdm dconf profile not found - login user list and GDM login methods left as they are"
  fi
  if (( $(section_changes) )); then
    if dconf update; then log "dconf databases updated (log out/in to see changes)"
    else warn "dconf update failed - run: sudo dconf update"; fi
  fi
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
  local profile feat current

  if ! authselect check >/dev/null 2>&1; then
    warn "authselect reports manual PAM edits - skipping PAM section"
    return 0
  fi
  current=" $(authselect current --raw) "
  profile=${current# }; profile=${profile%% *}
  if [[ $current == *" with-fingerprint "* ]]; then
    if [[ $FINGERPRINT == disable ]]; then
      authselect disable-feature with-fingerprint >/dev/null
      log "authselect: disabled with-fingerprint"; changed "authselect -with-fingerprint"
    else
      warn "with-fingerprint is enabled: failed fingerprint reads can count toward faillock lockouts"
    fi
  fi
  for feat in with-faillock with-pwhistory without-nullok; do
    if [[ $current == *" $feat "* ]]; then
      continue
    elif authselect list-features "$profile" | grep -x "$feat" >/dev/null; then
      authselect enable-feature "$feat" >/dev/null
      log "authselect: enabled $feat"; changed "authselect +$feat"
    else
      warn "authselect profile '$profile' has no feature '$feat'"
    fi
  done
  if (( $(section_changes) )); then authselect apply-changes >/dev/null; fi

  set_kv /etc/security/faillock.conf deny 5
  set_kv /etc/security/faillock.conf fail_interval 900
  set_kv /etc/security/faillock.conf unlock_time 900
  set_kv /etc/security/pwhistory.conf remember 24
  log "faillock: 5 failures -> locked 15 min | pwhistory: last 24 passwords"

  # Written to the main pwquality.conf (the scanner only checks that file). minlen 15: NIST
  # SP 800-63B-4 minimum for a password used alone (CIS: 14); minclass 4: CIS (deviations.md)
  local pq=/etc/security/pwquality.conf kv
  for kv in minlen=15 minclass=4 difok=2 maxrepeat=3 maxsequence=3 dictcheck=1; do
    set_kv "$pq" "${kv%%=*}" "${kv#*=}"
  done
  if ! grep -qx 'enforce_for_root' "$pq"; then
    backup "$pq"; echo 'enforce_for_root' >> "$pq"; changed "$pq enforce_for_root"
  fi
  if [[ -e /etc/security/pwquality.conf.d/90-cis.conf ]]; then
    backup /etc/security/pwquality.conf.d/90-cis.conf
    rm -f /etc/security/pwquality.conf.d/90-cis.conf
    changed "removed /etc/security/pwquality.conf.d/90-cis.conf"
  fi
  log "pwquality: min 15 chars, 4 character classes, dictionary check"
}

## CIS: password aging. login.defs (new accounts) + chage on every login account (uid >= 1000
## with a usable password): max age, warning, min age (pwhistory counts; root can still
## change any password the same day: sudo passwd <user>). No INACTIVE lock: root is locked,
## an expired + locked admin = no sudo. An account whose password would expire within the
## warning days is skipped: change that password first, then run the section again.
sec_pwage() {
  local defs=/etc/login.defs u uid shell hash last min max warnd today kv tmp
  for kv in "$PASS_MAX_DAYS" "$PASS_MIN_DAYS" "$PASS_WARN_AGE"; do
    [[ $kv =~ ^(0|[1-9][0-9]{0,4})$ ]] || die "PASS_MAX_DAYS, PASS_MIN_DAYS, PASS_WARN_AGE: whole numbers"
  done
  (( PASS_MIN_DAYS < PASS_MAX_DAYS - PASS_WARN_AGE )) ||
    die "PASS_MIN_DAYS must be below PASS_MAX_DAYS - PASS_WARN_AGE"
  today=$(( $(date +%s) / 86400 ))
  tmp=$(mktemp)
  cat "$defs" > "$tmp"
  for kv in "PASS_MAX_DAYS $PASS_MAX_DAYS" "PASS_MIN_DAYS $PASS_MIN_DAYS" "PASS_WARN_AGE $PASS_WARN_AGE"; do
    if grep -Eq "^[[:space:]]*${kv%% *}[[:space:]]" "$tmp"; then      # set lines, not comments
      sed -i -E "s/^[[:space:]]*${kv%% *}[[:space:]].*/${kv%% *}\t${kv#* }/" "$tmp"
    else
      printf '%s\t%s\n' "${kv%% *}" "${kv#* }" >> "$tmp"
    fi
  done
  commit_file "$defs" "$tmp"
  log "login.defs: PASS_MAX_DAYS $PASS_MAX_DAYS, PASS_MIN_DAYS $PASS_MIN_DAYS, PASS_WARN_AGE $PASS_WARN_AGE"
  while IFS=: read -r u _ uid _ _ _ shell; do
    (( uid >= 1000 && uid < 60000 )) || continue
    [[ $shell == */nologin || $shell == */false ]] && continue
    IFS=: read -r _ hash last min max warnd _ < <(getent shadow "$u")
    [[ $hash == [\!\*]* || -z $hash ]] && { log "$u: no usable password - skipped"; continue; }
    if [[ -z $last || $last == 0 ]] || (( today - last >= PASS_MAX_DAYS - PASS_WARN_AGE )); then
      if [[ -z $last || $last == 0 ]]; then last="never"; else last="$(( today - last )) days ago"; fi
      warn "$u: password last changed $last - change it first, skipped"
      continue
    fi
    if [[ $max == "$PASS_MAX_DAYS" && $min == "$PASS_MIN_DAYS" && $warnd == "$PASS_WARN_AGE" ]]; then
      log "$u: max $PASS_MAX_DAYS days, min $PASS_MIN_DAYS, warning $PASS_WARN_AGE already"
      continue
    fi
    chage -M "$PASS_MAX_DAYS" -m "$PASS_MIN_DAYS" -W "$PASS_WARN_AGE" "$u"
    log "$u: max $PASS_MAX_DAYS days, min $PASS_MIN_DAYS, warning $PASS_WARN_AGE (changed $(( today - last )) days ago)"
    changed "$u password aging"
  done < <(getent passwd)
}

sec_su() {
  if ! getent group sugroup >/dev/null; then groupadd sugroup; changed "group sugroup"; fi
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
    changed "/etc/pam.d/su pam_wheel group=sugroup"

  else
    warn "pam_rootok line not found in /etc/pam.d/su - nothing changed"
  fi
}

## Admin home (review A-3, not CIS). A script handed to the admin runs as the admin: it
## could put an alias, a function or a PATH entry for sudo into a file the admin's shell
## reads, and catch the password at the next sudo. Here:
## - shell start files = accounts/admin.* (fixed PATH, no ~/.bashrc.d, readline includes
##   /etc/inputrc), immutable (chattr +i: no write, rename, delete or chmod, not even by the
##   owner). Owner stays the admin: CIS 7.2.9 rules want that, and a root-owned file in a
##   home the admin owns protects nothing (the admin can rename it and put its own there)
## - files bash, /etc/profile.d or bash-completion read at start, unused here, removed
##   (backup first): .profile .bash_login (read only without .bash_profile), .bash_completion,
##   .i18n (lang.sh), .config/bash_completion
## - the top of the home, .config, .local, .local/share immutable (those present): nothing
##   new there, so none of the files above, no git config. Also .config/systemd,
##   .local/share/systemd (timer stamps live there) and .local/share/flatpak, if present:
##   no user/ (user units) or exports/ (XDG_DATA_DIRS: completions) can be made in them.
##   Directories already inside stay writable: tools/check-accounts.sh lists them, FAIL on
##   known places that run code
## Not covered (THREAT_MODEL.md): a process the script left running until logout / reboot,
## the admin's own clones. Cost: nothing new at those levels without root (sudo chattr -i)
ADMIN_RC=(bash_profile bashrc bash_logout inputrc)
ADMIN_GONE=(.profile .bash_login .bash_completion .i18n .config/bash_completion)
# under the home, inner first; the home last
ADMIN_FROZEN=(.config/systemd .local/share/systemd .local/share/flatpak .config .local/share .local)
# known places that run code; already there = writable: warned, look and remove by hand
ADMIN_CODE_DIRS=(.config/systemd/user .local/share/systemd/user .config/git .config/environment.d
                 .local/share/bash-completion .local/share/flatpak/exports)
admin_home_lock() {
  local a=$1 home grp src f rel n=0
  home=$(user_home "$a")
  grp=$(id -gn "$a")
  [[ $home == /?* && -d $home && ! -L $home ]] || { warn "admin home '$home' not found - lock skipped"; return 0; }
  if ! command -v chattr >/dev/null || ! command -v lsattr >/dev/null; then
    warn "no chattr / lsattr - admin home lock skipped"; return 0
  fi
  src="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/accounts"
  for f in "${ADMIN_RC[@]}"; do
    [[ -f $src/admin.$f ]] || { warn "missing $src/admin.$f - admin home lock skipped"; return 0; }
  done

  # unlock what an earlier run locked; locked again below (change = not locked before)
  local -A was_locked=()
  for rel in "${ADMIN_RC[@]/#/.}" "${ADMIN_FROZEN[@]}" .; do
    f=$home/$rel
    if immutable "$f"; then was_locked[$rel]=1; chattr -i -- "$f" || die "chattr -i $f failed"; fi
  done

  for f in "${ADMIN_RC[@]}"; do
    if [[ -f $home/.$f && ! -L $home/.$f ]] && cmp -s "$src/admin.$f" "$home/.$f"; then continue; fi
    backup "$home/.$f"
    install -m 0640 -o "$a" -g "$grp" "$src/admin.$f" "$home/.$f"    # replaces a link too
    restorecon -F "$home/.$f" 2>/dev/null || true
    log "$home/.$f <- accounts/admin.$f"; n=$((n + 1)); changed "$home/.$f"
  done
  set_owner_mode "$a:$grp" 0640 "${ADMIN_RC[@]/#/$home/.}"
  (( n )) || log "admin shell start files: no change"

  for rel in "${ADMIN_GONE[@]}"; do
    f=$home/$rel
    [[ -f $f || -L $f ]] || continue
    if immutable "$f"; then chattr -i -- "$f" || die "chattr -i $f failed"; fi
    backup "$f"
    rm -f -- "$f"
    warn "removed $f (read at shell start; copy in $BACKUP_ROOT)"; changed "removed $f"
  done
  # history: bash writes it at logout, it cannot create it once the home is locked
  if [[ ! -e $home/.bash_history ]]; then
    install -m 0600 -o "$a" -g "$grp" /dev/null "$home/.bash_history"; changed "$home/.bash_history"
  fi

  for f in "${ADMIN_RC[@]}"; do
    if chattr +i -- "$home/.$f"; then
      [[ -n ${was_locked[.$f]:-} ]] || changed "chattr +i $home/.$f"
    else
      warn "chattr +i $home/.$f failed (filesystem without it?)"
    fi
  done
  for rel in "${ADMIN_FROZEN[@]}" .; do
    f=$home/$rel
    if [[ -L $f ]]; then warn "$f is a link: not locked, look at it"; continue; fi
    [[ -d $f ]] || continue
    if chattr +i -- "$f"; then
      [[ -n ${was_locked[$rel]:-} ]] || changed "chattr +i $f"
    else
      warn "chattr +i $f failed"
    fi
  done
  for rel in "${ADMIN_CODE_DIRS[@]}"; do
    if [[ -e $home/$rel || -L $home/$rel ]]; then
      warn "$home/$rel exists and stays writable (runs code): look, remove by hand"
    fi
  done
  log "admin home: shell start files from accounts/ (PATH without home dirs), immutable;"
  log "  nothing new at the top of $home, .config, .local, .local/share, systemd / flatpak dirs (sudo chattr -i to change)"
}

## Not CIS as a rule, CIS Controls v8.1 5.4 / NIST SP 800-53 AC-6(2) / NSA-CISA AA23-278A #2:
## admin work from an account used for nothing else. ADMIN_USER: wheel, text console only
## (hidden from GDM, GDM login refused). DAILY_USER: GNOME, browsers, no sudo.
## Run 1 (any sudo user): admin account + GDM + homes + admin home lock (admin_home_lock,
## both runs). Its password is set by hand on a text console. Run 2 from the admin itself (its sudo is the proof it works): the daily
## user leaves wheel, the Mullvad group and sectop's reader group. Never the other way: root is locked, a daily
## user out of wheel before the admin's sudo works = no sudo left.
sec_accounts() {
  local a=$ADMIN_USER d=$DAILY_USER as f h pam=/etc/pam.d/gdm-password g
  local line="auth       requisite   pam_succeed_if.so user != ${ADMIN_USER} quiet_success"
  if [[ -z $a || -z $d ]]; then log "ADMIN_USER / DAILY_USER empty: one account, nothing to do"; return 0; fi
  for f in "$a" "$d"; do
    [[ $f =~ ^[a-z_][a-z0-9_-]{0,31}$ && $f != root ]] || { warn "bad user name '$f' - skipped"; return 0; }
  done
  [[ $a != "$d" ]] || { warn "ADMIN_USER = DAILY_USER - skipped"; return 0; }
  id "$d" >/dev/null 2>&1 || { warn "no daily user $d - skipped"; return 0; }

  # --- admin account: wheel, own group, bash
  if id "$a" >/dev/null 2>&1; then
    in_group "$a" wheel || { usermod -aG wheel "$a"; log "$a added to wheel"; changed "$a in wheel"; }
    log "admin $a: $(id "$a")"
  else
    useradd -m -U -G wheel -s /bin/bash -c "admin (text console)" "$a"
    log "admin $a created (wheel, password locked until set)"; changed "user $a"
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
    log "$f: SystemAccount=true added (GDM list: after a reboot)"; changed "$f SystemAccount=true"
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
    log "$pam: line 1 refuses $a (GDM password login)"; changed "$pam refuses $a"
  else
    warn "$pam missing (no GDM?) - GDM line skipped"
  fi

  # --- homes: owner only (the admin's may be locked from an earlier run: unlocked for
  # chmod, locked again by admin_home_lock)
  for f in "$a" "$d"; do
    h=$(user_home "$f")
    if [[ $(stat -c %a "$h") != 700 ]]; then
      if immutable "$h"; then chattr -i -- "$h"; fi
      chmod 0700 "$h"; log "home of $f -> 0700"; changed "$h mode 0700"
    else
      log "home of $f: 0700"
    fi
  done
  admin_home_lock "$a"
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
      usermod -aG "$g" "$a"; log "$a added to $g"; changed "$a in $g"
    fi
    if in_group "$d" "$g"; then
      gpasswd -d "$d" "$g" >/dev/null; log "$d removed from $g"; changed "$d out of $g"
    fi
  done
  # sectop's reader group: the daily user runs only the user helper (install.sh warns,
  # sysusers never removes a member). Found 2026-11-06: still a member after the split
  if getent group sectop >/dev/null && in_group "$d" sectop; then
    gpasswd -d "$d" sectop >/dev/null; log "$d removed from sectop"; changed "$d out of sectop"
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
  if unit_exists nftables.service && [[ $(unit_state nftables.service) != masked* ]]; then
    systemctl disable nftables.service >/dev/null 2>&1 || true
    if systemctl mask nftables.service >/dev/null 2>&1; then
      log "nftables.service masked (firewalld manages nftables)"; changed "masked nftables.service"
    else
      warn "could not mask nftables.service"
    fi
  fi
}

## CIS Controls v8.1 4.8 (uninstall or disable unnecessary services): guest agents for VMware, VirtualBox
## and SPICE are in Fedora's base image for when it runs as a VM. On real hardware they do
## nothing useful, but they bring a setuid root program (vmware-user-suid-wrapper) and agents
## started at every login. Removed from the image with rpm-ostree (new deployment, next boot),
## only packages nothing else needs. Their setuid files leave the audit rules in the same go
## (55-privileged.rules, loaded at that boot): rules and programs match after one reboot.
## Way back: rpm-ostree override reset <package>, then audit-rules after the reboot.
sec_guesttools() {
  local p f virt removed rules=/etc/audit/rules.d/55-privileged.rules tmp
  local -a cand=() want=() req=() caps=() gone=() other=() dropped=()

  (( ${#GUEST_TOOLS[@]} )) || { log "GUEST_TOOLS empty: guest tools kept"; return 0; }
  command -v rpm-ostree >/dev/null || { warn "no rpm-ostree: remove ${GUEST_TOOLS[*]} with your package manager"; return 0; }
  virt=$(systemd-detect-virt 2>/dev/null || true)
  if [[ -n $virt && $virt != none ]]; then warn "this machine is a VM ($virt): guest tools kept"; return 0; fi

  # removals already asked for (default deployment: the next boot, or the booted one)
  removed=" $( { rpm-ostree status --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["deployments"][0]
print(" ".join(d.get("requested-base-removals", [])))' 2>/dev/null; } || true) "
  for p in "${GUEST_TOOLS[@]}"; do
    if [[ $removed == *" $p "* ]]; then log "$p: removal already in the image"
    elif rpm -q "$p" >/dev/null 2>&1; then cand+=("$p")
    else log "$p: not installed"; fi
  done
  (( ${#cand[@]} )) || return 0

  # nothing outside this list may need a package (its name or anything it provides)
  for p in "${cand[@]}"; do
    mapfile -t caps < <(rpm -q --provides "$p" | awk '{ print $1 }' | sort -u)
    mapfile -t req < <(rpm -q --qf '%{NAME}\n' --whatrequires "$p" "${caps[@]}" 2>/dev/null |
                       grep -v '^no package requires' | sort -u)
    other=()
    for f in "${req[@]}"; do
      [[ " ${cand[*]} " == *" $f "* ]] || other+=("$f")
    done
    if (( ${#other[@]} )); then warn "$p kept: needed by ${other[*]}"; else want+=("$p"); fi
  done
  (( ${#want[@]} )) || return 0

  # their setuid / setgid files (still on disk until the reboot). Files only: rpm -ql also
  # lists links to them (/usr/bin/vmware-user, /usr/lib/.build-id/...), and -u / -g follow
  # links; the privileged rules have files only (find -type f, audit-rules section)
  for p in "${want[@]}"; do
    while IFS= read -r f; do
      if [[ -f $f && ! -L $f && ( -u $f || -g $f ) ]]; then gone+=("$f"); fi
    done < <(rpm -ql "$p" 2>/dev/null)
  done

  if ! rpm-ostree override remove "${want[@]}" >/dev/null; then
    warn "rpm-ostree override remove ${want[*]} failed: nothing changed"; return 0
  fi
  log "removed from the image, gone at the next boot: ${want[*]}"
  log "way back: rpm-ostree override reset ${want[*]} (then reboot)"
  changed "rpm-ostree override remove ${want[*]}"
  if (( ${#gone[@]} )); then log "setuid / setgid files with them: ${gone[*]}"; fi

  if (( ${#gone[@]} )) && [[ -f $rules ]]; then
    # rules that really go: a file of the list with a path= rule in the file
    for f in "${gone[@]}"; do
      if awk -v p="path=$f" '{ for (i = 1; i <= NF; i++) if ($i == p) { found = 1; exit } }
                            END { exit !found }' "$rules"; then
        dropped+=("$f")
      fi
    done
    if (( ${#dropped[@]} )); then
      tmp=$(mktemp)
      awk -v list="${dropped[*]}" '
        BEGIN { n = split(list, g, " "); for (i = 1; i <= n; i++) drop["path=" g[i]] = 1 }
        { for (i = 1; i <= NF; i++) if ($i in drop) next; print }' "$rules" > "$tmp"
      write_file "$rules" 0640 < "$tmp"
      rm -f "$tmp"
      log "audit: $(grep -c -- '-k privileged' "$rules") privileged rules from the next boot (rules dropped: ${dropped[*]})"
    else
      log "audit: no privileged rule for those files (nothing to drop)"
    fi
  fi
}

## CIS: loopback traffic (firewalld): lo in zone trusted, 127.0.0.1 / ::1 as source only
## toward themselves. Permanent config, then a firewalld reload (own table only: hostfw,
## Mullvad and kvmlan tables stay).
sec_loopback() {
  local r
  local -a rules=('rule family="ipv4" source address="127.0.0.1" destination not address="127.0.0.1" drop'
                  'rule family="ipv6" source address="::1" destination not address="::1" drop')
  command -v firewall-cmd >/dev/null || { warn "no firewall-cmd - skipped"; return 0; }
  if firewall-cmd --permanent --zone=trusted --query-interface=lo >/dev/null 2>&1; then
    log "lo already in zone trusted"
  else
    firewall-cmd --permanent --zone=trusted --add-interface=lo >/dev/null
    log "lo -> zone trusted"; changed "firewalld: lo in zone trusted"
  fi
  for r in "${rules[@]}"; do
    if firewall-cmd --permanent --zone=trusted --query-rich-rule="$r" >/dev/null 2>&1; then
      log "rich rule there: $r"
    else
      firewall-cmd --permanent --zone=trusted --add-rich-rule="$r" >/dev/null
      log "rich rule: $r"; changed "firewalld: trusted rich rule $r"
    fi
  done
  if (( $(section_changes) )); then
    if firewall-cmd --reload >/dev/null; then log "firewalld reloaded"; else warn "firewall-cmd --reload failed"; fi
  fi
}

sec_cron() {
  local f
  for f in /etc/crontab /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.yearly; do
    [[ -e $f ]] || continue
    if [[ $(stat -c %U:%G "$f") != root:root ]]; then chown root:root "$f"; changed "$f owner root:root"; fi
    if (( 8#$(stat -c %a "$f") & 8#077 )); then chmod og-rwx "$f"; changed "$f og-rwx"; fi
  done
  # the dirs were back at the image mode 0755 on 2026-11-09 (crontab kept 0600): tmpfiles
  # sets the modes again at every boot ("z": existing paths only)
  write_file /etc/tmpfiles.d/90-cis-cron.conf 0644 <<'EOF'
z /etc/crontab      0600 root root -
z /etc/cron.d       0700 root root -
z /etc/cron.hourly  0700 root root -
z /etc/cron.daily   0700 root root -
z /etc/cron.weekly  0700 root root -
z /etc/cron.monthly 0700 root root -
z /etc/cron.yearly  0700 root root -
EOF
  if [[ -e /etc/cron.deny ]]; then backup /etc/cron.deny; rm -f /etc/cron.deny; changed "removed /etc/cron.deny"; fi
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
      warn "sshd -t failed - removed 40-cis.conf"; changed "removed /etc/ssh/sshd_config.d/40-cis.conf"
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
  set_mode 0640 "$f"
  if (( $(section_changes) == 0 )); then log "$f: no change"; return 0; fi
  if auditctl --signal reload >/dev/null 2>&1; then log "auditd configuration reloaded"; else warn "reload auditd manually or reboot"; fi
}

sec_audit_rules() {
  local d=/etc/audit/rules.d n
  # The earlier 50-watch.rules used b64-only rules, which miss 32-bit programs (Steam).
  if [[ -e $d/50-watch.rules ]]; then
    backup "$d/50-watch.rules"; rm -f "$d/50-watch.rules"; log "removed old 50-watch.rules (backed up)"
    changed "removed $d/50-watch.rules"
  fi

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
    changed "removed $d/99-finalize.rules"
  fi

  # Not CIS (2026-11-16): io_uring is off for everyone (sysctl section), so every
  # io_uring_setup call fails with EPERM: a program that wants it, or a probe.
  write_file "$d/70-io-uring.rules" 0640 <<'EOF'
## io_uring_setup, not CIS. kernel.io_uring_disabled = 2 (sysctl section): every call
## fails (EPERM), so every event is a refused try.
-a always,exit -F arch=b64 -S io_uring_setup -k io-uring
-a always,exit -F arch=b32 -S io_uring_setup -k io-uring
EOF

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

  set_mode 0640 "$d"/*.rules
  # audit.rules (built from rules.d by augenrules, loaded at boot) already up to date and
  # nothing changed here: no rebuild, no load
  if (( $(section_changes) == 0 )) && [[ $(augenrules --check 2>&1) == *"No change"* ]]; then
    log "audit rules: no change (rules.d = /etc/audit/audit.rules)"
    return 0
  fi
  if [[ $(auditctl -s | awk '$1 == "enabled" {print $2}') == 2 ]]; then
    # Locked: the kernel refuses every change. Write audit.rules, load it at boot.
    if ! augenrules >/dev/null; then warn "augenrules reported an error - check the files in $d"; fi
    changed "/etc/audit/audit.rules"
    log "audit rules are locked (-e 2): the new rules load at the next reboot"
    return 0
  fi
  if ! augenrules --load >/dev/null; then
    warn "augenrules reported an error - run: sudo augenrules --load"
  fi
  changed "/etc/audit/audit.rules (loaded)"
  n=$(auditctl -l | grep -vc '^No rules' || true)
  log "audit rules loaded in kernel: $n"
  if (( n < 40 )); then warn "fewer rules than expected - check the files in $d"; fi
  if [[ $MAKE_AUDIT_IMMUTABLE == yes ]]; then log "audit rules locked now (-e 2): next change needs a reboot"; fi
}

sec_perms() {
  local home f u
  for f in /etc/audit/auditd.conf /etc/audit/audit.rules /etc/audit/rules.d/*.rules; do
    [[ -f $f ]] || continue
    if ! same_mode "$f" 0640; then chmod 0640 "$f"; changed "$f mode 0640"; fi
  done
  log "audit config files: 0640"

  # every file in /boot/grub2 (also the empty marker .grub2-blscfg-supported); tmpfiles sets
  # the known ones again at boot, after a bootloader update wrote them with 0644
  if [[ -d /boot/grub2 ]]; then
    while IFS= read -r -d '' f; do
      chmod go-rwx "$f"; log "$f: go-rwx"; changed "$f go-rwx"
    done < <(find /boot/grub2 -maxdepth 1 -type f -perm /0077 -print0)
  fi
  write_file /etc/tmpfiles.d/90-cis-grub.conf 0644 <<'EOF'
z /boot/grub2/grub.cfg                0600 root root -
z /boot/grub2/user.cfg                0600 root root -
z /boot/grub2/grubenv                 0600 root root -
z /boot/grub2/.grub2-blscfg-supported 0600 root root -
EOF

  for u in "$TARGET_USER" "$ADMIN_USER"; do          # the admin's home too (skel: 0644)
    [[ -n $u ]] && id "$u" >/dev/null 2>&1 || continue
    home=$(user_home "$u")
    # every dotfile in the home, not only shell rc (the scanner checks .gitconfig too);
    # immutable ones (the admin's shell files, accounts section) are 0640 already
    while IFS= read -r -d '' f; do
      if immutable "$f"; then warn "$f: immutable, mode left (chattr -i first)"; continue; fi
      chmod g-wx,o-rwx "$f"; changed "$f g-wx,o-rwx"
    done < <(find "$home" -maxdepth 1 -type f -name '.*' -perm /0037 -print0)
    log "dotfiles in $home: 0740 or stricter"
  done
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

  if (( $(section_changes) == 0 )); then
    :
  elif [[ -n $TARGET_USER ]] && systemctl --user -M "${TARGET_USER}@" restart wireplumber >/dev/null 2>&1; then
    log "WirePlumber restarted for $TARGET_USER"
  else
    warn "restart WirePlumber yourself (not with sudo): systemctl --user restart wireplumber"
  fi
}


# Not CIS: what a network I join can learn about this laptop. No real MAC, no hostname.
sec_netprivacy() {
  local ethmac v6 hook=/etc/NetworkManager/dispatcher.d/50-netprivacy src c0 nm_conf=0 res_conf=0
  case $MAC_MODE in
    random)      ethmac=random ;;
    stable-ssid) ethmac=stable ;;
    *) die "MAC_MODE must be random or stable-ssid" ;;
  esac
  case $UPLINK_IPV6 in
    off)  v6=disabled ;;
    keep) v6="" ;;
    *) die "UPLINK_IPV6 must be off or keep" ;;
  esac
  src="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/netprivacy/nm-dispatcher/50-netprivacy"
  [[ -f $src ]] || die "$src missing (run from the repo)"
  c0=$(section_changes)
  write_file /etc/NetworkManager/conf.d/90-privacy.conf 0644 <<EOF
[main]
# DNS only from the tunnel: Mullvad puts its resolver on its own link in systemd-resolved
# (D-Bus SetLinkDNS), NetworkManager hands resolved none, from no network (DHCP, router
# advertisement, profile), a new one included. dns=none alone is not enough: with
# systemd-resolved=true (default) NetworkManager still sends the profile DNS to resolved.
# /etc/resolv.conf stays resolved's stub (dns=none = rc-manager unmanaged).
dns=none
systemd-resolved=false

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
  (( $(section_changes) == c0 )) || nm_conf=1
  # LLMNR / mDNS answer and announce the hostname on the LAN (avahi: services section)
  c0=$(section_changes)
  write_file /etc/systemd/resolved.conf.d/90-privacy.conf 0644 <<'EOF'
[Resolve]
LLMNR=no
MulticastDNS=no
EOF
  (( $(section_changes) == c0 )) || res_conf=1
  if (( nm_conf )); then
    if systemctl reload NetworkManager; then log "NetworkManager config reloaded"; else warn "reload NetworkManager failed - reboot"; fi
  fi
  # existing Wi-Fi / cable profiles, written in the profile:
  # - no hostname in DHCP
  # - no DNS servers (static or from DHCP): only the tunnel has one. With a server on the
  #   uplink, resolved falls back to it while the tunnel has none (connect / reconnect)
  #   and queries go out unencrypted (seen 2026-10-31, blocked by hostfw out_dns).
  #   ignore-auto-dns has no global default in NetworkManager.conf(5): per profile only
  #   (dns=none above already keeps them out of resolved: belt and braces).
  # - IPv6 off (UPLINK_IPV6=off): ipv6.method has no global default either. Fewer
  #   packets on the LAN (router solicitations, DHCPv6), no IPv6 address from it.
  # profiles: the fields before and after nmcli modify (same values = nothing changed);
  # the folder copied first, kept as backup only when a profile changed
  local uuid type n=0 m=0 before after snap
  local f=ipv4.dns,ipv4.ignore-auto-dns,ipv6.dns,ipv6.ignore-auto-dns,ipv4.dhcp-send-hostname,ipv6.dhcp-send-hostname,ipv6.method
  local -a v6arg=()
  [[ -z $v6 ]] || v6arg=(ipv6.method "$v6")
  snap=$(mktemp -d)
  cp -a /etc/NetworkManager/system-connections "$snap/"
  while IFS=: read -r uuid type; do
    case $type in 802-11-wireless|802-3-ethernet) ;; *) continue ;; esac
    before=$(nmcli -g "$f" connection show "$uuid" 2>/dev/null) || before="?"
    if nmcli connection modify "$uuid" ipv4.dhcp-send-hostname no ipv6.dhcp-send-hostname no \
         ipv4.dns "" ipv4.ignore-auto-dns yes ipv6.dns "" ipv6.ignore-auto-dns yes "${v6arg[@]}"; then
      n=$((n + 1))
      after=$(nmcli -g "$f" connection show "$uuid" 2>/dev/null) || after="??"
      if [[ $before != "$after" ]]; then m=$((m + 1)); changed "NetworkManager profile $uuid"; fi
    else
      warn "profile $uuid: not changed"
    fi
  done < <(nmcli -g UUID,TYPE connection show)
  if (( m )) && [[ ! -e $BACKUP_ROOT/etc/NetworkManager/system-connections ]]; then
    mkdir -p "$BACKUP_ROOT/etc/NetworkManager"
    cp -a "$snap/system-connections" "$BACKUP_ROOT/etc/NetworkManager/"
  fi
  rm -rf "$snap"
  log "no hostname in DHCP, no DNS servers${v6:+, IPv6 $v6} on $n Wi-Fi / cable profiles ($m changed)"
  # profiles made later (a new network): the same on their first connect (dispatcher hook,
  # input = profile uuid only). The hostname: the generic one covers the first DHCP.
  sed "s/^IPV6_METHOD=[a-z]*/IPV6_METHOD=${v6}/" "$src" | write_file "$hook" 0755
  # live connections: reapply after a change (no reconnect, same MAC and lease)
  local dev state
  if (( m || nm_conf )); then
    while IFS=: read -r dev type state; do
      case $type in wifi|ethernet) ;; *) continue ;; esac
      [[ $state == connected ]] || continue
      if nmcli device reapply "$dev" >/dev/null; then log "reapplied $dev"; else warn "reapply $dev failed - reconnect it"; fi
    done < <(nmcli -g DEVICE,TYPE,STATE device)
  fi
  # profiles made later send the hostname on their first connect (NetworkManager 1.56.1
  # ignores the global dhcp-send-hostname default): a generic hostname
  if [[ -n $GENERIC_HOSTNAME ]]; then
    if [[ $(hostnamectl hostname --static 2>/dev/null || true) != "$GENERIC_HOSTNAME" ]]; then
      hostnamectl set-hostname --static "$GENERIC_HOSTNAME"; changed "static hostname $GENERIC_HOSTNAME"
    fi
    if [[ -n $(hostnamectl hostname --pretty 2>/dev/null || true) ]]; then
      hostnamectl set-hostname --pretty ""   # pretty name = Bluetooth / GNOME device name
      changed "pretty hostname empty"
    fi
    # static "localhost" counts as unset: hostnamed then shows the distro fallback
    # ("fedora") as transient hostname. Same name as fallback (systemd.io ENVIRONMENT).
    c0=$(section_changes)
    write_file /etc/systemd/system/systemd-hostnamed.service.d/90-privacy.conf 0644 <<EOF
[Service]
Environment=SYSTEMD_DEFAULT_HOSTNAME=${GENERIC_HOSTNAME}
EOF
    if (( $(section_changes) != c0 )); then
      systemctl daemon-reload
      systemctl try-restart systemd-hostnamed.service || true
    fi
    # The initramfs comes with the image (no /etc/hostname in it): its systemd set the
    # fallback "fedora" for the first ~12 s of boot. The kernel hands KEY=value args it
    # does not know to PID 1 as environment, in the initramfs too (tested 2026-10-27).
    add_karg "SYSTEMD_DEFAULT_HOSTNAME=${GENERIC_HOSTNAME}"
    log "hostname: $GENERIC_HOSTNAME (log out and in: X11 apps keep the old name in Xauthority)"
  fi
  # reload, not restart: a restart drops the DNS servers Mullvad set on its link
  if (( res_conf )); then
    if systemctl reload systemd-resolved; then log "resolved config reloaded"; else warn "reload systemd-resolved failed - reboot"; fi
  fi
  (( nm_conf == 0 )) || log "new MAC on the next connect: reconnect Wi-Fi / cable, or reboot"

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
  if ! getent group "$MULLVAD_SOCKET_GROUP" >/dev/null; then
    groupadd -r "$MULLVAD_SOCKET_GROUP"; changed "group $MULLVAD_SOCKET_GROUP"
  fi
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
    changed "$who in $MULLVAD_SOCKET_GROUP"
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
  if [[ $(unit_state kvmlan.service) != enabled ]]; then
    if systemctl enable kvmlan.service >/dev/null 2>&1; then log "kvmlan.service enabled"; changed "enabled kvmlan.service"
    else warn "could not enable kvmlan.service"; fi
  fi
  if (( $(section_changes) == 0 )) && systemctl is-active -q kvmlan.service; then
    log "table inet kvmlan: no change (${MULLVAD_VM_BRIDGES[*]})"
  elif systemctl reload-or-restart kvmlan.service; then log "table inet kvmlan loaded: ${MULLVAD_VM_BRIDGES[*]}"
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

# fw_policy <name> <ingress zone> <egress zone> <target>: permanent firewalld policy
fw_policy() {
  local name=$1 in=$2 out=$3 target=$4
  if [[ " $(firewall-cmd --permanent --get-policies) " != *" $name "* ]]; then
    firewall-cmd --permanent --new-policy="$name" >/dev/null ||
      { warn "could not create firewalld policy $name - skipped"; return 1; }
    log "firewalld policy $name created"; changed "firewalld policy $name"
  fi
  if ! firewall-cmd --permanent --policy="$name" --query-ingress-zone="$in" >/dev/null 2>&1; then
    if firewall-cmd --permanent --policy="$name" --add-ingress-zone="$in" >/dev/null; then
      changed "firewalld policy $name ingress $in"
    else warn "policy $name: ingress $in"; fi
  fi
  if ! firewall-cmd --permanent --policy="$name" --query-egress-zone="$out" >/dev/null 2>&1; then
    if firewall-cmd --permanent --policy="$name" --add-egress-zone="$out" >/dev/null; then
      changed "firewalld policy $name egress $out"
    else warn "policy $name: egress $out"; fi
  fi
  if [[ $(firewall-cmd --permanent --policy="$name" --get-target 2>/dev/null || true) != "$target" ]]; then
    if firewall-cmd --permanent --policy="$name" --set-target="$target" >/dev/null; then
      changed "firewalld policy $name target $target"
    else warn "policy $name: target $target"; fi
  fi
}

## Not CIS, NIST SP 800-53 SC-44 (detonation chamber) / SC-39 / CIS Controls v8.1 Control 9:
## random links in a throwaway VM (docs/browsevm.md). Step 1 = its network only: libvirt
## NAT network "browse" on BROWSEVM_BRIDGE, firewalld zone "browsevm" + policies (DHCP + DNS
## to the host, nothing else), hostfw if_vm_iso (tunnel only, never a lab VM or the LAN), kvmlan
## marks (lease with Allow LAN off). Not autostarted: the VM unit starts it (step 3).
sec_browsevm() {
  local zone=browsevm net=browse xml=/etc/browsevm/network.xml want have rule
  if ! command -v virsh >/dev/null || ! command -v firewall-cmd >/dev/null; then
    warn "virsh or firewall-cmd missing - skipped"; return 0
  fi
  [[ $BROWSEVM_BRIDGE =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || { warn "invalid BROWSEVM_BRIDGE - skipped"; return 0; }
  [[ $BROWSEVM_NET =~ ^(10|172\.(1[6-9]|2[0-9]|3[01])|192\.168)(\.[0-9]{1,3}){1,2}$ ]] &&
    [[ $(tr -cd . <<<"$BROWSEVM_NET") == .. ]] ||
    { warn "BROWSEVM_NET must be the first 3 bytes of a private /24 (e.g. 192.168.123) - skipped"; return 0; }
  # an address of that /24 on another interface (home LAN, another libvirt network) = clash
  have=$(ip -4 -o addr show to "$BROWSEVM_NET.0/24" 2>/dev/null | awk -v br="$BROWSEVM_BRIDGE" '$2 != br {print $2, $4}')
  if [[ -n $have ]]; then
    warn "$BROWSEVM_NET.0/24 already used: $have - pick another BROWSEVM_NET"; return 0
  fi

  # firewalld: zone + 2 policies, the same shape as libvirt's own (libvirt.zone,
  # libvirt-nat-out.policy, libvirt-to-host.policy) without ssh / tftp / IPv6:
  # to the host DHCP + DNS only, rest rejected; out = ACCEPT here, hostfw decides where.
  # DNS only to its own bridge address: a service in a policy is open on every host
  # address, so the lab network's dnsmasq (192.168.122.1:53, knows the lab VMs' names)
  # answered the browsing VM too (probe 2026-11-17). The VM's code counts as hostile.
  rule="rule family=\"ipv4\" destination address=\"$BROWSEVM_NET.1\" service name=\"dns\" accept"
  if [[ " $(firewall-cmd --permanent --get-zones) " == *" $zone "* ]]; then
    log "firewalld zone $zone exists"
  else
    firewall-cmd --permanent --new-zone="$zone" >/dev/null ||
      { warn "could not create firewalld zone $zone - skipped"; return 0; }
    log "firewalld zone $zone created"; changed "firewalld zone $zone"
  fi
  fw_policy "$zone-nat-out" "$zone" ANY ACCEPT || return 0
  fw_policy "$zone-to-host" "$zone" HOST REJECT || return 0
  if ! firewall-cmd --permanent --policy="$zone-to-host" --query-service=dhcp >/dev/null 2>&1; then
    if firewall-cmd --permanent --policy="$zone-to-host" --add-service=dhcp >/dev/null; then
      changed "firewalld policy $zone-to-host service dhcp"
    else warn "policy $zone-to-host: dhcp not added"; fi
  fi
  for have in $(firewall-cmd --permanent --policy="$zone-to-host" --list-services); do
    [[ $have == dhcp ]] || {
      firewall-cmd --permanent --policy="$zone-to-host" --remove-service="$have" >/dev/null || true
      log "policy $zone-to-host: service $have removed (dns: own bridge address only, below)"
      changed "firewalld policy $zone-to-host -service $have"; }
  done
  if ! firewall-cmd --permanent --policy="$zone-to-host" --query-rich-rule="$rule" >/dev/null 2>&1; then
    if firewall-cmd --permanent --policy="$zone-to-host" --add-rich-rule="$rule" >/dev/null; then
      changed "firewalld policy $zone-to-host DNS rule"
    else warn "policy $zone-to-host: DNS rule not added"; fi
  fi
  while IFS= read -r have; do
    # ours (also when firewalld writes it back in another spacing / order)
    [[ -z $have || ( $have == *"address=\"$BROWSEVM_NET.1\""* && $have == *"name=\"dns\""* ) ]] && continue
    firewall-cmd --permanent --policy="$zone-to-host" --remove-rich-rule="$have" >/dev/null || true
    log "policy $zone-to-host: rule removed: $have"; changed "firewalld policy $zone-to-host -rule"
  done < <(firewall-cmd --permanent --policy="$zone-to-host" --list-rich-rules)
  log "policy $zone-to-host: DHCP, DNS to $BROWSEVM_NET.1 only, the rest rejected"
  if (( $(section_changes) )); then
    if firewall-cmd --reload >/dev/null; then log "firewalld reloaded (own tables only: hostfw, Mullvad, kvmlan stay)"
    else warn "firewall-cmd --reload failed"; fi
  fi

  # libvirt network: NAT, own bridge in that zone, no autostart, no IPv6
  write_file "$xml" 0644 <<EOF
<!-- harden-workstation.sh browsevm: network of the throwaway browsing VM -->
<network>
  <name>$net</name>
  <forward mode='nat'/>
  <bridge name='$BROWSEVM_BRIDGE' stp='on' delay='0' zone='$zone'/>
  <ip address='$BROWSEVM_NET.1' prefix='24'>
    <dhcp>
      <range start='$BROWSEVM_NET.10' end='$BROWSEVM_NET.20'/>
    </dhcp>
  </ip>
</network>
EOF
  if virsh -q -c qemu:///system net-info "$net" >/dev/null 2>&1; then
    have=$(virsh -q -c qemu:///system net-info "$net" | sed -n 's/^Bridge: *//p')
    if [[ $have != "$BROWSEVM_BRIDGE" ]]; then
      warn "network $net exists with bridge '$have', not $BROWSEVM_BRIDGE - not touched"; return 0
    fi
    log "libvirt network $net exists (bridge $have)"
  else
    virsh -q -c qemu:///system net-define "$xml" >/dev/null ||
      { warn "virsh net-define $xml failed"; return 0; }
    log "libvirt network $net defined"; changed "libvirt network $net"
  fi
  if virsh -q -c qemu:///system net-info "$net" 2>/dev/null | grep -E '^Autostart: *yes' >/dev/null; then
    virsh -q -c qemu:///system net-autostart --disable "$net" >/dev/null 2>&1 || true
    changed "libvirt network $net autostart off"
  fi

  # the other two places that must know the bridge
  if [[ " ${MULLVAD_VM_BRIDGES[*]} " != *" $BROWSEVM_BRIDGE "* ]]; then
    warn "$BROWSEVM_BRIDGE not in MULLVAD_VM_BRIDGES: no lease with Allow LAN off (run kvmlan after fixing)"
  fi
  if nft list set inet hostfw if_vm_iso 2>/dev/null | grep -F "\"$BROWSEVM_BRIDGE\"" >/dev/null; then
    log "hostfw: $BROWSEVM_BRIDGE in if_vm_iso (tunnel only)"
  else
    warn "hostfw live table has no $BROWSEVM_BRIDGE in if_vm_iso: install the new hostfw first"
  fi
  log "start for a test: sudo virsh net-start $net (stop: sudo virsh net-destroy $net)"
}

## Not CIS. sVirt = what the QEMU process of a VM may touch on the host (docs/browsevm.md,
## "SELinux (host)"; NIST SP 800-53 AC-6, SC-39). SELinux booleans that widen it are turned
## off (SVIRT_OFF_BOOLEANS: host USB devices, files on NFS; no VM here uses either), and
## libvirt refuses a domain that asks to run without sVirt (qemu.conf
## security_require_confined = 1; libvirt's default is 0 = <seclabel type='none'/> works).
sec_svirt() {
  local conf=/etc/libvirt/qemu.conf b u on=()
  if ! command -v getsebool >/dev/null || ! command -v selinuxenabled >/dev/null || ! selinuxenabled; then
    warn "SELinux off or its tools missing - skipped"; return 0
  fi
  for b in "${SVIRT_OFF_BOOLEANS[@]}"; do
    [[ $b =~ ^virt_[a-z_]+$ ]] || { warn "SVIRT_OFF_BOOLEANS: '$b' is not a virt_ boolean - left"; continue; }
    case $(getsebool "$b" 2>/dev/null) in
      *"--> on")  on+=("$b=off") ;;
      *"--> off") log "boolean $b is off" ;;
      *)          warn "boolean $b not known to this policy - left" ;;
    esac
  done
  if (( ${#on[@]} )); then
    # one policy rebuild for all of them (-P: kept over reboots)
    if setsebool -P "${on[@]}"; then log "booleans set (persistent): ${on[*]}"; changed "booleans ${on[*]}"
    else warn "setsebool -P ${on[*]} failed"; fi
  fi

  [[ -f $conf ]] || { warn "$conf missing (libvirt QEMU driver not installed?) - skipped"; return 0; }
  if grep -Eq '^[[:space:]]*security_require_confined[[:space:]]*=[[:space:]]*1[[:space:]]*$' "$conf"; then
    log "$conf: security_require_confined = 1"
  else
    set_kv "$conf" security_require_confined 1
    log "$conf: security_require_confined = 1 (a domain without sVirt is refused)"
    # the daemon reads qemu.conf at start; running VMs survive its restart
    for u in virtqemud.service libvirtd.service; do
      if systemctl is-active --quiet "$u"; then
        if systemctl try-restart "$u"; then log "$u restarted"; else warn "$u restart failed"; fi
      fi
    done
  fi
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
  local src gen cfg_changed=0 c0
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
    cfg_changed=1
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
    cfg_changed=1; changed "$conf IPCAllowedGroups="
  fi

  # flash drives: a root owned copy, a root tool never runs from my home
  if cmp -s "$src" "$tool"; then
    log "$tool up to date"
  else
    backup "$tool"
    install -o root -g root -m 0755 "$src" "$tool"
    restorecon -F "$tool" 2>/dev/null || true
    log "installed $tool (flash drive: sudo usb-allow-storage)"; changed "$tool"
  fi

  # GNOME usb-protection off + locked (GNOME default is on)
  if [[ -e $pk ]]; then
    backup "$pk"
    rm -f "$pk"
    log "removed $pk"; changed "removed $pk"
  fi
  grep -qs 'system-db:local' /etc/dconf/profile/user || warn "no system-db:local in /etc/dconf/profile/user: run the gnome section first"
  c0=$(section_changes)
  write_file /etc/dconf/db/local.d/90-usbguard 0644 <<'EOF'
[org/gnome/desktop/privacy]
usb-protection=false
EOF
  write_file /etc/dconf/db/local.d/locks/90-usbguard 0644 <<'EOF'
/org/gnome/desktop/privacy/usb-protection
EOF
  if (( $(section_changes) != c0 )); then
    if dconf update; then log "dconf updated"; else warn "dconf update failed - run: sudo dconf update"; fi
  fi
  if rpm -q usbguard-dbus >/dev/null 2>&1 && [[ $(unit_state usbguard-dbus.service) != masked* ]]; then
    systemctl disable --now usbguard-dbus.service >/dev/null 2>&1 || true
    if systemctl mask usbguard-dbus.service >/dev/null 2>&1; then log "usbguard-dbus masked"; changed "masked usbguard-dbus.service"
    else warn "could not mask usbguard-dbus.service"; fi
  fi
  if rpm -q usbguard-dbus >/dev/null 2>&1; then
    warn "usbguard-dbus not needed: rpm-ostree uninstall usbguard-dbus, reboot"
  fi

  if systemctl is-enabled -q usbguard.service; then
    if (( cfg_changed )); then
      if systemctl restart usbguard.service; then log "usbguard restarted"; else warn "usbguard restart failed"; fi
    fi
    log "usbguard enabled"
  elif systemctl is-active -q usbguard.service; then
    if (( cfg_changed )); then
      systemctl restart usbguard.service
      warn "config changed: usbguard restarted, still NOT enabled - test again, then run again"
      return 0
    fi
    systemctl enable usbguard.service
    log "usbguard enabled (from the next boot too)"; changed "enabled usbguard.service"
  else
    systemctl start usbguard.service
    log "usbguard started, NOT enabled (a reboot turns it off again)"; changed "started usbguard.service"
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
    log "installed $tool"; changed "$tool"
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

## CIS Controls v8.1 7.3, 7.4 (automated OS and application patch
## management): rpm-ostree's own automatic updates (rpm-ostreed.conf AutomaticUpdatePolicy,
## rpm-ostreed-automatic.timer: an hour after boot, then daily). "stage" downloads the new
## deployment with its layered packages (Mullvad VPN, Brave, ...) and leaves it for the next
## boot (ostree-finalize-staged): nothing changes under a running session, the previous
## deployment stays in GRUB (rpm-ostree rollback). Flatpaks: a system unit for system-wide
## installs, a global user unit for each user's own. Both daily, Persistent.
# fwupd: no report to LVFS from any remote (no ReportURI = nothing to send to, even after
# a "yes" by mistake; Automatic*Reports=false). Same edit as admin script 27 (2026-11-16).
fwupd_reports_off() {
  local f new cfg_changed=0
  for f in /etc/fwupd/remotes.d/*.conf; do
    [[ -f $f ]] || continue
    grep -qE '^#?[[:space:]]*(Security)?ReportURI[[:space:]]*=' "$f" || continue
    new=$(sed -E -e 's/^((Security)?ReportURI[[:space:]]*=.*)$/#\1/' \
                 -e 's/^(AutomaticReports|AutomaticSecurityReports)[[:space:]]*=.*$/\1=false/' "$f")
    grep -qE '^AutomaticReports=' <<<"$new" || new+=$'\nAutomaticReports=false'
    grep -qE '^AutomaticSecurityReports=' <<<"$new" || new+=$'\nAutomaticSecurityReports=false'
    if [[ $new == "$(cat "$f")" ]]; then
      log "$f: firmware reports already off"
      continue
    fi
    backup "$f"
    printf '%s\n' "$new" > "$f"
    restorecon -F "$f" 2>/dev/null || true
    log "$f: firmware reports off (no report address, nothing automatic)"
    cfg_changed=1; changed "$f reports off"
  done
  if (( cfg_changed )); then
    systemctl try-restart fwupd.service >/dev/null 2>&1 || true
  fi
}

sec_autoupdate() {
  local conf=/etc/rpm-ostreed.conf
  case $AUTO_UPDATE_POLICY in
    none|check|stage) ;;
    *) warn "AUTO_UPDATE_POLICY '$AUTO_UPDATE_POLICY': none, check or stage (apply reboots by itself: not here) - skipped"; return 0 ;;
  esac
  if command -v rpm-ostree >/dev/null && [[ -f $conf ]]; then
    if grep -Eq "^AutomaticUpdatePolicy=$AUTO_UPDATE_POLICY\$" "$conf"; then
      log "$conf: AutomaticUpdatePolicy=$AUTO_UPDATE_POLICY"
    else
      backup "$conf"
      if grep -Eq '^[#[:space:]]*AutomaticUpdatePolicy[[:space:]]*=' "$conf"; then
        sed -i -E "s|^[#[:space:]]*AutomaticUpdatePolicy[[:space:]]*=.*|AutomaticUpdatePolicy=$AUTO_UPDATE_POLICY|" "$conf"
      elif grep -q '^\[Daemon\]' "$conf"; then
        sed -i "/^\[Daemon\]/a AutomaticUpdatePolicy=$AUTO_UPDATE_POLICY" "$conf"
      else
        printf '[Daemon]\nAutomaticUpdatePolicy=%s\n' "$AUTO_UPDATE_POLICY" >> "$conf"
      fi
      restorecon -F "$conf" 2>/dev/null || true
      log "$conf: AutomaticUpdatePolicy=$AUTO_UPDATE_POLICY"; changed "$conf AutomaticUpdatePolicy=$AUTO_UPDATE_POLICY"
      rpm-ostree reload || warn "rpm-ostree reload failed"
    fi
    if [[ $AUTO_UPDATE_POLICY == none ]]; then
      if [[ $(unit_state rpm-ostreed-automatic.timer) == enabled ]] || systemctl is-active -q rpm-ostreed-automatic.timer; then
        if systemctl disable --now rpm-ostreed-automatic.timer >/dev/null 2>&1; then
          log "rpm-ostreed-automatic.timer off"; changed "disabled rpm-ostreed-automatic.timer"
        else warn "could not disable rpm-ostreed-automatic.timer"; fi
      fi
    elif enable_unit rpm-ostreed-automatic.timer now; then
      log "rpm-ostreed-automatic.timer on (an hour after boot, then daily)"
    else
      warn "could not enable rpm-ostreed-automatic.timer"
    fi
    rpm-ostree status 2>/dev/null | grep -E 'AutomaticUpdates' || true
  else
    warn "no rpm-ostree / $conf: OS updates left as they are"
  fi

  # Firmware: metadata only. Installing (UEFI dbx, device firmware) stays a reviewed
  # admin step (docs/secure-boot.md, Revocation list): fwupd never installs by itself.
  # Reports first: with AutomaticReports=true a plain `fwupdmgr refresh` uploads any
  # unreported update (lessons-learned.md, fwupd).
  if [[ $FIRMWARE_REPORTS == no ]]; then
    fwupd_reports_off
  fi
  if [[ $FIRMWARE_METADATA_REFRESH == yes ]]; then
    if ! unit_exists fwupd-refresh.timer; then
      warn "no fwupd-refresh.timer: firmware metadata left as it is"
    elif ! systemd-analyze calendar "$FIRMWARE_METADATA_CALENDAR" >/dev/null 2>&1; then
      warn "FIRMWARE_METADATA_CALENDAR '$FIRMWARE_METADATA_CALENDAR': not a systemd calendar - timer left as it is"
    else
      local dropin=/etc/systemd/system/fwupd-refresh.timer.d
      local c0
      c0=$(section_changes)
      if [[ -f $dropin/50-once-a-day.conf ]]; then         # name until 2026-11-16
        backup "$dropin/50-once-a-day.conf"
        rm -f "$dropin/50-once-a-day.conf"; changed "removed $dropin/50-once-a-day.conf"
      fi
      write_file "$dropin/50-schedule.conf" 0644 <<EOF
# silverblue-cis-hardening: firmware metadata on a calendar (Fedora's timer: every hour)
[Timer]
OnCalendar=
OnCalendar=$FIRMWARE_METADATA_CALENDAR
EOF
      if (( $(section_changes) != c0 )); then
        systemctl daemon-reload
        systemctl try-restart fwupd-refresh.timer >/dev/null 2>&1 || true
      fi
      if enable_unit fwupd-refresh.timer now; then
        log "fwupd-refresh.timer on ($FIRMWARE_METADATA_CALENDAR, firmware metadata only, nothing installed)"
      else
        warn "could not enable fwupd-refresh.timer"
      fi
    fi
  fi

  if [[ $FLATPAK_AUTO_UPDATE != yes ]]; then
    log "FLATPAK_AUTO_UPDATE=$FLATPAK_AUTO_UPDATE: Flatpak updates left as they are"; return 0
  fi
  command -v flatpak >/dev/null || { warn "no flatpak: skipped"; return 0; }
  write_file /etc/systemd/system/flatpak-update-system.service 0644 <<'EOF'
# harden-workstation.sh autoupdate: system-wide Flatpaks
[Unit]
Description=Update system Flatpaks
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/flatpak update --system --noninteractive --assumeyes
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=1h
EOF
  write_file /etc/systemd/system/flatpak-update-system.timer 0644 <<'EOF'
# harden-workstation.sh autoupdate
[Unit]
Description=Daily update of system Flatpaks

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
OnBootSec=20min

[Install]
WantedBy=timers.target
EOF
  write_file /etc/systemd/user/flatpak-update-user.service 0644 <<'EOF'
# harden-workstation.sh autoupdate: this user's own Flatpaks (--user installs)
[Unit]
Description=Update my Flatpaks

[Service]
Type=oneshot
ExecStart=/usr/bin/flatpak update --user --noninteractive --assumeyes
Nice=10
EOF
  write_file /etc/systemd/user/flatpak-update-user.timer 0644 <<'EOF'
# harden-workstation.sh autoupdate
[Unit]
Description=Daily update of my Flatpaks

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
OnBootSec=20min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  if enable_unit flatpak-update-system.timer now; then
    log "flatpak-update-system.timer on (daily)"
  else
    warn "could not enable flatpak-update-system.timer"
  fi
  if [[ $(systemctl --global is-enabled flatpak-update-user.timer 2>/dev/null || true) == enabled ]]; then
    log "flatpak-update-user.timer on for every user"
  elif systemctl --global enable flatpak-update-user.timer >/dev/null 2>&1; then
    log "flatpak-update-user.timer on for every user (from their next login)"; changed "enabled flatpak-update-user.timer (global)"
  else
    warn "could not enable flatpak-update-user.timer globally"
  fi
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
  if (( $(section_changes) == 0 )); then return 0; fi
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
#   init_on_free=1: freed memory is zeroed at once (a use-after-free or an uninitialized
#   read finds zeros, not old data). Fedora sets init_on_alloc only.
#   iommu.strict=1: a device loses DMA access to a buffer as soon as the driver unmaps
#   it (the default lazy mode batches the IOTLB flush: a short window).
#   Both after a 4-day trial (2026-11-03 to 2026-11-07, tools/kargs-bench.sh): no felt
#   slowdown (desktop, Steam), podman start +0.08 s, IOMMU faults 0.
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
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  echo "Sections: ${SECTIONS[*]}"
}

# on_err: a command failed (set -e; -E: inside functions too). Says where, then the run
# stops (EXIT trap: summary). Command substitutions and pipeline parts run in a subshell:
# the line in the parent shell is reported (the subshell's command can mislead: under
# pipefail the last command of a pipe, not the one that failed)
on_err() {
  local rc=$1 line=$2 cmd=$3 fn=${FUNCNAME[1]:-main}
  (( BASH_SUBSHELL == 0 )) || return 0
  printf '\e[31m[x]\e[0m STOP: section %s, %s line %s, exit %s: %s\n' \
    "${CUR_SECTION:-none}" "$fn" "$line" "$rc" "$cmd" >&2
}

# on_exit: every end of a run (done, die, error): what each section changed, where it
# stopped, what did not run, the backups (none: no folder)
on_exit() {
  local rc=$1 s n total=0 i
  trap - ERR
  if [[ -z $CHANGE_LOG ]]; then exit "$rc"; fi
  printf '\n\e[1m== summary ==\e[0m\n'
  for s in "${DONE_SECTIONS[@]}"; do
    n=$(section_changes "$s"); total=$((total + n))
    if (( n )); then printf '  %-12s %s change(s)\n' "$s" "$n"; else printf '  %-12s no change\n' "$s"; fi
  done
  if (( rc != 0 )) && [[ -n $CUR_SECTION ]]; then
    n=$(section_changes "$CUR_SECTION"); total=$((total + n))
    printf '  %-12s STOPPED (exit %s), %s change(s) before the stop\n' "$CUR_SECTION" "$rc" "$n"
    for i in "${!RUN_LIST[@]}"; do
      [[ ${RUN_LIST[i]} == "$CUR_SECTION" ]] || continue
      if (( i + 1 < ${#RUN_LIST[@]} )); then printf '  not run: %s\n' "${RUN_LIST[*]:i+1}"; fi
      break
    done
  fi
  if [[ -d $BACKUP_ROOT ]]; then
    printf 'Backups: %s\n' "$BACKUP_ROOT"
  else
    printf 'Backups: none (nothing replaced or removed)\n'
  fi
  if (( rc == 0 && total > 0 )); then
    printf 'Reboot recommended (kernel modules, sysctl one-way switches, PAM).\n'
  elif (( rc != 0 )); then
    printf 'Stopped: fix the cause, then run the stopped section and the ones not run (undo: docs/rollback.md).\n'
  fi
  rm -f "$CHANGE_LOG"
  exit "$rc"
}

RUN_LIST=()

main() {
  if [[ $# -eq 0 || ${1:-} == --list || ${1:-} == -h ]]; then usage; exit 0; fi
  [[ $EUID -eq 0 ]] || die "run with sudo"
  if [[ -z $TARGET_USER ]]; then warn "SUDO_USER is empty - user-specific steps will be skipped"; fi
  run_sections "$@"
}

# run_sections <section>... | all: each section and its changes; the summary comes when the
# shell ends (EXIT trap). A failed command stops the run (on_err: section, line, command)
run_sections() {
  local s n
  RUN_LIST=("$@")
  if [[ ${RUN_LIST[0]} == all ]]; then RUN_LIST=("${SECTIONS[@]}"); fi
  CHANGE_LOG=$(mktemp)
  # two runs in the same second: own folder (the summary looks for this run's folder)
  if [[ -e $BACKUP_ROOT ]]; then BACKUP_ROOT+="-$$"; fi
  trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
  trap 'on_exit $?' EXIT

  for s in "${RUN_LIST[@]}"; do
    printf '\n\e[1m== %s ==\e[0m\n' "$s"
    CUR_SECTION=$s
    case $s in
      sysctl)      sec_sysctl ;;
      modules)     sec_modules ;;
      coredump)    sec_coredump ;;
      journald)    sec_journald ;;
      gnome)       sec_gnome ;;
      sudo)        sec_sudo ;;
      pam)         sec_pam ;;
      pwage)       sec_pwage ;;
      su)          sec_su ;;
      accounts)    sec_accounts ;;
      services)    sec_services ;;
      guesttools)  sec_guesttools ;;
      loopback)    sec_loopback ;;
      cron)        sec_cron ;;
      sshd)        sec_sshd ;;
      auditd)      sec_auditd ;;
      audit-rules) sec_audit_rules ;;
      perms)       sec_perms ;;
      mic)         sec_mic ;;
      netprivacy)  sec_netprivacy ;;
      mullvad)     sec_mullvad ;;
      kvmlan)      sec_kvmlan ;;
      browsevm)    sec_browsevm ;;
      svirt)       sec_svirt ;;
      usbguard)    sec_usbguard ;;
      appunit)     sec_appunit ;;
      time)        sec_time ;;
      autoupdate)  sec_autoupdate ;;
      kargs)       sec_kargs ;;
      *)           warn "unknown section: $s" ;;
    esac
    n=$(section_changes)
    if (( n )); then
      log "$s: $n change(s):"
      awk -F '\t' -v s="$s" '$1 == s && !seen[$0]++ { print "      " $2 }' "$CHANGE_LOG"
    else
      log "$s: no change"
    fi
    if [[ " ${SECTIONS[*]} " == *" $s "* ]]; then DONE_SECTIONS+=("$s"); fi
    CUR_SECTION=""
  done
}

# run when executed; tests source the file for its functions
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
