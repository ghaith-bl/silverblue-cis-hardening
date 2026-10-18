# silverblue-cis-hardening

CIS Fedora Benchmark **Level 2 – Workstation** hardening, tailored for a daily-driver
Fedora Silverblue 44 laptop that also runs KVM/libvirt, rootless Podman (kind), Steam (Flatpak)
and ProtonVPN (WireGuard + kill switch).

Goal: apply as much of CIS L2 as possible **without breaking** the tools I use every day,
and document every deviation with a reason.

## Result (OpenSCAP, profile `cis_workstation_l2`)

| Result         | Before | After |
|----------------|-------:|------:|
| fail           |    227 |   115 |
| pass           |    172 |   284 |
| not applicable |     34 |    34 |

Remaining `fail` items (approx.):

- ~55 intentional deviations → [docs/deviations.md](docs/deviations.md)
- ~16 scanner false positives on Silverblue (config read from the wrong place, syscalls that do not exist on x86_64)
- ~17 audit rules that are loaded and verified working, but written in a different format than the scanner matches
- the rest: backlog / optional (AIDE, crypto-policy module, GRUB password, umask)

## Environment

- Fedora Silverblue 44 — rpm-ostree, composefs (`/` is overlay), kernel 7.2
- LUKS full-disk encryption, SELinux enforcing, firewalld default zone `drop`
- KVM/libvirt NAT network (`virbr0`), rootless Podman + kind, toolbox
- Steam (Flatpak), ProtonVPN (WireGuard) with kill switch
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
| `SSH_SERVER`           | `off`      | `off` masks sshd (incoming only — outgoing `ssh` still works) |
| `FINGERPRINT`          | `disable`  | turn off `with-fingerprint` before enabling faillock |
| `MIC_DISABLE`          | `internal` | `internal` / `all` / `no` — via WirePlumber, speakers unaffected |
| `ENABLE_NOISY_AUDIT`   | `no`       | DAC / delete / failed-open audit rules (very noisy with Steam/Brave) |
| `MAKE_AUDIT_IMMUTABLE` | `no`       | `-e 2` — enable after a week of testing |
| `IDLE_LOCK_SECONDS`    | `900`      | GNOME idle lock |

### Recommended order (low → high risk)

```bash
sudo ./harden-workstation.sh sysctl modules coredump journald services cron sshd auditd audit-rules perms mic
systemctl reboot        # test VPN, VMs, podman, a game
sudo ./harden-workstation.sh sudo     # then: sudo -k && sudo true
sudo ./harden-workstation.sh gnome su # then: su - (must fail), sudo true
sudo ./harden-workstation.sh pam      # with a root shell open
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
| `pam`         | faillock (5 tries → 15 min), pwhistory (24), pwquality (14 chars, 4 classes), no empty passwords | lockout includes lock screen |
| `su`          | `su` limited to empty group `sugroup` | use `sudo` |
| `services`    | mask rpcbind / nfs / avahi, disable+mask nftables.service (not stopped live) | no mDNS |
| `cron`        | root-only cron dirs, `cron.allow` / `at.allow` | only root + your user can use crontab |
| `sshd`        | hardened drop-in `40-cis.conf`, server masked | no incoming SSH |
| `auditd`      | SYSLOG / SUSPEND actions instead of HALT | none |
| `audit-rules` | ~70 CIS rules, `-c`, setuid list | more log volume |
| `perms`       | audit config 0640, GRUB cfg 0600, shell rc files 0740 | none |
| `mic`         | WirePlumber rule disables capture nodes | no microphone |

## Rollback

```bash
ls /var/backups/hardening/                       # restore files from here
sudo authselect disable-feature with-faillock    # PAM lockout off
faillock --user "$USER" --reset                  # from a root shell, if locked
sudo systemctl unmask <unit>                     # bring a service back
sudo rm /etc/wireplumber/wireplumber.conf.d/90-disable-mic.conf
systemctl --user restart wireplumber
sudo ostree admin config-diff                    # every /etc change vs. image defaults
```

- Removing a sysctl file does not revert values until reboot.
- `kernel.kexec_load_disabled` and `kernel.unprivileged_bpf_disabled = 1` are one-way until reboot.

## Docs

- [docs/deviations.md](docs/deviations.md) — what was not applied and why
- [docs/verification.md](docs/verification.md) — tests run after hardening
- [docs/lessons-learned.md](docs/lessons-learned.md) — findings worth remembering

## Credits

Research, script drafting and documentation done with help from Claude.
Every change was reviewed, run and verified on my own machine.
