# silverblue-cis-hardening

CIS Fedora Benchmark **Level 2 - Workstation** hardening, tailored for a daily-driver
Fedora Silverblue 44 laptop that also runs KVM/libvirt, rootless Podman (kind), Steam (Flatpak)
and Mullvad VPN (official app, WireGuard, lockdown mode).

Goal: apply as much of CIS L2 as possible **without breaking** the tools I use every day,
and document every deviation with a reason.

> **This is my own laptop's config, not a product.** Tested only on the machine below.
> Read the script and the Decisions block before you run anything: some sections lock
> you out if they do not fit your setup (PAM, su, sudo, kernel args). No warranty
> (GPL-3.0, sections 15-16).

Watched live by [sectop](https://github.com/ghaith-bl/sectop): a terminal dashboard
whose default posture checks and watch list are this repo's baseline.

## Result (OpenSCAP, profile `cis_workstation_l2`)

| Result         | Before | After |
|----------------|-------:|------:|
| fail           |    227 |   115 |
| pass           |    172 |   284 |
| not applicable |     34 |    34 |

Remaining `fail` items (approx.):

- ~55 intentional deviations -> [docs/deviations.md](docs/deviations.md)
- ~16 scanner false positives on Silverblue (config read from the wrong place, syscalls that do not exist on x86_64)
- ~17 audit rules that are loaded and verified working, but written in a different format than the scanner matches
- the rest: backlog / optional (AIDE, crypto-policy module, umask); GRUB password set by hand
  since 2026-11-01 (`grub2-setpassword`)

## Environment

- Fedora Silverblue 44 - rpm-ostree, composefs (`/` is overlay), kernel 7.2
- LUKS full-disk encryption, SELinux enforcing, firewalld default zone `drop`
- KVM/libvirt NAT network (`virbr0`), rootless Podman + kind, toolbox
- Steam (Flatpak), Brave (RPM, Brave's repo), Mullvad VPN (RPM, CLI), lockdown mode,
  auto-connect at boot
- hostfw: own nftables egress filter next to firewalld, enforce from boot (out_noscope
  too)
- Secure Boot on, kernel lockdown `integrity`, only Fedora-signed kernel modules, no NVIDIA
  driver (dGPU off, supergfxctl `Integrated`) -> [docs/secure-boot.md](docs/secure-boot.md)
- OpenSCAP 1.4.4, scap-security-guide 0.1.82

## Usage

```bash
./harden-workstation.sh --list
sudo ./harden-workstation.sh <section> [section...]
sudo ./harden-workstation.sh all
```

- Edit the **Decisions** block at the top of the script first.
- Every replaced file is backed up to `/var/backups/hardening/<timestamp>/`.
- Keep a root shell open (`sudo -i`) while running `sudo`, `su`, `pam`.
- Reboot after the first full run.

### Decisions (top of the script)

| Variable               | Default    | Meaning |
|------------------------|------------|---------|
| `DISABLE_USB_STORAGE`  | `no`       | `yes` blocks USB flash drives / external disks |
| `DISABLE_BLUETOOTH`    | `no`       | `yes` masks bluetooth.service |
| `DISABLE_AVAHI`        | `yes`      | mDNS / network printer discovery off |
| `SSH_SERVER`           | `off`      | `off` masks sshd (incoming only - outgoing `ssh` still works) |
| `FINGERPRINT`          | `disable`  | turn off `with-fingerprint` before enabling faillock |
| `MIC_DISABLE`          | `internal` | `internal` / `all` / `no` - via WirePlumber, speakers unaffected |
| `ENABLE_NOISY_AUDIT`   | `no`       | DAC / delete / failed-open audit rules (very noisy with Steam/Brave) |
| `MAKE_AUDIT_IMMUTABLE` | `yes`      | `-e 2`: audit rules locked until reboot; `no` = unlocked from the next boot |
| `IDLE_LOCK_SECONDS`    | `900`      | GNOME idle lock |
| `MAC_MODE`             | `random`   | `random` = new MAC on every connect, `stable-ssid` = one per Wi-Fi network |
| `GENERIC_HOSTNAME`     | `localhost`| hostname a new network may see on its first connect; `""` = keep mine |
| `MULLVAD_SOCKET_GROUP` | `mullvad`  | group for the Mullvad CLI / GUI; `""` = any local user (Mullvad's default) |
| `MULLVAD_VM_BRIDGES`   | `(virbr0)` | libvirt bridges the `kvmlan` section takes out of Mullvad's LAN block (same as `if_vm` in hostfw); `()` = none |
| `USBGUARD_BLOCK_BLUETOOTH` | `yes` | USB Bluetooth adapters get `block` in the generated USBGuard rules |
| `APP_UNITS`            | `(brave-browser)` | desktop ids the `appunit` section starts as their own service; `()` = none |
| `ADMIN_USER`           | `""` (env) | `accounts`: CLI-only admin (wheel, text console, hidden from GDM); `""` = one account. Given on the command line: `sudo ADMIN_USER=<admin> DAILY_USER=<daily> ./harden-workstation.sh ...` (names stay out of git) |
| `DAILY_USER`           | `""` (env) | `accounts`: GNOME daily user, no sudo; also the user of the desktop steps (cron.allow, shell rc, mic, appunit). Two accounts: give it to every run from the admin |
| `KERNEL_ARGS`          | `(initcall_blacklist=af_alg_init page_alloc.shuffle=1 rd.shell=0 rd.emergency=halt init_on_free=1 iommu.strict=1)` | kernel args of the `kargs` section; `()` = none |

### Recommended order (low -> high risk)

```bash
sudo ./harden-workstation.sh sysctl modules coredump journald services cron sshd auditd audit-rules perms mic
systemctl reboot        # test VPN, VMs, podman, a game
sudo ./harden-workstation.sh sudo     # then: sudo -k && sudo true
sudo ./harden-workstation.sh gnome su # then: su - (must fail), sudo true
sudo ./harden-workstation.sh pam      # with a root shell open
sudo ADMIN_USER=<admin> DAILY_USER=<daily> ./harden-workstation.sh accounts
                                      # run 1: admin account, GDM hidden + refused, homes 0700
                                      # admin password on a text console (Ctrl+Alt+F3):
                                      #   sudo passwd <admin>   (never inside GNOME)
                                      # tty3 as the admin: sudo -v, then run 2 from there
                                      # (same command): daily user out of wheel + mullvad, reboot
sudo ./harden-workstation.sh netprivacy  # close Brave first, then log out and in
sudo ./harden-workstation.sh mullvad  # then log out and in; mullvad status
sudo ./harden-workstation.sh kvmlan   # VMs: lease + ssh with Allow LAN off; in a VM: nmcli device status
sudo rpm-ostree install usbguard && systemctl reboot
sudo ./harden-workstation.sh usbguard # starts it, not enabled: test (keyboard, a new device
                                      # blocked, sudo usb-allow-storage), then the same command again enables it
sudo ./harden-workstation.sh appunit  # close Brave, log out and in; open Brave from the menu
sudo ./harden-workstation.sh time     # VPN connected; then chronyc -N authdata
sudo grub2-setpassword                # by hand, before kargs (user root at the menu)
sudo ./harden-workstation.sh kargs    # then reboot: LUKS unlock, Wi-Fi, VPN, a VM
```

## Sections

| Section       | What it does | Visible effect |
|---------------|--------------|----------------|
| `sysctl`      | kernel + network hardening (`/etc/sysctl.d/90-hardening.conf`) | `dmesg` needs sudo; attaching gdb/strace to running processes needs sudo |
| `modules`     | blocks unused filesystems / protocols | no HFS (Mac) / UDF (DVD) mounts |
| `coredump`    | no core dumps | crashes not saved |
| `journald`    | persistent, compressed journal | none |
| `gnome`       | no automount/autorun, 15 min idle lock (locked), hide login user list | type username at login |
| `sudo`        | `use_pty`, `/var/log/sudo.log`, 5 min timeout | password asked again after 5 min |
| `pam`         | faillock (5 tries -> 15 min), pwhistory (24), pwquality (14 chars, 4 classes), no empty passwords | lockout includes lock screen |
| `su`          | `su` limited to empty group `sugroup` | use `sudo` |
| `accounts`    | CIS Controls v8 5.4: admin `ADMIN_USER` (wheel, own group, AccountsService `SystemAccount=true`, `auth requisite pam_succeed_if.so user != <admin>` as line 1 of `/etc/pam.d/gdm-password`), homes 0700. Run 2 only from the admin (its sudo = proof it works; root is locked): daily user out of `wheel`, `MULLVAD_SOCKET_GROUP` and `sectop`, admin in the Mullvad group | admin: text console only, not in the GDM list, GDM refuses it; daily user: no sudo, no Mullvad CLI; `mullvad` / `rpm-ostree` / `virsh` from the admin |
| `services`    | mask rpcbind / nfs / avahi, disable+mask nftables.service (not stopped live) | no mDNS |
| `cron`        | root-only cron dirs, `cron.allow` / `at.allow` | crontab: root + the daily user (one account: the sudo user); `at`: root only |
| `sshd`        | hardened drop-in `40-cis.conf`, server masked | no incoming SSH |
| `auditd`      | SYSLOG / SUSPEND actions instead of HALT, log ring 40 x 32 MiB | up to 1280 MiB in `/var/log/audit` |
| `audit-rules` | ~70 CIS rules, `-c`, setuid list (from the files on the host), `-e 2` lock; not CIS: `af-alg` (AF_ALG sockets, 2 rules). This host: 73 loaded | more log volume; once locked, a rule change needs a reboot |
| `perms`       | audit config 0640, GRUB cfg 0600, shell rc files 0740 | none |
| `mic`         | WirePlumber rule disables capture nodes | no microphone |
| `netprivacy`  | not CIS: random MAC (Wi-Fi + cable), no hostname in DHCP (every profile), generic hostname (also as fallback, kernel arg: from the first second of boot), DHCP ids from that MAC, IPv6 temporary addresses, LLMNR + mDNS off in resolved, no DNS servers in Wi-Fi / cable profiles (only the tunnel) | new device on the router at every connect: no DHCP reservation; prompt shows `localhost`; no DNS without the tunnel |
| `mullvad`     | not CIS: Mullvad management socket only for group `mullvad` (`MULLVAD_MANAGEMENT_SOCKET_GROUP`, drop-in `50-socket-group.conf`), the admin added (`ADMIN_USER`; one account: my user), daemon restarted (blocks while it restarts) | `mullvad` CLI works after logging out and in, for the admin only; socket access = full daemon control (disconnect, lockdown off) |
| `kvmlan`      | not CIS: own nftables table `inet kvmlan` (`/etc/kvmlan.nft`, `kvmlan.service`): Mullvad's split tunneling marks (ct mark 0xf41 + mark 0x6d6f6c65) on host <-> VM packets of `MULLVAD_VM_BRIDGES` only. Marks, no accept / drop; Mullvad's table and Allow LAN (off) not changed | VMs get a DHCP lease, host <-> VM ssh works; LAN stays blocked; VM internet only via the tunnel (blocked while Mullvad is disconnected) |
| `usbguard`    | not CIS: USBGuard rules from the devices present (only while rules.conf is empty; Bluetooth adapter blocked), usbguard CLI root only, `usb-allow-storage` in `/usr/local/sbin`, GNOME usb-protection off (locked), usbguard-dbus masked if installed (not layered on this host). Run twice: start + test, then enable | only devices in rules.conf work (locked or not, before login too); flash drive: `sudo usb-allow-storage` (storage-only devices, until unplugged); no Bluetooth; `usbguard` needs sudo |
| `appunit`     | not CIS: `app-unit` in `/usr/local/bin`; for each id in `APP_UNITS` a copy of its desktop file in `/usr/local/share/applications` whose Exec runs `app-unit <id> ...`: systemd starts the app as `app-<id>@<pid>.service`. Fixes Brave (launcher forks before GNOME moves it) running inside `org.gnome.Shell@user.service` | the app in its own unit (sectop, `systemd-cgls`); its output in `journalctl --user`; after a Brave update run the section again |
| `time`        | chrony: NTS only (Netnod + PTB), `authselectmode require`, `minsources 2`, no pool, no NTP servers from DHCP | no time sync without the tunnel (RTC keeps time) |
| `kargs`       | not CIS: kernel args from `KERNEL_ARGS` via `rpm-ostree kargs` (next boot). `initcall_blacklist=af_alg_init`: AF_ALG (kernel crypto API from user space) off; `page_alloc.shuffle=1`: random page allocator; `rd.shell=0 rd.emergency=halt`: no initramfs root shell; `init_on_free=1`: freed memory zeroed; `iommu.strict=1`: DMA unmapped at once | `socket(AF_ALG)` fails; no Adiantum / Serpent / Twofish LUKS, BlueZ mesh, iwd; boot failure halts (fix: previous GRUB entry, or `e` + GRUB password) |

## Rollback

```bash
ls /var/backups/hardening/                       # restore files from here
sudo authselect disable-feature with-faillock    # PAM lockout off
faillock --user "$USER" --reset                  # from a root shell, if locked
sudo systemctl unmask <unit>                     # bring a service back
sudo rm /etc/wireplumber/wireplumber.conf.d/90-disable-mic.conf
systemctl --user restart wireplumber
sudo rm /etc/NetworkManager/conf.d/90-privacy.conf /etc/systemd/resolved.conf.d/90-privacy.conf
sudo systemctl reload NetworkManager systemd-resolved   # then reconnect
sudo rm -r /etc/systemd/system/systemd-hostnamed.service.d && sudo systemctl daemon-reload
sudo rpm-ostree kargs --delete=SYSTEMD_DEFAULT_HOSTNAME=localhost   # then reboot
sudo hostnamectl set-hostname <name>             # per profile: nmcli con modify <uuid> ipv4.dhcp-send-hostname -1
sudo nmcli con modify <uuid> ipv4.ignore-auto-dns no   # router DNS back (or old profile: backup system-connections)
sudo usermod -aG wheel <daily>                   # accounts: from the admin; then the
sudo sed -i '1{/pam_succeed_if.so user != /d}' /etc/pam.d/gdm-password   # admin in GDM again
sudo rm /var/lib/AccountsService/users/<admin>   # admin in the GDM list (after a reboot)
sudo rm /etc/systemd/system/mullvad-daemon.service.d/50-socket-group.conf
sudo systemctl daemon-reload && sudo systemctl restart mullvad-daemon
sudo systemctl disable --now kvmlan              # VMs blocked by Mullvad again (table deleted)
sudo rm /etc/systemd/system/kvmlan.service /etc/kvmlan.nft && sudo systemctl daemon-reload
sudo systemctl disable --now usbguard               # USB protection off
sudo usbguard append-rule 'allow id <vid>:<pid> ...'   # one device for good (sudo usbguard list-devices)
sudo rm /usr/local/share/applications/brave-browser.desktop /usr/local/bin/app-unit   # appunit off
sudo hostfw noscope observe                      # out_noscope: log only again
sudo cp /var/backups/hardening/<time>/etc/chrony.conf /etc/ && sudo systemctl restart chronyd
sudo rpm-ostree kargs --delete=initcall_blacklist=af_alg_init   # then reboot
sudo rpm-ostree kargs --delete=page_alloc.shuffle=1 --delete=rd.shell=0 --delete=rd.emergency=halt
sudo rpm-ostree kargs --delete=init_on_free=1 --delete=iommu.strict=1
sudo rm /boot/grub2/user.cfg                     # GRUB password off
sudo rm /etc/audit/rules.d/99-finalize.rules     # audit lock off, then reboot
sudo rpm-ostree rollback                         # after booting the previous GRUB entry
sudo ostree admin config-diff                    # every /etc change vs. image defaults
```

- Removing a sysctl file does not revert values until reboot.
- `kernel.kexec_load_disabled` and `kernel.unprivileged_bpf_disabled = 1` are one-way until reboot.

## Two accounts

CIS Controls v8 5.4, NIST SP 800-53 AC-6(2), NSA/CISA AA23-278A #2: admin work from an
account used for nothing else.

| | admin (`ADMIN_USER`) | daily (`DAILY_USER`) |
|---|---|---|
| login | text console only (GDM hides + refuses it) | GNOME |
| groups | wheel, mullvad, sectop | own group only |
| work | sudo, rpm-ostree, mullvad, `sudo virsh`, install scripts, sectop UI | browsers, Steam, rootless Podman / kind, toolbox, git push |
| password | memorized + offline copy; never typed in GNOME | own |

- Root stays locked. Order matters: the daily user leaves wheel only after the admin's
  sudo works (run 2 of `accounts` refuses to run from anyone else)
- Repos: the daily user develops, tests, commits, pushes; the admin keeps its own clones
  (https), `git pull`, reviews (`git log -p`), then `sudo ./install.sh`. The admin never
  runs code from the daily user's home
- Host changes: one script per step (pre-check, change, verify, report), handed from
  the daily user to the admin and reviewed before it runs:

```bash
# daily user (GNOME)
install -d -m 0755 /tmp/to-admin && install -m 0644 step.sh /tmp/to-admin/
sha256sum step.sh                       # compare on a second device
# admin (Ctrl+Alt+F3)
cd ~/my-project/silverblue-cis-hardening && tools/admin-run.sh step.sh
```

- `tools/admin-run.sh`: private copy in `~/admin-inbox`, shows sha256 + sudo lines + the
  whole script, runs only after the first 8 characters of the sha256 are typed, as the
  admin (sudo per line: each root command in sudo.log and sectop), output copy for the
  daily user in `/tmp/from-admin/`. admin-run itself changes only via `git pull` + review
- `sudo tools/check-accounts.sh <admin> <daily>`: read-only check, one PASS / FAIL line
  each (wheel, mullvad, sectop members, processes still holding old groups, sudo policy,
  root locked, GDM list + PAM line, homes 0700, sectop sysusers + units, Mullvad lockdown),
  copy in `/tmp/check-accounts.*`. Exit 0 = no FAIL
- sectop: `sudo ./install.sh --desktop-user <daily>` from the admin (UI as the admin,
  user helper for the daily user). Run 2 of `accounts` takes group sectop from the
  daily user (sysusers never removes a member)

## Planned

- option, only if a network ever blocks Direct: hostfw mirrors whatever `inet mullvad`
  allows at the time, and Bridges / Encrypted DNS proxy go back on

## Docs

- [docs/deviations.md](docs/deviations.md) - what was not applied and why
- [docs/verification.md](docs/verification.md) - tests run after hardening, account split check
- [docs/secure-boot.md](docs/secure-boot.md) - Secure Boot on, NVIDIA driver removed
- [docs/lessons-learned.md](docs/lessons-learned.md) - findings worth remembering
- [firewall/README.md](firewall/README.md) - hostfw egress filter: design, rules, tests
- [firewall/docs/observe-log.md](firewall/docs/observe-log.md) - observe findings, changes, tests
- [docs/mullvad.md](docs/mullvad.md) - Mullvad VPN setup, Proton VPN removed
- [browsers/README.md](browsers/README.md) - Brave + Firefox hardening

## Requirements

- Fedora Silverblue / Atomic desktop (rpm-ostree). Plain Fedora: most sections work, the
  `kargs` section only warns (no rpm-ostree), check every path first
- bash, sudo, systemd, auditd, firewalld, NetworkManager, chrony, SELinux enforcing
- hostfw (firewall/): nftables + Mullvad VPN app (WireGuard, lockdown mode)
- OpenSCAP + scap-security-guide only to measure (`oscap`, profile `cis_workstation_l2`)

## Checks (CI)

Every push (.github/workflows/check.yml): ASCII-only files, `bash -n` (browsers/brave and
browsers/firefox too), ShellCheck (warnings), Python syntax (firewall/hostfw-noscope.py),
private-info check of the working tree (tools/check-private-info.sh --tree).
Git history: reviewed by hand 2026-11-01 (full run): public VPN / DNS addresses, LAN and
libvirt addresses, interface names, Mullvad's public signing key uid. Kept on purpose.

## Kernel arg trials

`tools/kargs-bench.sh before`, then the args (`sudo rpm-ostree kargs --append=...`) and a
reboot, then `tools/kargs-bench.sh after`: the same numbers both times (memory free,
small files, O_DIRECT disk read, podman start, optional VM boot to ssh, kernel warnings,
IOMMU faults) in `~/kargs-bench/`. A trial arg goes into `KERNEL_ARGS` only after it is
kept.

## Credits

- CIS Fedora Linux Benchmark, OpenSCAP / scap-security-guide (profile and scans)
- Kernel args ideas: secureblue (default kargs), Kernel Self Protection Project
- Research, script drafting and documentation done with help from Claude.
  Every change was reviewed, run and verified on my own machine.

## License

GPL-3.0-or-later, see [LICENSE](LICENSE).
