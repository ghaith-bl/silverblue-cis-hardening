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
| `accounts_maximum_age_login_defs`, `accounts_minimum_age_login_defs`, `accounts_password_set_max_life_existing`, `accounts_password_set_min_life_existing` | skip | NIST SP 800-63B advises against forced periodic password changes |
| `account_disable_post_pw_expiration` | skip | risk of locking out the only account |
| `accounts_tmout` | skip | GNOME idle lock (15 min, locked) covers it |
| `banner_etc_issue_cis`, `banner_etc_issue_net_cis`, `dconf_gnome_banner_enabled`, `dconf_gnome_login_banner_text`, `sshd_enable_warning_banner_net` | skip | legal banners — value in organisations, not on a personal device |
| `package_systemd-journal-remote_installed` | skip (later) | needs a log server — planned for the homelab |
| `accounts_passwords_pam_faillock_even_deny_root_or_root_unlock_time` | skip | root account is locked; `su` restricted to an empty group |
| `ensure_root_password_configured` | skip | root is locked; emergency shell refuses access instead of opening unauthenticated |
| `service_bluetooth_disabled` | skip | service already disabled manually; masking optional |

## Changed on purpose

| Rule | Decision | Reason |
|------|----------|--------|
| `sysctl_kernel_kptr_restrict` | set `2` | stricter than the CIS value `1` (hidden from root too) |
| `auditd_data_disk_full_action`, `auditd_data_retention_admin_space_left_action` | `SUSPEND` | CIS `HALT`/`SINGLE` would stop a laptop when the disk fills |
| `auditd_data_retention_space_left_action` | `SYSLOG` | no local MTA for `EMAIL` |
| `auditd_data_retention_max_log_file_action` | keep `ROTATE` | CIS `KEEP_LOGS` can fill the disk |
| `audit_rules_dac_modification_*` (14), `audit_rules_file_deletion_events_*` (5), `audit_rules_unsuccessful_file_modification_*` (5) | off by default | thousands of events/hour from Steam and Brave caches; `ENABLE_NOISY_AUDIT=yes` to apply |
| `audit_rules_immutable` | later | enable `-e 2` after a week without rule changes |
| `audit_rules_time_clock_settime` | `subj_type!=chronyd_t` filter | chronyd adjusts the clock constantly |

## Scanner false positives on Silverblue (verified manually)

| Rule | Why it fails | Verification |
|------|--------------|--------------|
| `grub2_audit_argument`, `grub2_audit_backlog_limit_argument` | checks GRUB files; Silverblue sets kargs via `rpm-ostree kargs` | `grep -o 'audit[^ ]*' /proc/cmdline` |
| `audit_rules_kernel_module_loading_create`, `..._query` | `create_module` / `query_module` do not exist on x86_64 | — |
| `ensure_fedora_gpgkey_installed` | ostree verifies commits with its own remote keys | `grep -r gpg-verify /etc/ostree/remotes.d/` |
| `package_cron_installed` | `cronie` is layered | `rpm -q cronie` |
| `sysctl_kernel_yama_ptrace_scope`, `sysctl_fs_suid_dumpable` | conflicting defaults in `/usr/lib/sysctl.d/`; ours loads last | `sysctl kernel.yama.ptrace_scope fs.suid_dumpable` → `1`, `0` |
| `file_groupownership_sshd_private_key` | Fedora uses group `ssh_keys` by design | — |
| `sshd_*` | sshd is masked; hardened drop-in present | `systemctl is-enabled sshd` → `masked` |
| ~17 `audit_rules_*` | rules loaded, different text format than the scanner regex | `sudo auditctl -l`, `ausearch -k <key>` |

## Proton VPN CLI
- me.proton.vpn.split_tunneling.service masked (eBPF, unused).
- me.proton.vpn.kill_switch D-Bus service runs as root, no systemd sandboxing.
  Not used by kill-switch "standard" (routing only). Re-check if "permanent" ships.
- Kill switch "standard" is not applied at boot. hostfw adapts to it.
- CLI does not connect at boot. Boot -> login covered by hostfw boot mode enforce
  (2026-10-19): no internet outside the tunnel before connect.
- Connect at login via user unit protonvpn-connect.service (firewall/proton/),
  not at boot: CLI auth is per user.
- hostfw observe week ended after 1 day (2026-10-19). Findings: firewall/docs/observe-log.md.
