# silverblue-cis-hardening

CIS Fedora Benchmark **Level 2 - Workstation** hardening for a daily-driver Fedora
Silverblue 44 laptop that also runs KVM/libvirt, rootless Podman (kind), Steam (Flatpak)
and Mullvad VPN (WireGuard, lockdown mode).

Goal: as much of CIS L2 as possible **without breaking** the tools I use every day, every
deviation documented with a reason.

> **This is my own laptop's config, not a product.** Tested only on the machine below.
> Read the script and the Decisions block before you run anything: some sections lock
> you out if they do not fit your setup (PAM, su, sudo, kernel args). No warranty
> (GPL-3.0, sections 15-16).

Watched live by [sectop](https://github.com/ghaith-bl/sectop): a terminal dashboard
whose default posture checks and watch list are this repo's baseline.

## Result (OpenSCAP, profile `cis_workstation_l2`)

| Result         | Before | 2026-10 | 2026-11-09 |
|----------------|-------:|--------:|-----------:|
| fail           |    227 |     115 |        109 |
| pass           |    172 |     284 |        290 |
| not applicable |     34 |      34 |         34 |

The 109 fails (scan 2026-11-09, openscap 1.4.6, scap-security-guide 0.1.82):

| Count | Kind | Where |
|------:|------|-------|
| 57 | deviations on purpose: would break the machine, not useful on a personal laptop, two accounts, values changed on purpose | [docs/deviations.md](docs/deviations.md) |
| 11 | scanner false positives on Silverblue (checks the wrong file, syscalls missing on x86_64, sshd masked) | [docs/deviations.md](docs/deviations.md) |
| 16 | audit rules loaded, written in another format than the scanner matches | [docs/deviations.md](docs/deviations.md) |
| 8  | backlog: AIDE (4), CIS crypto-policy module, umask (3) | - |
| 17 | open, being checked: cron dir modes (5), GRUB file mode, user init files, world-writable / unowned files (4), firewalld loopback (2), PAM authselect (2), GDM user list, journald ForwardToSyslog | - |

The profile is a DRAFT in scap-security-guide (based on the CIS Fedora 40 benchmark).
Reports stay on the host, never in git (`.gitignore`: `scap-*`).

## Environment

- Fedora Silverblue 44: rpm-ostree, composefs (`/` is overlay), kernel 7.2
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
| `SSH_SERVER`           | `off`      | `off` masks sshd (incoming only, outgoing `ssh` works) |
| `FINGERPRINT`          | `disable`  | turn off `with-fingerprint` before enabling faillock |
| `MIC_DISABLE`          | `internal` | `internal` / `all` / `no`, via WirePlumber, speakers unaffected |
| `ENABLE_NOISY_AUDIT`   | `no`       | DAC / delete / failed-open audit rules (very noisy with Steam / Brave) |
| `MAKE_AUDIT_IMMUTABLE` | `yes`      | `-e 2`: audit rules locked until reboot |
| `IDLE_LOCK_SECONDS`    | `900`      | GNOME idle lock |
| `MAC_MODE`             | `random`   | `random` = new MAC on every connect, `stable-ssid` = one per Wi-Fi network |
| `GENERIC_HOSTNAME`     | `localhost`| hostname a network sees; `""` = keep mine |
| `MULLVAD_SOCKET_GROUP` | `mullvad`  | group for the Mullvad CLI / GUI; `""` = any local user (Mullvad's default) |
| `MULLVAD_VM_BRIDGES`   | `(virbr0)` | libvirt bridges outside Mullvad's LAN block (`kvmlan`); `()` = none |
| `USBGUARD_BLOCK_BLUETOOTH` | `yes` | USB Bluetooth adapters blocked in the generated USBGuard rules |
| `APP_UNITS`            | `(brave-browser)` | desktop ids `appunit` starts as their own service; `()` = none |
| `ADMIN_USER`           | `""` (env) | `accounts`: text-console admin; `""` = one account |
| `DAILY_USER`           | `""` (env) | `accounts`: GNOME daily user, no sudo; also the user of the desktop steps. Give it to every run from the admin |
| `KERNEL_ARGS`          | `(initcall_blacklist=af_alg_init page_alloc.shuffle=1 rd.shell=0 rd.emergency=halt init_on_free=1 iommu.strict=1)` | kernel args of `kargs`; `()` = none |

User names are given on the command line and stay out of git:
`sudo ADMIN_USER=<admin> DAILY_USER=<daily> ./harden-workstation.sh ...`

### Recommended order (low -> high risk)

```bash
sudo ./harden-workstation.sh sysctl modules coredump journald services loopback cron sshd auditd audit-rules perms mic
systemctl reboot                      # test VPN, VMs, podman, a game
sudo ./harden-workstation.sh sudo     # then: sudo -k && sudo true
sudo ./harden-workstation.sh gnome su # then: su - (must fail), sudo true
sudo ./harden-workstation.sh pam      # with a root shell open
sudo ADMIN_USER=<admin> DAILY_USER=<daily> ./harden-workstation.sh accounts
                                      # run 1, then the admin password on a text console
                                      # (Ctrl+Alt+F3, sudo passwd <admin>, never in GNOME);
                                      # run 2 (same command) from the admin on tty3, reboot
sudo ./harden-workstation.sh netprivacy  # close Brave first, then log out and in
sudo ./harden-workstation.sh mullvad  # log out and in; mullvad status
sudo ./harden-workstation.sh kvmlan   # VMs: lease + ssh with Allow LAN off
sudo rpm-ostree install usbguard && systemctl reboot
sudo ./harden-workstation.sh usbguard # run 1 starts it: test keyboard, new device blocked,
                                      # sudo usb-allow-storage; run 2 enables it
sudo ./harden-workstation.sh appunit  # close Brave, log out and in
sudo ./harden-workstation.sh time     # VPN connected; then chronyc -N authdata
sudo grub2-setpassword                # by hand, before kargs (user root at the menu)
sudo ./harden-workstation.sh kargs    # reboot: LUKS unlock, Wi-Fi, VPN, a VM
```

## Sections

| Section       | What it does | Visible effect |
|---------------|--------------|----------------|
| `sysctl`      | kernel + network hardening (`/etc/sysctl.d/90-hardening.conf`) | `dmesg`, gdb / strace attach need sudo |
| `modules`     | blocks unused filesystems / protocols | no HFS / UDF mounts |
| `coredump`    | no core dumps | crashes not saved |
| `journald`    | persistent, compressed journal, no syslog forward | none |
| `gnome`       | no automount / autorun, 15 min idle lock, no login user list (all locked) | type the user name at login |
| `sudo`        | `use_pty`, `/var/log/sudo.log`, 5 min timeout | password asked again after 5 min |
| `pam`         | faillock (5 tries -> 15 min), pwhistory (24), pwquality (14 chars, 4 classes), no empty passwords | lockout includes the lock screen |
| `su`          | `su` limited to the empty group `sugroup` | use `sudo` |
| `accounts`    | CIS Controls v8 5.4: admin in wheel, hidden from and refused by GDM; daily user out of wheel, `mullvad`, `sectop`; homes 0700. Run 2 only from the admin | admin: text console only; daily user: no sudo, no Mullvad CLI |
| `services`    | mask rpcbind / nfs / avahi, nftables.service | no mDNS |
| `loopback`    | firewalld: `lo` in zone `trusted`, 127.0.0.1 / ::1 as source only toward themselves | none |
| `cron`        | root-only cron dirs (modes set again at every boot by tmpfiles), `cron.allow` / `at.allow` | crontab: root + the daily user; `at`: root only |
| `sshd`        | hardened drop-in `40-cis.conf`, server masked | no incoming SSH |
| `auditd`      | SYSLOG / SUSPEND instead of HALT, log ring 40 x 32 MiB | up to 1280 MiB in `/var/log/audit` |
| `audit-rules` | CIS rules, `-c`, setuid list from the host, `-e 2` lock; not CIS: `af-alg` (2 rules). This host: 73 | more log volume; a rule change needs a reboot |
| `perms`       | audit config 0640, `/boot/grub2` files 0600 (set again at boot by tmpfiles), dotfiles in the homes 0740 or stricter (daily user and admin) | none |
| `mic`         | WirePlumber rule disables capture nodes | no microphone |
| `netprivacy`  | not CIS: random MAC, no hostname in DHCP, generic hostname (also a kernel arg), DHCP ids from that MAC, IPv6 temporary addresses, LLMNR + mDNS off, no DNS servers in Wi-Fi / cable profiles | new device on the router each connect; prompt shows `localhost`; no DNS without the tunnel |
| `mullvad`     | not CIS: Mullvad management socket only for group `mullvad`, the admin in it | `mullvad` CLI for the admin only |
| `kvmlan`      | not CIS: table `inet kvmlan`, Mullvad's split tunneling marks on host <-> VM packets of `MULLVAD_VM_BRIDGES` only (no accept / drop) | VM lease + host <-> VM ssh with Allow LAN off; VM internet only via the tunnel |
| `usbguard`    | not CIS: rules from the devices present, CLI root only, `usb-allow-storage`, GNOME usb-protection off. Run twice: start + test, then enable | only known devices work, locked or not; flash drive: `sudo usb-allow-storage` |
| `appunit`     | not CIS: apps in `APP_UNITS` start as `app-<id>@<pid>.service` (Brave left GNOME Shell's cgroup) | the app in its own unit; after a Brave update run it again |
| `time`        | chrony: NTS only (Netnod + PTB), `authselectmode require`, `minsources 2`, no pool, no DHCP NTP | no time sync without the tunnel |
| `kargs`       | not CIS: `KERNEL_ARGS` via `rpm-ostree kargs` (next boot): AF_ALG off, random page allocator, no initramfs shell, freed memory zeroed, strict IOMMU | no Adiantum / Serpent / Twofish LUKS, BlueZ mesh, iwd; boot failure halts |

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
- Host changes: one script per step, handed over in `/tmp/to-admin` and run with
  `tools/admin-run.sh <step>.sh` on tty3 (shows the script, asks for the first 8
  characters of its sha256, sudo per line, output copy in `/tmp/from-admin`).

## Tools

- `tools/admin-run.sh` - review, then run, a script from the daily user (as the admin)
- `tools/check-accounts.sh <admin> <daily>` - read-only PASS / FAIL check of the account split
- `tools/check-private-info.sh` - private data check of the tree / history before a push
- `tools/kargs-bench.sh before|after` - same numbers before and after a kernel arg trial

## Planned

- only if a network ever blocks Mullvad's Direct API access: hostfw mirrors what
  `inet mullvad` allows, and Bridges / Encrypted DNS proxy go back on

## Docs

- [docs/deviations.md](docs/deviations.md) - what was not applied and why
- [docs/verification.md](docs/verification.md) - tests after hardening, account split check
- [docs/rollback.md](docs/rollback.md) - undo per section
- [docs/secure-boot.md](docs/secure-boot.md) - Secure Boot on, NVIDIA driver removed
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
