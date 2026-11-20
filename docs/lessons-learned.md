# Lessons learned

## auditd

- Fedora ships `-a task,never` in `/etc/audit/rules.d/audit.rules` -> syscall auditing **off**.
  Watch rules load fine but never fire. Always check `sudo auditctl -l` for it.
- After removing it, add kernel args so early-boot processes are audited:
  `sudo rpm-ostree kargs --append=audit=1 --append=audit_backlog_limit=8192`
- `-F arch=b64`-only rules miss 32-bit programs (Steam). Use `-w` for file watches or list both arches.
- `auditctl -R` stops at the first failing rule -> put `-c` in `01-continue.rules`.
- `augenrules` always moves `-D` first and `-e` last.
- `ausearch -k <key>` also returns the `CONFIG_CHANGE` events of `auditctl` adding the
  rule (same key), and `-m SYSCALL` still shows them (auditctl's own syscall record).
  Filter on the syscall: `ausearch -k af-alg -sc socket`.
- Rules added with `auditctl` are gone after a reboot; a file in `/etc/audit/rules.d/`
  also covers services that start before login.
- `/proc/crypto` lists the kernel's own algorithms (dm-crypt uses `xts(aes)`): it does
  not change when AF_ALG is off. Test with a socket (`socket(AF_ALG)` -> errno 97).
- `initcall_blacklist=<fn>` skips a built-in init function at boot (needs
  CONFIG_KALLSYMS). One karg per function, or a comma list in one.

## OpenSCAP

- The scanner reads config files, not runtime state -> verify with `/proc/cmdline`, `sysctl`, `pwscore`, `ausearch`.
- Silverblue sets kernel args via `rpm-ostree kargs`, not `/etc/default/grub` -> GRUB-based checks fail.
- `pwquality.conf.d/` works, but the scanner only checks `/etc/security/pwquality.conf`.
- Never run `--remediate` on a desktop: server-oriented profiles break GUI/VPN.
- Fedora CIS profiles are marked DRAFT - reference, not a contract.
- Before changing a file for a failed rule, read what the check really reads (OVAL items
  in the ARF / `--results` file). Found 2026-11-09 (scap-security-guide 0.1.82):
  - `dconf_gnome_disable_user_list` checks only dconf db `distro` (`/etc/dconf/db/distro.d/`
    + locks), not `gdm.d`; GDM's profile reads both.
  - `journald_disable_forward_to_syslog` reads only `/etc/systemd/journald.conf`, no
    drop-ins. Fedora 44 has no such file (defaults in `/usr/lib/systemd/`).
  - `file_permission_user_init_files` = every top-level dotfile of a home (`.gitconfig`,
    `.python_history`, ...), not only the shell init files.
  - `file_permissions_boot_grub2` = every file in `/boot/grub2`, also the empty marker
    `.grub2-blscfg-supported`.
  - `accounts_password_pam_unix_authtok` reads `/etc/pam.d/common-password` (Debian):
    fails on Fedora whatever `system-auth` says.
  - Unowned / world-writable checks walk `/var/home` fully: old app data (Waydroid's
    Android uids) and rootless container storage (subuids) show up there.
- Cron dir modes set once (0700) were back at 0755 at a later scan, `/etc/crontab` kept
  0600: set them at every boot (tmpfiles.d `z` lines), same for `/boot/grub2`.

## Silverblue / Fedora

- `/` is overlay (composefs) -> never blacklist the `overlay` module.
- `sudo ostree admin config-diff` lists every `/etc` change vs. the image - good for review and for finding leftovers
  (found a dangling `docker.service` symlink and an old firewalld `docker` zone).
- authselect `local` profile is the default since Fedora 40; features: `with-faillock`, `with-pwhistory`, `without-nullok`.
- `with-fingerprint` enabled without a reader + faillock -> risk of fast lockouts. Disable it first.
- A root-owned file in a home the user owns protects nothing: the user can rename it and
  put its own in its place (needs only write on the folder). `chattr +i` blocks write,
  rename, delete and chmod even for the owner; `chattr +i` on a folder blocks new entries
  in it, not changes inside the folders below it. Tested 2026-11-18.
- What a bash login reads from the home is more than the rc files: `/etc/profile.d/lang.sh`
  reads `~/.i18n`, `/etc/profile.d/bash_completion.sh` sources `~/.config/bash_completion`,
  bash-completion sources `~/.bash_completion` and loads completions (code) from
  `~/.local/share/bash-completion` and every `XDG_DATA_DIRS` entry. Fedora's skel `.bashrc`
  adds `~/.local/bin:~/bin` to PATH and sources `~/.bashrc.d/*`.
- GDM 50 had `enable-passkey-authentication` / `enable-web-authentication`; GDM 51 dropped
  them (passkey and web login ride on `enable-switchable-authentication`, service
  `gdm-switchable-auth`). An unknown dconf key is ignored.

## Secure Boot / kernel modules

- A local MOK key (akmods) has its private key on the same disk: root can sign any module
  and the kernel loads it with Secure Boot on. No local key = only Fedora-signed modules.
- An out-of-tree module taints the kernel (`O E`) at the load attempt, even when it fails
  (`modprobe nvidia`: ENODEV, no GPU).
- `/etc/pki/akmods` and the first key pair had group 963 = now `systemd-coredump`
  (`akmods` = 958): that group could read an old private key. Likely the akmods GID
  moved between deployments (not checked). Check group owners of key files by number.
- `mokutil --list-delete` as a user printed nothing while a delete request was queued
  (MokManager showed "Delete MOK"). Check pending requests with `sudo`.
- `rpm-ostree kargs --delete=KEY=VALUE` removes one entry per flag: a duplicate needs the
  flag twice. All or nothing: an error stages nothing.
- `rpm-ostree uninstall` left the enable symlink of a removed unit:
  `find /etc/systemd/system -xtype l`.
- Repo files from `fedora-workstation-repositories` (`rpm -qf`): `enabled=0`, not delete.
- Kernel lockdown (Secure Boot) blocks hibernation; suspend works.

## Networking

- `nftables.service` `ExecStop` = `nft flush ruleset` -> stopping it wipes firewalld, libvirt and the VPN kill switch.
  Disable + mask only, never stop it live.
- WireGuard is a kernel socket -> `ss` shows the UDP port with no process. Check with `sudo wg show all listen-port`.
  The port changes on every reconnect.
- NetworkManager handles IPv6 RA in userspace -> `accept_ra = 0` is safe.
- NetworkManager sets `rp_filter = 2` itself on multihomed hosts -> strict `1` is not worth it with a VPN.
- VM traffic goes through the host -> with the kill switch active, VMs have no internet either (expected).
- A routing kill switch (Proton: dummy default route + host route to the server) breaks
  when DHCP restarts on wifi roaming (router band steering): the host route goes away,
  transport hits the dummy. Mullvad's kill switch is an nftables table, its routing uses
  a mark: no host route to lose (2026-10-26).
- Changing the VPN client means testing the VMs again: Mullvad's LAN block (Allow LAN off)
  also covers `virbr0`, so the VMs lost DHCP and ssh. Found 9 days after the switch, on
  the first VM use. Mullvad's split tunneling marks on the bridge fix it (kvmlan,
  2026-11-04).
- `virsh net-start` while a VM runs: the VM's tap leaves the bridge and does not come
  back. Network first, then the VM; else `virsh shutdown` + `virsh start` (a reboot
  inside the VM is not enough).
- A VPN client that needs its API before the tunnel is up needs a way out of an egress
  filter. Check it on the host, not from the docs: Mullvad marks only the relay
  transport, its API calls go out as uid 0 without the mark (2026-10-26).
- Fedora ships `/usr/lib/NetworkManager/conf.d/22-wifi-mac-addr.conf`
  (`wifi.cloned-mac-address=stable-ssid`): Wi-Fi already used a random MAC, but the same
  one on every visit to a network; cable kept the real MAC. A random MAC alone does not
  hide the laptop: DHCP sends the hostname (2026-10-27).
- `ipv4.dhcp-send-hostname=false` in a `[connection]` section of NetworkManager.conf is
  documented (profile value -1 = use it) but not used by NetworkManager 1.56.1: hostname
  still sent after reload and reboot; `nmcli con modify <uuid> ipv4.dhcp-send-hostname no`
  works (tcpdump, 2026-10-27; upstream issue NetworkManager#584 open). A new network gets
  a new profile with -1: only a generic hostname covers its first connect.
- NetworkManager.conf `dns=none` stops only the main DNS plugin: `[main]
  systemd-resolved` (default true) still sends every profile's DNS to systemd-resolved.
  No network DNS in resolved = both `dns=none` and `systemd-resolved=false`
  (NetworkManager.conf(5), 2026-11-20). Mullvad is not affected: it sets its resolver on
  its own link through resolved's D-Bus API (SetLinkDNS), not through NetworkManager.
- No global default for `ipv6.method` or `ignore-auto-dns` in NetworkManager.conf: a
  new profile is `auto` / takes the network's DNS. A dispatcher script on `up` can fix
  the profile and `nmcli device reapply` it (netprivacy hook, 2026-11-20).
- Hostname `localhost`: NetworkManager sends no hostname option at all, even with -1
  (tcpdump, 2026-10-27). systemd counts static `localhost` as unset, so `hostnamectl`
  showed `Transient hostname: fedora` (fallback from os-release) while the kernel name
  stayed `localhost`: `SYSTEMD_DEFAULT_HOSTNAME=localhost` for systemd-hostnamed.
- The same fallback at boot: the initramfs comes with the Silverblue image, without
  /etc/hostname, so its systemd set `fedora` at 0.9 s, the real root `localhost` at 12 s
  (first DHCP at 19 s: nothing sent, only early local logs). Kernel arg
  `SYSTEMD_DEFAULT_HOSTNAME=localhost` (the kernel passes unknown `KEY=value` args to
  PID 1 as environment): `localhost` from 0.9 s (2026-10-27).
- With a random MAC, `/sys/class/net/*/address` is not the real one any more: the hardware
  MAC is `permaddr` in `ip link` (tools/check-private-info.sh reads both).

## Bash

- `set -o pipefail` + `cmd | grep -q x` fails at random: grep -q exits at the first
  match, `cmd` gets SIGPIPE on its next write (exit 141), the pipe reports failure
  although the line was there. Seen 2026-11-05 in a host script (`2-hostfw-split.sh`).
  Use `cmd | grep x >/dev/null` (grep reads to the end) or test in the shell
  (`[[ " $(id -nG u) " == *" g "* ]]`). Same for `| head` when the status matters.

## sysctl

- Removing a file from `/etc/sysctl.d/` does not revert values until reboot.
- `kernel.kexec_load_disabled = 1` and `kernel.unprivileged_bpf_disabled = 1` cannot be undone until reboot.
- `ptrace_scope = 1`: `gdb ./prog` / `strace ./prog` still work; attaching to a running process needs sudo.
- `ptrace_scope = 2` (since 2026-10-30): `gdb ./prog` / `strace ./prog` need sudo too (`PTRACE_TRACEME`
  needs `CAP_SYS_PTRACE`, kernel Yama docs). Yama checks attach only, so `/proc/<pid>` reads stay as before.
  Can be set back without reboot; only `3` is one-way.
- `ptrace_scope = 3` (since 2026-11-16): no `PTRACE_ATTACH` / `PTRACE_TRACEME` for anyone, root
  included; `/proc/<pid>/mem` and `process_vm_readv` need attach rights too, so they fail
  as well. Reading `/proc/<pid>/status`, `cgroup`, `fd` links (sectop, `ss -p`) works as before.
- `vm.mmap_rnd_bits` / `vm.mmap_rnd_compat_bits` are root-only files (0600), like
  `net.core.bpf_jit_harden`: a non-root checker (sectop) cannot read them.
- kernel-hardening-checker (2026-11-15, v0.6.17.1, kernel 7.3): the 16 CPU mitigation
  cmdline rows say "is off, not found" although kconfig has `CONFIG_CPU_MITIGATIONS=y` and
  every `CONFIG_MITIGATION_*=y`: read the kconfig rows before trusting a cmdline FAIL.
  Run it unprivileged on copies made by root (`sysctl -a` needs root for 0600 files).

## fwupd

- `/etc/fwupd/remotes.d/lvfs.conf` can hold `AutomaticReports=true` and
  `AutomaticSecurityReports=true` (most likely an earlier "yes" to "upload automatically in the
  future?"; the file was already changed on 2026-11-15). Then `fwupdmgr refresh` uploads
  every unreported update by itself, also with no terminal: admin script 24
  (2026-11-16) sent the report of an older Secure Boot key (KEK) update that way.
- Off for good: comment out `ReportURI` in every remote (no address = nothing to send,
  even after a "yes" by mistake) and set both `Automatic*Reports=false`
  (`FIRMWARE_REPORTS=no`). In scripts every `fwupdmgr` call gets `--no-unreported-check`.
- Fedora 44's `fwupd-refresh.timer` runs every hour (`OnCalendar=*-*-* *:00:00`,
  `RandomizedDelaySec=1h`), not daily: the drop-in `50-schedule.conf` sets its own
  `OnCalendar` (every second day since 2026-11-16; the first one, `50-once-a-day.conf`,
  is removed by the section).

## Audit rules and OS updates

- The setuid / setgid list under `/usr` changes with image updates: 28 programs on
  2026-11-03 (`mullvad-exclude` added), 27 on 2026-11-16 (`/usr/bin/userhelper` no longer
  in the image). `audit-rules` writes one `privileged` rule per program, so a fixed rule
  count in a checker breaks; run the section again after updates. sectop compares the
  `privileged` rules with the programs it finds (posture `audit-rules`).

## Audio

- Laptop mic and speakers share one HDA codec (ALC285) -> blacklisting the driver kills all sound.
- Disable capture in WirePlumber (`node.disabled = true` on `alsa_input.pci-*`) -> speakers keep working.
- This is a software block; a hardware/firmware block is stronger.
