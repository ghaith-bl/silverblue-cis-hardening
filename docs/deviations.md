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
| `accounts_minimum_age_login_defs`, `accounts_password_set_min_life_existing` | skip | NIST SP 800-63B advises against forced periodic password changes (max age: Two accounts) |
| `accounts_tmout` | skip | GNOME idle lock (15 min, locked) covers it |
| `banner_etc_issue_cis`, `banner_etc_issue_net_cis`, `dconf_gnome_banner_enabled`, `dconf_gnome_login_banner_text`, `sshd_enable_warning_banner_net` | skip | legal banners - value in organisations, not on a personal device |
| `package_systemd-journal-remote_installed` | skip | needs a log server on a second device; none now |
| `accounts_passwords_pam_faillock_even_deny_root_or_root_unlock_time` | skip | root account is locked; `su` restricted to an empty group |
| `ensure_root_password_configured` | skip | root is locked; emergency shell refuses access instead of opening unauthenticated |
| `service_bluetooth_disabled` | skip | service already disabled manually; masking optional |

## Two accounts (accounts section, 2026-11-05)

| Rule | Decision | Reason |
|------|----------|--------|
| `accounts_maximum_age_login_defs` (`PASS_MAX_DAYS` <= 365), `accounts_password_set_max_life_existing` | admin and daily user: no expiry (`chage -M 99999`) | NIST SP 800-63B (memorized secrets): no forced periodic change, change on compromise; CIS Password Policy Guide (2023) agrees for long passwords. A forced change pushes to weaker or written-down admin passwords. Change it when there is any sign of compromise |
| `account_disable_post_pw_expiration` | skip | with no expiry it never triggers; root locked, the admin is the only sudo account |
| admin password | memorized + offline copy (paper / phone password manager), never in storage the daily user opens, never typed in GNOME | a keylogger or a password manager in the daily session must not get it |

## Changed on purpose

| Rule | Decision | Reason |
|------|----------|--------|
| `sysctl_kernel_kptr_restrict` | set `2` | stricter than the CIS value `1` (hidden from root too) |
| `sysctl_kernel_yama_ptrace_scope` | set `2` | admin-only attach, idea from secureblue (no ptrace by default). CIS RHEL 9 v3.0.0 accepts `1`, `2` or `3` and recommends `2`; RHEL 9 STIG (RHEL-09-213080) wants exactly `1`: finding there. Scanner fails if its profile value is `1`. Cost: `gdb` / `strace` need sudo; anti-cheat games need ptrace (GTA Online does not run on Linux anyway). Tested 2026-10-30 at runtime: Steam game, browsers, VMs OK. Undo: set `1`, `sudo sysctl --system` (no reboot) |
| `auditd_data_disk_full_action`, `auditd_data_retention_admin_space_left_action` | `SUSPEND` | CIS `HALT`/`SINGLE` would stop a laptop when the disk fills |
| `auditd_data_retention_space_left_action` | `SYSLOG` | no local MTA for `EMAIL` |
| `auditd_data_retention_max_log_file_action` | keep `ROTATE` | CIS `KEEP_LOGS` has no limit; `/var` also holds `/var/home` |
| `auditd_data_retention_max_log_file`, `auditd_data_retention_num_logs` | `32` MiB x `40` files | ring >= 1 week (DISA STIG RHEL 9 V-258155). 2026-10-20: measured 2.3 MiB/h with sectop mostly closed, estimated 6.6 MiB/h with sectop polling as root every 6 s (before its privilege split; sectop runs no root commands now) |
| `audit_rules_dac_modification_*` (14), `audit_rules_file_deletion_events_*` (5), `audit_rules_unsuccessful_file_modification_*` (5) | off by default | thousands of events/hour from Steam and Brave caches; `ENABLE_NOISY_AUDIT=yes` to apply |
| `audit_rules_time_clock_settime` | `subj_type!=chronyd_t` filter | chronyd adjusts the clock constantly |

## Scanner false positives on Silverblue (verified manually)

| Rule | Why it fails | Verification |
|------|--------------|--------------|
| `grub2_audit_argument`, `grub2_audit_backlog_limit_argument` | checks GRUB files; Silverblue sets kargs via `rpm-ostree kargs` | `grep -o 'audit[^ ]*' /proc/cmdline` |
| `audit_rules_kernel_module_loading_create`, `..._query` | `create_module` / `query_module` do not exist on x86_64 | - |
| `ensure_fedora_gpgkey_installed` | ostree verifies commits with its own remote keys | `grep -r gpg-verify /etc/ostree/remotes.d/` |
| `package_cron_installed` | `cronie` is layered | `rpm -q cronie` |
| `sysctl_kernel_yama_ptrace_scope`, `sysctl_fs_suid_dumpable` | conflicting defaults in `/usr/lib/sysctl.d/` (`10-default-yama-scope.conf` sets `0`); ours loads last | `sysctl kernel.yama.ptrace_scope fs.suid_dumpable` -> `2`, `0` |
| `file_groupownership_sshd_private_key` | Fedora uses group `ssh_keys` by design | - |
| `sshd_*` | sshd is masked; hardened drop-in present | `systemctl is-enabled sshd` -> `masked` |
| 16 `audit_rules_*` (execution, mac / networkconfig modification, privileged commands, suid_auid, sysadmin, pam.d) | rules loaded, different text format than the scanner regex | `sudo auditctl -l`, `ausearch -k <key>` |

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
  `nosmt` (half the cores), `vsyscall=none` (kernel already xonly), `module.sig_enforce`
  (lockdown integrity).
- `init_on_free=1 iommu.strict=1` (kargs, 2026-11-07, after a trial from 2026-11-03):
  freed pages zeroed at once; IOTLB flushed on every DMA unmap (no lazy window).
  Kernel docs: init_on_free costs 3-5 % typical, up to 8 %. Measured with
  tools/kargs-bench.sh (before / after / end): boot 41.1 / 37.8 / 39.0 s, memory free
  0.78 / 0.68 / 0.66 s, small files 0.17 / 0.18 / 0.17 s, podman run 0.28 / 0.36 /
  0.35 s, O_DIRECT 2 GiB read noisy (1.0 - 3.3 s), IOMMU faults 0, no felt slowdown in
  4 days (desktop, Steam on the iGPU). Undo: `rpm-ostree kargs --delete=...`, reboot.
