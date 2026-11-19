# silverblue-privacy-hardening

Privacy and security hardening for a Fedora Silverblue workstation. CIS-aligned,
measured with OpenSCAP, every deviation documented. My daily-driver laptop (Silverblue
44) that also runs KVM/libvirt, rootless Podman (kind), Steam (Flatpak) and Mullvad VPN
(WireGuard, lockdown mode).

Goal: privacy, anonymity and security **without breaking** the tools I use every day.
The CIS Benchmark is the measure, not the target: scap-security-guide, Fedora profile
`cis_workstation_l2` (a DRAFT, based on the CIS Fedora 40 community benchmark). Every
deviation has a written reason. Why I do this, what it protects and its limits:
[docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).

> **This is my own laptop's config, not a product.** Tested only on the machine below.
> Read the script and the Decisions block before you run anything: some sections lock
> you out if they do not fit your setup (PAM, su, sudo, kernel args). No warranty
> (GPL-3.0, sections 15-16).

Watched live by [sectop](https://github.com/ghaith-bl/sectop): a terminal dashboard
whose default posture checks and watch list are this repo's baseline.

## Result (OpenSCAP, profile `cis_workstation_l2`)

| Result         | Before | 2026-10 | 2026-11-09 |
|----------------|-------:|--------:|-----------:|
| fail           |    227 |     115 |         96 |
| pass           |    172 |     284 |        303 |
| not applicable |     34 |      34 |         34 |

The 96 fails (scan 2026-11-09, openscap 1.4.6, scap-security-guide 0.1.82), each one
checked by hand:

| Count | Kind | Where |
|------:|------|-------|
| 56 | deviations on purpose: would break the machine, not useful on a personal laptop, two accounts, values changed on purpose, Fedora's own PAM profile | [docs/deviations.md](docs/deviations.md) |
| 12 | scanner false positives on Silverblue / Fedora (checks the wrong file or a Debian path, syscalls missing on x86_64, sshd masked) | [docs/deviations.md](docs/deviations.md) |
| 16 | audit rules loaded, written in another format than the scanner matches | [docs/deviations.md](docs/deviations.md) |
| 8  | backlog: AIDE (4), CIS crypto-policy module, umask (3) | - |
| 4  | rootless container storage in the daily user's home (kind lab): subuid owners, the container's own modes | [docs/deviations.md](docs/deviations.md) |

Reports stay on the host, never in git (`.gitignore`: `scap-*`).

## Environment

- Fedora Silverblue 44: rpm-ostree, composefs (`/` is overlay), Fedora kernel (current)
- LUKS full-disk encryption, SELinux enforcing, firewalld default zone `drop`
- Secure Boot on, kernel lockdown `integrity`, only Fedora-signed modules, no NVIDIA
  driver (dGPU off) -> [docs/secure-boot.md](docs/secure-boot.md)
- KVM/libvirt NAT (`virbr0`), rootless Podman + kind, toolbox
- Steam (Flatpak), Brave (RPM, Brave's repo), Mullvad VPN (RPM, CLI, lockdown mode,
  auto-connect at boot)
- hostfw: own nftables egress filter next to firewalld, enforce from boot ->
  [firewall/README.md](firewall/README.md)
- Two accounts: GNOME daily user without sudo, text-console admin (see below)

## Usage

```bash
./harden-workstation.sh --list
sudo ./harden-workstation.sh <section> [section...]
sudo ./harden-workstation.sh all
```

- Edit the **Decisions** block at the top of the script first.
- Every replaced file is backed up to `/var/backups/hardening/<timestamp>/`.
- Keep a root shell open (`sudo -i`) while running `sudo`, `su`, `pam`.
- Reboot after the first full run. Undo: [docs/rollback.md](docs/rollback.md).

### Decisions (top of the script)

| Variable               | Default    | Meaning |
|------------------------|------------|---------|
| `DISABLE_USB_STORAGE`  | `no`       | `yes` blocks USB flash drives / external disks |
| `DISABLE_BLUETOOTH`    | `no`       | `yes` masks bluetooth.service |
| `DISABLE_AVAHI`        | `yes`      | mDNS / network printer discovery off |
| `GUEST_TOOLS`          | `(open-vm-tools-desktop open-vm-tools virtualbox-guest-additions spice-vdagent)` | `guesttools`: VM guest agents removed from the image on real hardware; `()` = keep |
| `SSH_SERVER`           | `off`      | `off` masks sshd (incoming only, outgoing `ssh` works) |
| `FINGERPRINT`          | `disable`  | turn off `with-fingerprint` before enabling faillock; GDM fingerprint login off (locked) |
| `MIC_DISABLE`          | `internal` | `internal` / `all` / `no`, via WirePlumber, speakers unaffected |
| `ENABLE_NOISY_AUDIT`   | `no`       | DAC / delete / failed-open audit rules (very noisy with Steam / Brave) |
| `MAKE_AUDIT_IMMUTABLE` | `yes`      | `-e 2`: audit rules locked until reboot |
| `IDLE_LOCK_SECONDS`    | `900`      | GNOME idle lock |
| `PASS_MAX_DAYS`        | `365`      | `pwage`: password max age, new and existing accounts |
| `PASS_MIN_DAYS`        | `1`        | `pwage`: min days between changes (pwhistory counts); `0` = none |
| `PASS_WARN_AGE`        | `14`       | `pwage`: warning days before it expires |
| `MAC_MODE`             | `random`   | `random` = new MAC on every connect, `stable-ssid` = one per Wi-Fi network |
| `GENERIC_HOSTNAME`     | `localhost`| hostname a network sees; `""` = keep mine |
| `MULLVAD_SOCKET_GROUP` | `mullvad`  | group for the Mullvad CLI / GUI; `""` = any local user (Mullvad's default) |
| `MULLVAD_VM_BRIDGES`   | `(virbr0 virbr-browse)` | libvirt bridges outside Mullvad's LAN block (`kvmlan`); `()` = none |
| `BROWSEVM_BRIDGE`      | `virbr-browse` | `browsevm`: bridge of network `browse` (also in hostfw `if_vm_iso` and `MULLVAD_VM_BRIDGES`) |
| `BROWSEVM_NET`         | `192.168.123` | `browsevm`: its /24 (host .1, DHCP .10-.20) |
| `SVIRT_OFF_BOOLEANS`   | `(virt_use_usb virt_use_nfs)` | `svirt`: SELinux booleans turned off for every VM process; `()` = leave them |
| `USBGUARD_BLOCK_BLUETOOTH` | `yes` | USB Bluetooth adapters blocked in the generated USBGuard rules |
| `AUTO_UPDATE_POLICY`   | `stage`    | `autoupdate`: rpm-ostree automatic updates (daily): `stage` = ready for the next boot, `check` = only look, `none` = manual |
| `FLATPAK_AUTO_UPDATE`  | `yes`      | `autoupdate`: system + every user's Flatpaks updated daily; `no` = leave |
| `FIRMWARE_METADATA_REFRESH` | `yes` | `autoupdate`: firmware metadata (LVFS) on `FIRMWARE_METADATA_CALENDAR` (Fedora's timer: every hour); firmware itself is never installed by itself |
| `FIRMWARE_METADATA_CALENDAR` | `*-*-1/2` | `autoupdate`: systemd `OnCalendar` of `fwupd-refresh.timer`: every second day (odd days, 00:00 + up to 1 h) |
| `FIRMWARE_REPORTS`     | `no`       | `autoupdate`: fwupd sends no reports to LVFS (report address removed, nothing automatic); other = leave |
| `APP_UNITS`            | `(brave-browser)` | desktop ids `appunit` starts as their own service; `()` = none |
| `ADMIN_USER`           | `""` (env) | `accounts`: text-console admin; `""` = one account |
| `DAILY_USER`           | `""` (env) | `accounts`: GNOME daily user, no sudo; also the user of the desktop steps. Give it to every run from the admin |
| `KERNEL_ARGS`          | `(initcall_blacklist=af_alg_init page_alloc.shuffle=1 rd.shell=0 rd.emergency=halt init_on_free=1 iommu.strict=1 hash_pointers=always proc_mem.force_override=never module.sig_enforce=1 intel_iommu=on debugfs=off bdev_allow_write_mounted=0)` | kernel args of `kargs`; `()` = none |
| `PTRACE_SCOPE`         | `3`        | `sysctl`: `2` = only root may trace, `3` = nobody (one-way until reboot) |

User names are given on the command line and stay out of git:
`sudo ADMIN_USER=<admin> DAILY_USER=<daily> ./harden-workstation.sh ...`

### Recommended order (low -> high risk)

```bash
sudo ./harden-workstation.sh sysctl modules coredump journald services loopback cron sshd auditd audit-rules perms mic
sudo ./harden-workstation.sh guesttools  # after audit-rules: VM guest agents out of the image
systemctl reboot                      # test VPN, VMs, podman, a game
sudo ./harden-workstation.sh sudo     # then: sudo -k && sudo true
sudo ./harden-workstation.sh gnome su # then: su - (must fail), sudo true
sudo ./harden-workstation.sh pam      # with a root shell open
sudo ./harden-workstation.sh pwage    # skips an account whose password would expire within PASS_WARN_AGE
sudo ADMIN_USER=<admin> DAILY_USER=<daily> ./harden-workstation.sh accounts
                                      # run 1, then the admin password on a text console
                                      # (Ctrl+Alt+F3, sudo passwd <admin>, never in GNOME);
                                      # run 2 (same command) from the admin on tty3, reboot
sudo ./harden-workstation.sh netprivacy  # close Brave first, then log out and in
sudo ./harden-workstation.sh mullvad  # log out and in; mullvad status
sudo ./harden-workstation.sh kvmlan   # VMs: lease + ssh with Allow LAN off
sudo ./harden-workstation.sh browsevm # throwaway browsing VM, step 1: its network (new hostfw first)
sudo browsevm/browsevm.sh build       # browsevm step 2: base image (unattended Fedora install)
sudo DAILY_USER=<daily> browsevm/browsevm.sh install
                                      # browsevm step 3: domain, units, polkit rule, launchers,
                                      # daily update timer (needs virt-viewer layered); then
                                      # "browsevm Mullvad" / "browsevm Brave" in the app grid
sudo browsevm/browsevm.sh report      # the kiosk's own state (one start with a serial port)
sudo browsevm/browsevm.sh update      # new base image now (the timer does it at 7 days)
sudo ./harden-workstation.sh svirt    # VMs: no host USB / NFS for QEMU, unconfined domains refused
sudo rpm-ostree install usbguard && systemctl reboot
sudo ./harden-workstation.sh usbguard # run 1 starts it: test keyboard, new device blocked,
                                      # sudo usb-allow-storage; run 2 enables it
sudo ./harden-workstation.sh appunit  # close Brave, log out and in
sudo ./harden-workstation.sh time     # VPN connected; then chronyc -N authdata
sudo ./harden-workstation.sh autoupdate  # OS staged daily (applied at reboot), Flatpaks daily
sudo grub2-setpassword                # by hand, before kargs (user root at the menu)
sudo ./harden-workstation.sh kargs    # reboot: LUKS unlock, Wi-Fi, VPN, a VM
```

## Sections

| Section       | What it does | Visible effect |
|---------------|--------------|----------------|
| `sysctl`      | kernel + network hardening (`/etc/sysctl.d/90-hardening.conf`); not CIS: KSPP attack surface (io_uring off, no tty ldisc autoload, FIFO / file protection 2, SysRq off, WARN / Oops limit 100, mmap bits max) | `dmesg`; gdb / strace do not work, not even with sudo; no io_uring |
| `modules`     | blocks unused filesystems / protocols | no HFS / UDF mounts |
| `coredump`    | no core dumps | crashes not saved |
| `journald`    | persistent, compressed journal, no syslog forward (drop-in + main file) | none |
| `gnome`       | no automount / autorun, 15 min idle lock, no login user list (dconf `gdm` + `distro`, all locked); GDM: password login only (switchable authentication, passkey, web login, smartcard off and locked; fingerprint with `FINGERPRINT=disable`) | type the user name at login; no other login method offered |
| `sudo`        | `use_pty`, `/var/log/sudo.log`, 5 min timeout | password asked again after 5 min |
| `pam`         | faillock (5 tries -> 15 min), pwhistory (24), pwquality (15 chars, 4 classes, dictionary check), no empty passwords | lockout includes the lock screen |
| `pwage`       | password max age `PASS_MAX_DAYS`, min age `PASS_MIN_DAYS`, warning `PASS_WARN_AGE` (login.defs + every login account); no lock after expiry | change the password once a year; not twice in one day (root can: `sudo passwd <user>`) |
| `su`          | `su` limited to the empty group `sugroup` | use `sudo` |
| `accounts`    | CIS Controls v8 5.4: admin in wheel, hidden from and refused by GDM; daily user out of wheel, `mullvad`, `sectop`; homes 0700. Not CIS: the admin's shell start files from `accounts/` (fixed PATH, no `~/.bashrc.d`), immutable; the top of its home, `.config`, `.local`, `.local/share` (and its systemd / flatpak folders) immutable (nothing new there). Run 2 only from the admin | admin: text console only; its shell files and new files at those levels only after `sudo chattr -i`; daily user: no sudo, no Mullvad CLI |
| `services`    | mask rpcbind / nfs / avahi, nftables.service | no mDNS |
| `guesttools`  | CIS Controls v8 4.8: `GUEST_TOOLS` removed from the image (`rpm-ostree override remove`, next boot) when the machine is not a VM and nothing else needs them: one setuid root program (`vmware-user-suid-wrapper`) and three agents started at login less. Their setuid files leave `55-privileged.rules` in the same go | none on real hardware; one reboot |
| `loopback`    | firewalld: `lo` in zone `trusted`, 127.0.0.1 / ::1 as source only toward themselves | none |
| `cron`        | root-only cron dirs (modes set again at every boot by tmpfiles), `cron.allow` / `at.allow` | crontab: root + the daily user; `at`: root only |
| `sshd`        | hardened drop-in `40-cis.conf`, server masked | no incoming SSH |
| `auditd`      | SYSLOG / SUSPEND instead of HALT, log ring 40 x 32 MiB | up to 1280 MiB in `/var/log/audit` |
| `audit-rules` | CIS rules, `-c`, setuid list from the host, `-e 2` lock; not CIS: `af-alg`, `io-uring` (2 rules each). This host: 73 (47 + one per setuid program: 26); run again after updates | more log volume; a rule change needs a reboot |
| `perms`       | audit config 0640, `/boot/grub2` files 0600 (set again at boot by tmpfiles), dotfiles in the homes 0740 or stricter (daily user and admin) | none |
| `mic`         | WirePlumber rule disables capture nodes | no microphone |
| `netprivacy`  | not CIS: random MAC, no hostname in DHCP, generic hostname (also a kernel arg), DHCP ids from that MAC, IPv6 temporary addresses, LLMNR + mDNS off, no DNS servers in Wi-Fi / cable profiles | new device on the router each connect; prompt shows `localhost`; no DNS without the tunnel |
| `mullvad`     | not CIS: Mullvad management socket only for group `mullvad`, the admin in it | `mullvad` CLI for the admin only |
| `kvmlan`      | not CIS: table `inet kvmlan`, Mullvad's split tunneling marks on host <-> VM packets of `MULLVAD_VM_BRIDGES` only (no accept / drop) | VM lease + host <-> VM ssh with Allow LAN off; VM internet only via the tunnel |
| `browsevm`    | not CIS: throwaway VM for random links ([docs/browsevm.md](docs/browsevm.md)). Section: libvirt network `browse` (own bridge, not autostarted), firewalld zone `browsevm` + policies (to the host: DHCP, DNS to its own bridge address only). `browsevm/browsevm.sh`: `build` (unattended Fedora minimal, cage kiosk, Mullvad Browser at Safer + Brave with managed policies, kiosk user confined `user_u`), `install` (domain on a RAM overlay, `browsevm@<browser>.service`, polkit rule, two launchers, daily `browsevm-update.timer`), `report`, `update` (new base at 7 days). Viewer (beta): through an own Wayland relay (no drops when GNOME Shell is busy), inside a bwrap sandbox | app grid `browsevm Mullvad` / `browsevm Brave`: a clean VM per window; its traffic: tunnel only, never the LAN, a lab VM or the host (DNS of its bridge only) |
| `svirt`       | not CIS: SELinux booleans `SVIRT_OFF_BOOLEANS` off (a VM's QEMU process gets no host USB device, no NFS file), `/etc/libvirt/qemu.conf` `security_require_confined = 1` (libvirt refuses a domain that asks to run without sVirt) | no USB passthrough to a VM, no VM disk on NFS |
| `usbguard`    | not CIS: rules from the devices present, CLI root only, `usb-allow-storage`, GNOME usb-protection off. Run twice: start + test, then enable | only known devices work, locked or not; flash drive: `sudo usb-allow-storage` |
| `appunit`     | not CIS: apps in `APP_UNITS` start as `app-<id>@<pid>.service` (Brave left GNOME Shell's cgroup) | the app in its own unit; after a Brave update run it again |
| `time`        | chrony: NTS only (Netnod + PTB), `authselectmode require`, `minsources 2`, no pool, no DHCP NTP | no time sync without the tunnel |
| `autoupdate`  | CIS Controls v8 7.3 / 7.4: `/etc/rpm-ostreed.conf` `AutomaticUpdatePolicy=stage` + `rpm-ostreed-automatic.timer` (OS + layered packages downloaded daily, applied at the next boot); `flatpak-update-system.timer` + global user `flatpak-update-user.timer` (daily); `fwupd-refresh.timer` every second day (firmware metadata only); fwupd reports to LVFS off | updates arrive without asking; reboot to apply the OS one (`rpm-ostree status`); firmware / dbx: `fwupdmgr get-updates`, by hand |
| `kargs`       | not CIS: `KERNEL_ARGS` via `rpm-ostree kargs` (next boot): AF_ALG off, random page allocator, no initramfs shell, freed memory zeroed, strict IOMMU, hashed pointers, no forced writes through /proc/<pid>/mem, signed modules only, IOMMU on, no debugfs, no writes to mounted block devices | no Adiantum / Serpent / Twofish LUKS, BlueZ mesh, iwd; boot failure halts; no debugfs |

Reasons and costs of every not-CIS choice: [docs/deviations.md](docs/deviations.md).

## Two accounts

CIS Controls v8 5.4, NIST SP 800-53 AC-6(2): admin work from an account used for nothing
else. Root stays locked.

| | admin (`ADMIN_USER`) | daily (`DAILY_USER`) |
|---|---|---|
| login | text console only | GNOME |
| groups | wheel, mullvad, sectop | own group only |
| work | sudo, rpm-ostree, mullvad, `sudo virsh`, installs, sectop UI | browsers, Steam, rootless Podman / kind, toolbox, git |
| password | memorized + offline copy, never typed in GNOME | own |

- Repos: the daily user commits and pushes; the admin pulls its own https clones,
  reviews, then installs. The admin never runs code from the daily user's home.
- Admin home: a script run as the admin cannot hide in its shell. Start files
  (`.bash_profile`, `.bashrc`, `.bash_logout`, `.inputrc`) = `accounts/admin.*`, immutable,
  PATH only from root-owned dirs; files bash, `/etc/profile.d` or bash-completion would read
  from the home (`.bash_completion`, `.i18n`, ...) removed and cannot come back: the top of
  the home, `.config`, `.local`, `.local/share` are immutable, and so are `.config/systemd`,
  `.local/share/systemd`, `.local/share/flatpak` if present (no user units, no flatpak
  exports with completions can be made there). Folders already there
  (scripts, clones, results) stay writable. Not covered: a process the script left
  running, the admin's clones ([docs/THREAT_MODEL.md](docs/THREAT_MODEL.md))
- Host changes: one script per step, handed over in `/tmp/to-admin` and run with
  `tools/admin-run.sh <step>.sh` on tty3 (shows the script, asks for the first 8
  characters of its sha256, sudo per line, output copy in `/tmp/from-admin`).

## Tools

- `tools/admin-run.sh` - review, then run, a script from the daily user (as the admin)
- `tools/check-accounts.sh <admin> <daily>` - read-only PASS / FAIL check of the account split
- `tools/check-private-info.sh` - private data check of the tree / history before a push
- `tools/kargs-bench.sh before|after` - same numbers before and after a kernel arg trial
- `tools/lint.sh [<sectop repo>]` - the CI's lint checks before a push (ASCII, bash -n,
  shellcheck, private info); ShellCheck from a toolbox: `tools/lint.sh --setup` once

## Planned

- only if a network ever blocks Mullvad's Direct API access: hostfw mirrors what
  `inet mullvad` allows, and Bridges / Encrypted DNS proxy go back on

## Docs

- [docs/deviations.md](docs/deviations.md) - what was not applied and why
- [docs/verification.md](docs/verification.md) - tests after hardening, account split check
- [docs/rollback.md](docs/rollback.md) - undo per section
- [docs/secure-boot.md](docs/secure-boot.md) - Secure Boot on, NVIDIA driver removed, revocation list (dbx)
- [docs/mullvad.md](docs/mullvad.md) - Mullvad VPN setup
- [docs/lessons-learned.md](docs/lessons-learned.md) - findings worth remembering
- [firewall/README.md](firewall/README.md) - hostfw egress filter: design, rules, tests
- [firewall/docs/observe-log.md](firewall/docs/observe-log.md) - observe findings and changes
- [browsers/README.md](browsers/README.md) - Brave + Firefox hardening

## Requirements

- Fedora Silverblue / Atomic desktop (rpm-ostree). Plain Fedora: most sections work,
  `kargs` only warns; check every path first
- bash, sudo, systemd, auditd, firewalld, NetworkManager, chrony, SELinux enforcing
- hostfw: nftables + Mullvad VPN app (WireGuard, lockdown mode)
- OpenSCAP + scap-security-guide only to measure

## Checks (CI)

Every push (.github/workflows/check.yml): ASCII-only files, `bash -n`, ShellCheck
(warnings), Python syntax, private-info check of the tree. Git history reviewed by hand:
public VPN / DNS addresses, LAN and libvirt addresses and interface names are kept on
purpose.

## Credits

- CIS Fedora Linux Benchmark, OpenSCAP / scap-security-guide (profile and scans)
- Kernel arg ideas: secureblue (default kargs), Kernel Self Protection Project
- Research, script drafting and documentation done with help from Claude.
  Every change was reviewed, run and verified on my own machine.

## License

GPL-3.0-or-later, see [LICENSE](LICENSE).
