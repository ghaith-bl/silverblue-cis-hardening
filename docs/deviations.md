# Deviations from CIS Fedora L2 Workstation

Rules intentionally **not** applied (or applied differently), with the reason.
Input for an OpenSCAP tailoring file.

## Would break this machine

| Rule | Decision | Reason |
|------|----------|--------|
| `kernel_module_overlayfs_disabled` | skip | Silverblue composefs is built on overlayfs + EROFS; Podman/toolbox also need it |
| `xwayland_disabled` | skip | Steam client and most games run on X11 via XWayland |
| `sysctl_net_ipv4_ip_forward`, `..._conf_all_forwarding`, `..._conf_default_forwarding` | skip | libvirt NAT (`virbr0`) and rootful Podman need IPv4 forwarding |
| `sysctl_net_ipv4_conf_all_rp_filter`, `..._default_rp_filter` | set `2` (loose) | strict mode can drop WireGuard traffic; NetworkManager itself switches to loose on multihomed hosts |
| `package_dnsmasq_removed` | skip | libvirt default network DHCP/DNS |
| `package_httpd_removed`, `package_rsync_removed` | skip | part of the base image, not running, not removable without `rpm-ostree override remove` |
| `kernel_module_usb-storage_disabled` | skip (option) | USB drives still needed; `DISABLE_USB_STORAGE=yes` to apply |

## Not useful on a single-user laptop

| Rule | Decision | Reason |
|------|----------|--------|
| `accounts_tmout` | skip | GNOME idle lock (15 min, locked) covers it |
| `banner_etc_issue_cis`, `banner_etc_issue_net_cis`, `dconf_gnome_banner_enabled`, `dconf_gnome_login_banner_text`, `sshd_enable_warning_banner_net` | skip | legal banners - value in organisations, not on a personal device |
| `package_systemd-journal-remote_installed` | skip | needs a log server on a second device; none now |
| `accounts_passwords_pam_faillock_even_deny_root_or_root_unlock_time` | skip | root account is locked; `su` restricted to an empty group |
| `ensure_root_password_configured` | skip | root is locked; emergency shell refuses access instead of opening unauthenticated |
| `service_bluetooth_disabled` | skip | service already disabled manually; masking optional |

## Two accounts (accounts section, 2026-11-05)

| Rule | Decision | Reason |
|------|----------|--------|
| `account_disable_post_pw_expiration` | skip | locks an account some days after its password expired: root is locked and the admin is the only sudo account, so an expired admin would mean no sudo at all (recovery from a live USB) |
| admin password | memorized + offline copy (paper / phone password manager), never in storage the daily user opens, never typed in GNOME | a keylogger or a password manager in the daily session must not get it |
| admin home lock (not CIS, 2026-11-18) | shell start files = `accounts/admin.*` (PATH only from root-owned dirs, no `~/.bashrc.d`), `chattr +i`; the top of the home, `.config`, `.local`, `.local/share` `chattr +i`, also `.config/systemd`, `.local/share/systemd` (timer stamps), `.local/share/flatpak` if present (no `user/` units, no `exports/` on `XDG_DATA_DIRS`); `.profile`, `.bash_login`, `.bash_completion`, `.i18n`, `.config/bash_completion` removed (backup first) | scripts from the daily session run as the admin (after review in `tools/admin-run.sh`); one that got through could plant an alias, a function or a PATH entry for `sudo` and catch the password at the next sudo. Bash reads the start files, `/etc/profile.d/lang.sh` reads `~/.i18n`, bash-completion sources `~/.bash_completion` and `~/.config/bash_completion` and loads completions from `~/.local/share/bash-completion`: none can be planted now (nothing new at those levels). Cost: the admin creates nothing new there and changes its shell files only with `sudo chattr -i`; a tool that wants a new history / config file there (less, nano) cannot save it; a full SELinux relabel cannot relabel the locked items (labeled when locked). Folders already inside stay writable: `tools/check-accounts.sh` lists them and fails on known places that run code (`user/` units, completions, git config, flatpak `exports/`). Not covered: a process the script left running until logout / reboot, the admin's own clones ([THREAT_MODEL.md](THREAT_MODEL.md), planned) |
| `accounts_user_dot_user_ownership`, `accounts_user_dot_group_ownership` | applied: the admin's start files stay owned by the admin and its group (CIS 7.2.9) | root as owner would add nothing: in a home the admin owns, it can rename a root-owned file and put its own in its place; `chattr +i` blocks write, rename, delete and chmod even for the owner (tested 2026-11-18) |
| GDM login methods (not CIS, 2026-11-18) | password only: `enable-switchable-authentication`, `enable-passkey-authentication`, `enable-web-authentication` (GDM 50; 51 dropped the last two), `enable-smartcard-authentication` false and locked in dconf `gdm`; `enable-fingerprint-authentication` too with `FINGERPRINT=disable` | only `gdm-password` refuses the admin; `gdm-switchable-auth`, `gdm-smartcard`, `gdm-fingerprint` use authselect stubs (`pam_debug auth=authinfo_unavail`) that refuse every user, `gdm-autologin` is unused (no automatic login in `/etc/gdm/custom.conf`): `tools/check-accounts.sh` checks each. The locked keys keep GDM off those services if a later authselect profile gives them a real stack. Cost: none here (no reader, no smart card, no passkey login) |

## Passwords: CIS on purpose (decision 2026-11-17)

NIST SP 800-63B-4: no periodic change, no composition rules, 15 chars for a password used
alone. This repo follows CIS on purpose (the benchmark is the measure). On any sign of
compromise: change the password at once (`sudo passwd <user>` works the same day too).

| Rule | Decision | Reason |
|------|----------|--------|
| `accounts_password_pam_minlen` | `15` (`pam`; CIS `14`) | NIST SP 800-63B-4 minimum for a password used alone; checked at the next change, not on the passwords set now |
| `accounts_password_pam_minclass` | `4` (`pam`) | CIS; NIST: no composition rules |
| `accounts_maximum_age_login_defs`, `accounts_password_set_max_life_existing` | applied: 365 days, warning 14 (`pwage`) | CIS; NIST: no periodic change. I change both passwords about every six months anyway; the max only catches a forgotten change |
| `accounts_minimum_age_login_defs`, `accounts_password_set_min_life_existing` | applied: 1 day (`pwage`, since 2026-11-18) | CIS; without it pwhistory (24) is cosmetic: 24 changes in a row bring the old password back. Cost: no second change of my own password the same day; root can (`sudo passwd <user>`) |

## Changed on purpose

| Rule | Decision | Reason |
|------|----------|--------|
| `sysctl_kernel_kptr_restrict` | set `2` | stricter than the CIS value `1` (hidden from root too) |
| `sysctl_kernel_yama_ptrace_scope` | set `3` (decision `PTRACE_SCOPE`, 2026-11-16; `2` since 2026-10-30) | no attach for anyone, root included (KSPP); `2` was admin-only attach, idea from secureblue. CIS RHEL 9 v3.0.0 accepts `1`, `2` or `3` and recommends `2`; RHEL 9 STIG (RHEL-09-213080) wants exactly `1`: finding there. Scanner fails if its profile value is `1`. Why 3: closes the easiest way for root (or malware that got root) to read or change a running program's memory (ptrace, /proc/<pid>/mem, process_vm_readv: keyring, browser secrets) and makes the rest harder; root still has other ways (run as the user and ask its Secret Service, eBPF, uprobes, change the sysctl file and reboot): against root this setup detects, it does not prevent (THREAT_MODEL.md). Programs that only read /proc (sectop, ps, btop, osquery, auditd) are not affected: Yama checks attach only. Cost: `gdb` / `strace` / `ltrace` / CRIU (`podman container checkpoint`) do not work, not even with sudo: use them in the lab VMs (own kernel; toolbox shares this one). Anti-cheat games need ptrace (none here). One-way until reboot. Undo: `PTRACE_SCOPE=2`, sysctl section, reboot |
| `auditd_data_disk_full_action`, `auditd_data_retention_admin_space_left_action` | `SUSPEND` | CIS `HALT`/`SINGLE` would stop a laptop when the disk fills |
| `auditd_data_retention_space_left_action` | `SYSLOG` | no local MTA for `EMAIL` |
| `auditd_data_retention_max_log_file_action` | keep `ROTATE` | CIS `KEEP_LOGS` has no limit; `/var` also holds `/var/home` |
| `auditd_data_retention_max_log_file`, `auditd_data_retention_num_logs` | `32` MiB x `40` files | ring >= 1 week (DISA STIG RHEL 9 V-258155). 2026-10-20: measured 2.3 MiB/h with sectop mostly closed, estimated 6.6 MiB/h with sectop polling as root every 6 s (before its privilege split; sectop runs no root commands now) |
| `audit_rules_dac_modification_*` (14), `audit_rules_file_deletion_events_*` (5), `audit_rules_unsuccessful_file_modification_*` (5) | off by default | thousands of events/hour from Steam and Brave caches; `ENABLE_NOISY_AUDIT=yes` to apply |
| `audit_rules_time_clock_settime` | `subj_type!=chronyd_t` filter | chronyd adjusts the clock constantly |
| `accounts_password_pam_modules_in_authselect_profile` | keep Fedora's authselect profile `local` | the rule wants a custom profile copied from `local`; the PAM lines would be the same (faillock, pwhistory, pwquality: features of `local`, set by the `pam` section). A copy gets no fixes from Fedora's updates of `local`, and a broken custom profile can lock out the only sudo account (root is locked). Decision 2026-11-09 |

## Scanner false positives on Silverblue (verified manually)

| Rule | Why it fails | Verification |
|------|--------------|--------------|
| `grub2_audit_argument`, `grub2_audit_backlog_limit_argument` | checks GRUB files; Silverblue sets kargs via `rpm-ostree kargs` | `grep -o 'audit[^ ]*' /proc/cmdline` |
| `audit_rules_kernel_module_loading_create`, `..._query` | `create_module` / `query_module` do not exist on x86_64 | - |
| `ensure_fedora_gpgkey_installed` | ostree verifies commits with its own remote keys | `grep -r gpg-verify /etc/ostree/remotes.d/` |
| `package_cron_installed` | `cronie` is layered | `rpm -q cronie` |
| `sysctl_fs_suid_dumpable` | another value in `/usr/lib/sysctl.d/`; ours (`90-hardening.conf`) loads last. `yama_ptrace_scope`: see Changed on purpose | `sysctl fs.suid_dumpable` -> `0` |
| `file_groupownership_sshd_private_key` | Fedora uses group `ssh_keys` by design | - |
| `sshd_*` | sshd is masked; hardened drop-in present | `systemctl is-enabled sshd` -> `masked` |
| `accounts_password_pam_unix_authtok` | its check reads `/etc/pam.d/common-password`, a Debian path that Fedora does not have | `grep use_authtok /etc/pam.d/system-auth /etc/pam.d/password-auth` |
| 16 `audit_rules_*` (execution, mac / networkconfig modification, privileged commands, suid_auid, sysadmin, pam.d) | rules loaded, different text format than the scanner regex | `sudo auditctl -l`, `ausearch -k <key>` |

## Rootless container storage (scan 2026-11-09)

| Rule | Decision | Reason |
|------|----------|--------|
| `no_files_or_dirs_unowned_by_user`, `no_files_or_dirs_ungroupowned`, `file_permissions_unauthorized_world_writable`, `dir_perms_world_writable_sticky_bits` | skip | every hit is in the daily user's home: the rootless Podman volume of my kind lab (node `kind-control-plane`). Inside, files belong to subordinate uids / gids (no passwd entry) and keep the container's own modes (world-writable dirs of the node image). The home is 0700: no other user reaches them. The scanner walks `/var/home` fully. Gone with the lab: `kind delete cluster` |

## Mullvad VPN (replaced Proton VPN 2026-10-26, docs/mullvad.md)
- mullvad-daemon runs as root (owns its nftables table, routes, DNS). Package unit,
  not changed.
- Management socket: only group `mullvad` (mullvad section, 2026-11-02). Mullvad's
  default: any local user can connect, disconnect and change settings.
- The RPM ships the GUI too (one package). Not started, no autostart.
- API access: only "Direct" enabled; "Mullvad Bridges" and "Encrypted DNS proxy" disabled
  (2026-10-27). My design, not from Mullvad, CIS or Red Hat docs. Why: hostfw allows the
  daemon outside the tunnel only for Direct (`vpn_api4`, root tcp/443), least privilege:
  one known flow. With all three on, the daemon switches to a method hostfw always
  blocks (seen 2026-10-27) -> OUT-LEAK noise, slower fallback to Direct, no gain.
  Cost: no automatic fallback if a network blocks the API address or Mullvad changes it.
  Escape: `sudo hostfw observe`, then fix `vpn_api4` in
  /etc/hostfw/local.conf. Undo: `mullvad api-access enable 2`
  / `enable 3` (then hostfw must mirror what `inet mullvad` allows, see README Planned).
- Lockdown mode + hostfw boot mode enforce: no internet outside the tunnel from boot,
  also while disconnected.
- No DNS servers on Wi-Fi / cable profiles (netprivacy, 2026-10-31). Problem: 2 profiles
  had a static public resolver; resolved used it while the tunnel had no DNS (reconnect):
  20 queries uid 990 out of the tunnel, blocked by hostfw (`out_dns`), not a leak.
  Cost: no DNS without the tunnel (captive portals: already closed by lockdown). New
  networks get DHCP DNS: run netprivacy again.
- hostfw: enforce from boot, out_noscope (GNOME Shell's cgroup) enforce too. Observe
  findings and history: firewall/docs/observe-log.md.
- VMs with Allow LAN off (kvmlan section, 2026-11-04). Problem: Mullvad's LAN block also
  covers `virbr0`: no DHCP lease in the VMs, host -> VM ssh refused at once (found
  2026-11-04, Mullvad since 2026-10-26; `mullvad lan get` = block, hostfw logged nothing).
  Not Allow LAN: it opens every private range on every network (zero trust LAN).
  Instead: own table `inet kvmlan`, Mullvad's documented split tunneling marks
  (ct mark 0xf41 + mark 0x6d6f6c65) on host <-> VM packets of `virbr0` only, input
  + route output at priority -100 (Mullvad: between -200 and 0, lower leaks the tunnel
  address). Marks only, no accept / drop; Mullvad's own table not touched.
  Still guarded: firewalld zone `libvirt` (what a VM may reach on the host), hostfw
  forward (VM -> tunnel only), Mullvad's forward chain. VM internet = forwarded traffic,
  never marked. A host program sending to `virbr0` only reaches the VMs.
  Tested 2026-11-04 (runtime table): VM lease + ping to a public address OK; in the VM
  `curl https://am.i.mullvad.net/connected` = connected; `mullvad disconnect` -> same VM
  ping `Packet filtered` from the host's `virbr0` address, 100 % loss; `mullvad connect`
  -> back.
  Cost: hand-written marks are Mullvad's "privacy danger" area: a wrong rule can leak;
  keep the file as tested. A new libvirt network: its bridge in `MULLVAD_VM_BRIDGES` and
  in hostfw `if_vm` / `if_trusted`. Undo: `sudo systemctl disable --now kvmlan`.
- Throwaway browsing VM (browsevm section, 2026-11-12, design: docs/browsevm.md). Not CIS;
  NIST SP 800-53 SC-44 (detonation chamber), SC-39, CIS Controls v8 Control 9. Goal:
  random links never reach the daily user's files or the system. A third local user was
  rejected: same kernel, a browser exploit + kernel LPE owns the host.
  Network (step 1): own libvirt network `browse` on `virbr-browse`, not `default`: hostfw
  accepts virbr0 <-> virbr0 (`fwd_vm_cross`, lab VMs talk to each other); `if_vm_iso`
  = tunnel only, no new flow to or from another bridge or the uplink (counter / log
  `fwd_vm_lan`, rule comment `fwd_vm_iso`). firewalld: zone `browsevm` + policies
  `browsevm-nat-out` (ACCEPT, hostfw decides where) and `browsevm-to-host` (REJECT, DHCP +
  DNS to its own bridge address only: the VM's code counts as hostile), the shape of
  libvirt's own zone / policies without ssh, tftp, IPv6. kvmlan marks for the bridge
  (lease with Allow LAN off). Not autostarted.
  Inside the VM (choices, docs/browsevm.md):
  - Mullvad Browser as shipped (no policy of ours: the same look as its other users),
    security level Safer at every start; NoScript applies it, its button stays hidden
    (the browser's default). Brave as the second browser (a site that breaks in Mullvad
    Browser): managed policies, JIT / V8 optimizers off (its "Safer"), no extension,
    nothing sent by itself
  - kiosk (cage + browser) as the confined SELinux user `user_u` (user_t), not the
    unit's domain; `NoNewPrivileges` on top
  - base image updated by itself: rebuilt from the kept ISO when 7 days old
    (`browsevm-update.timer`), not by hand. Nothing in the VM updates itself (every start
    is the base again); a new base = newest Fedora packages and both browsers
  On the host, the window (beta, 2026-11-18): remote-viewer only through an own Wayland
  relay (GTK 3 ends the viewer when GNOME Shell reads late) and inside a bwrap sandbox (no
  network, no home, no session bus, no devices, only its three sockets). Cost: a Python
  relay in the display path, user namespaces needed for the sandbox (already on), the
  sound socket can record other programs' sound. `BROWSEVM_RELAY=0` /
  `BROWSEVM_SANDBOX=0` turn one off per start

## Brave: RPM, not Flatpak (not CIS)
- Brave's own RPM repo, layered (browsers/README.md). Why: Brave's own build with the
  browser's own sandbox, fully native; Brave recommends its repos over the Flathub
  build, which changes Chromium sandboxing in ways not reviewed by Brave or Chromium.
- Cost: no Flatpak file limits (the browser runs as my user, whole home readable);
  updates only with an rpm-ostree deployment + reboot -> update often.
- Repo: `gpgcheck=1` + `repo_gpgcheck=1` (signed metadata, refresh OK 2026-11-02), the
  3 key fingerprints match brave.com/signing-keys.

## USBGuard: rules.conf only, flash drives by hand (not CIS, usbguard section, 2026-11-03)
- What: only devices in rules.conf work, locked or unlocked, before login too. A flash
  drive: `sudo usb-allow-storage` allows one blocked device until it is unplugged, only if
  every interface is mass storage (08). A "flash drive" that is also a keyboard / mouse /
  network adapter (BadUSB) is refused.
- Why not GNOME usb-protection (tried 2026-11-02): unlocked it allows every new device
  (temporary `allow id *:*`), locked it still allows HID-only devices and hubs. It needs
  usbguard-dbus + a polkit rule that lets a program running as me change USB decisions
  without a password. Now off (locked), no polkit rule, usbguard-dbus masked (not needed).
- Cost: every flash drive = one command + sudo password. Fine: drives are rare here.
- Storage only does not mean safe files: no automount (gnome section), do not run files
  from unknown drives. Behind a hub nothing shows up (the hub is blocked): plug in directly.
- `usb-allow-storage` reads `usbguard list-devices --blocked` with every quoted value
  emptied first, so a device name or serial cannot fake the interface list. Installed root
  owned in /usr/local/sbin: a root tool never runs from my home.
- rules.conf: generated once from the devices present (`usbguard generate-policy`), never
  overwritten. The internal keyboard is a USB device: without its rule, no keyboard
  before login. External keyboard / mouse: `sudo usbguard append-rule` from its
  list-devices line (id, name, hash, interfaces, connect type; no serial, no port).
- Bluetooth adapter: `block` (not used). Back: change `block` to `allow` in rules.conf,
  restart usbguard.
- usbguard CLI: root only (`IPCAllowedGroups=` empty; Fedora default lets wheel change
  rules without a password).

## Kernel args (not CIS)
- `initcall_blacklist=af_alg_init` (kargs section, 2026-11-01): AF_ALG never starts.
  Why: user-space door into the kernel crypto code, deprecated upstream for its attack
  surface; CVE-2026-31431 (Copy Fail, local root) was in algif_aead. The usual
  mitigation blocks `algif_aead_init` only; `af_alg_init` closes the whole family.
  Measured first: audit rule `af-alg` (socket family 38, b64 + b32) 2 days, 0 programs.
  LUKS2 `aes-xts-plain64` + `argon2id`, cryptsetup 2.8.8: unlocks without it (userspace
  library). Test boot 2026-11-01: LUKS unlock OK, `socket(AF_ALG)` errno 97.
  Cost: no Adiantum / Serpent / Twofish LUKS volumes, no BlueZ mesh, no iwd, no
  `cryptsetup benchmark` for ciphers. Undo: `rpm-ostree kargs --delete=...`, reboot.
- Audit rule `af-alg` kept after the block: every hit is a failed try (a program that
  needs it, or a probe). My design, not from CIS or Red Hat. Rules: ~72 (73 with
  `mullvad-exclude` in the setuid list, 2026-11-01).
- `page_alloc.shuffle=1` (kargs, 2026-11-01): random page allocator free lists. Built in
  (`CONFIG_SHUFFLE_PAGE_ALLOCATOR`), off by default. Cost: none expected.
- `rd.shell=0 rd.emergency=halt` (kargs, 2026-11-01): initramfs failure halts, no root
  shell (may run after the LUKS unlock). Needs the GRUB password (CIS `grub2_password`,
  set by hand with `grub2-setpassword`, user `root`): without it the menu edits them
  away. Normal boot and older entries ask nothing; edit (`e`), command line (`c`) and
  the firmware entry ask. Cost: no shell to debug a broken boot; fix = previous GRUB
  entry (`rpm-ostree rollback`) or `e` + password, remove the args for one boot.
  Host 2026-11-02: args in /proc/cmdline, shuffle `Y`, GRUB password asked on `e` only.
  The halt path itself not tested (a wrong LUKS password only waits, as before: no shell
  on that path anyway). Test idea: `e`, break the `ostree=` path, unlock -> must halt.
- Source of the kargs ideas: secureblue default kargs (compared 2026-10-30), minus what
  the Fedora kernel config already does. Not taken: `ia32_emulation=0` (Steam),
  `nosmt` (half the cores), `vsyscall=none` (kernel already xonly). `module.sig_enforce`
  first left out (lockdown integrity does it), taken 2026-11-16: see below.
- `init_on_free=1 iommu.strict=1` (kargs, 2026-11-07, after a trial from 2026-11-03):
  freed pages zeroed at once; IOTLB flushed on every DMA unmap (no lazy window).
  Kernel docs: init_on_free costs 3-5 % typical, up to 8 %. Measured with
  tools/kargs-bench.sh (before / after / end): boot 41.1 / 37.8 / 39.0 s, memory free
  0.78 / 0.68 / 0.66 s, small files 0.17 / 0.18 / 0.17 s, podman run 0.28 / 0.36 /
  0.35 s, O_DIRECT 2 GiB read noisy (1.0 - 3.3 s), IOMMU faults 0, no felt slowdown in
  4 days (desktop, Steam on the iGPU). Undo: `rpm-ostree kargs --delete=...`, reboot.

## Kernel attack surface (not CIS: KSPP, 2026-11-16)

Measured first: kernel-hardening-checker v0.6.17.1 (a13xp0p0v, KSPP / CLIP OS / grsecurity
recommendations) on the host's kconfig, /proc/cmdline and `sysctl -a`: OK 208, FAIL 144.
Most FAIL rows are Fedora build options (signed Fedora kernel, not changed here). Taken:

- sysctl section: `kernel.io_uring_disabled = 2` (RHEL >= 9.3 ships it; Google: 60 % of the
  kernel exploits in its 2022 bounty used io_uring, off on ChromeOS and its servers; no
  process held an io_uring fd on 2026-11-15), `dev.tty.ldisc_autoload = 0`,
  `fs.protected_fifos = 2`, `fs.protected_regular = 2`, `kernel.sysrq = 0`,
  `kernel.warn_limit = 100`, `kernel.oops_limit = 100` (kept journal 2026-08 .. 11: no WARN /
  Oops line at all), `vm.mmap_rnd_bits = 32`, `vm.mmap_rnd_compat_bits = 16` (kernel
  maximum; 32-bit Steam client and games: test after the reboot).
- Audit rule `io-uring` (b64 + b32 `io_uring_setup`): every hit is a refused try. Rules: 74 on 2026-11-16 (47 + 27 setuid programs), 73 after `guesttools` (2026-11-17: 26).
- kargs: `hash_pointers=always` (hashed %p in every log, also for root),
  `proc_mem.force_override=never` (no write to read-only memory of a process through
  /proc/<pid>/mem; debuggers may break), `module.sig_enforce=1` (signed modules only even
  if Secure Boot is switched off in the firmware and lockdown with it), `intel_iommu=on`
  (on now only through the firmware's DMA opt-in flag; `CONFIG_INTEL_IOMMU_DEFAULT_ON` is
  not set), `debugfs=off` (`CONFIG_DEBUG_FS_ALLOW_ALL=y`; lockdown already limits it),
  `bdev_allow_write_mounted=0` (no direct writes to a block device with a mounted
  filesystem). Undo: `rpm-ostree kargs --delete=...`, reboot.

Not taken:

| Checker row | Why |
|-------------|-----|
| `spectre_v2`, `mds`, `l1tf` ... `vmscape` (16 cmdline rows "is off, not found") | false positive: kconfig has `CONFIG_CPU_MITIGATIONS=y` and every `CONFIG_MITIGATION_*=y`; nothing turns them off on the command line |
| `user.max_user_namespaces = 0` | Flatpak (bwrap), rootless Podman / kind, Brave's sandbox, glycin image loaders and systemd services with `PrivateUsers=` use them (12 processes, 5 namespaces on 2026-11-15) |
| `kernel.modules_disabled = 1` | flash drives and libvirt load modules after boot |
| `mitigations=auto,nosmt`, `nosmt` | half the threads of the P-cores |
| `ia32_emulation=0` | Steam client and many games are 32-bit |
| `vsyscall=none` | kernel default `xonly` already; old binaries / games, later |
| `pti=on` | auto mode turns it on where the CPU needs it; check `/sys/devices/system/cpu/vulnerabilities/meltdown` |
| `lockdown=confidentiality` | now `integrity` (Secure Boot); confidentiality also blocks kernel memory reads by tracing / eBPF tools: decide with sectop's monitoring plans |
| `cfi=kcfi` | kernel built without `CONFIG_CFI` (IBT is on) |
| `kernel.perf_event_paranoid = 3` | needs a distro patch the Fedora kernel does not carry: no effect |
| `efi=disable_early_pci_dma` | some machines do not boot with it: own trial later, alone |
