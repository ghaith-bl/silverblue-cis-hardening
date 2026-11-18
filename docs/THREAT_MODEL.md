# Threat model

For whom this setup is, what it protects, against which capabilities, and what it cannot
do. Every choice: [deviations.md](deviations.md); tests: [verification.md](verification.md).
State: 2026-11-18 (host measured the same day: Secure Boot, LUKS, Thunderbolt, audit,
journal, network profiles, OpenSCAP).

## For whom
- one owner, one daily-driver laptop (Fedora Silverblue 44), two accounts: a daily GUI
  user without sudo, an admin used only on a text console
- networks: home and public / foreign Wi-Fi; all traffic through a VPN
- this repo: a documented personal setup and a portfolio. Not a product for other people

## Goals (all top priority)
- G1 privacy and anonymity: as few identifiers as possible; activities hard to link by
  networks, ISPs, sites, trackers, data brokers and service providers. Privacy is a right,
  not something to justify
- G2 security: a smaller attack surface, a hardened kernel and exploit mitigations, so a
  vulnerability is harder to exploit and does less harm. Recognized standards as the
  measure: CIS Benchmark (OpenSCAP), KSPP, DISA STIG RHEL 9, NIST SP 800-53 / 800-63B,
  CIS Controls v8.1. Every deviation has a reason
- G3 verifiable: measured (OpenSCAP, sectop, before / after on the host), documented,
  reversible ([rollback.md](rollback.md))

## Assets
| Asset | Main controls |
|-------|---------------|
| data on the disk | LUKS2 (aes-xts-plain64, 512-bit key), Secure Boot, lockdown |
| the LUKS passphrase | memorized; argon2id (t=8, 1 GiB, 4 threads); typed only at boot |
| the admin password | root locked; admin only on the text console, never typed in GNOME |
| browser sessions, cookies, saved logins | profiles per use, hardened policies; random links only in browsevm |
| network identity: real IP, DNS queries, VPN account and keys | VPN lockdown mode + hostfw, DNS only in the tunnel, management socket for one group |
| identifiers: MAC, hostname, DHCP ids, IPv6 addresses, browser fingerprint | netprivacy (random MAC, generic hostname, ids from the random MAC), IPv6 off on Wi-Fi profiles, Mullvad Browser / Tor Browser |
| GitHub / SSH keys | in the daily home (0700) |
| logs (journal, audit) | detection, and at the same time a record of activity (G1 cost) |

## Adversaries (capabilities, not names)
| # | Capability | Covered |
|---|------------|---------|
| A1 | web content: trackers, fingerprinting, browser exploits | yes: browser hardening, browsevm for unknown links |
| A2 | malware in the daily session, no root | yes: no sudo, ptrace off, firewall per app scope, kernel hardening against the step to root |
| A3 | the local network: public Wi-Fi, router, other devices | yes: inbound drop, no LAN traffic outside the tunnel, no LLMNR / mDNS / hostname |
| A4 | network observers (ISP, upstream): metadata, DNS, time | partly: they see an encrypted tunnel to the VPN, its size and timing |
| A5 | service providers, data brokers: linking identities | partly: separate profiles, fingerprint-resistant browsers; logins link sessions whatever the network does |
| A6 | a thief, laptop powered off | yes: full-disk encryption, strong passphrase parameters |
| A7 | repeated physical access (evil maid) | partly: GRUB password, USBGuard, IOMMU; the initramfs is not signed (accepted risks) |
| A8 | an attacker with root | detection only, best effort: logs live on the same disk, root can delete them |

Beyond what any workstation config can stop (said as a limit of the tool, not about
anyone): hardware / firmware implants, an exploit chain made for this one machine,
compulsion of the owner or of a provider, an observer who sees both ends of every
connection. Tor, Qubes and Tails list the same kind of limits.

## Section -> adversary
| Section(s) | Against |
|------------|---------|
| sysctl, modules, guesttools, kargs, autoupdate | A2: the step from a user to the kernel / root (kargs `iommu`: A7 DMA devices; `rd.shell=0`: a person at the console) |
| coredump | secrets in crash dumps (A2, A8) |
| journald, auditd, audit-rules (+ sectop) | detection (A8); retention is a G1 cost |
| gnome | a person at an unlocked laptop; media that start by themselves |
| sudo, su, pam, accounts | A2 reaching the admin / root; guessing at the lock screen |
| pwage | compliance only: no direct adversary |
| services, sshd, loopback, hostfw (firewall/) | A3; exfiltration by A2; leaks outside the tunnel |
| cron, perms | persistence; reading other config |
| mic, netprivacy, browsers/ | A2 listening; A1 / A3 / A5 tracking (MAC, hostname, DHCP ids) |
| mullvad, time | A4; a local user changing the VPN; clock attacks on certificates |
| kvmlan | none by itself: lets VMs work with the LAN blocked |
| browsevm, svirt | A1 contained in a VM; a VM escape lands confined |
| usbguard | BadUSB; A7 while locked |
| appunit | firewall attribution (apps hidden in GNOME Shell's cgroup) |

## Anonymity: layers and limits
- network: VPN (sites do not see the real IP, the ISP does not see the destinations), DNS
  only through the tunnel, a random MAC per network, no hostname or stable DHCP ids,
  IPv6 off on Wi-Fi profiles, NTS time through the tunnel
- browser: fingerprint resistance (Mullvad Browser, Tor Browser), separate profiles per
  identity, browsevm for unknown links
- device: microphone off (WirePlumber), no camera, location service masked
- account / behavior: an anonymous VPN account; logging in to an account links sessions
  whatever the network does (a practice of the user, not something a config can enforce)
- limits: a VPN moves trust to the provider (pseudonymity, not anonymity); the strongest
  unlinkability here is Tor Browser; the host and browsevm share the VPN exit IP;
  an observer of both ends of a connection can correlate timing (Tor's own design papers
  say Tor does not defend against this)

## Accepted risks (state 2026-11-18)
- root: detection, not prevention. `kernel.yama.ptrace_scope = 3` closes the easiest way
  into another program's memory and makes the rest harder; root still has others (run as
  the user and ask its Secret Service over D-Bus, eBPF, uprobes, change the sysctl file
  and reboot). Logs are on the same disk (`-e 2` locks the rules, not the files)
- boot chain: Secure Boot checks shim, GRUB and the kernel, not the initramfs; `/boot` is
  not encrypted. With repeated access someone can change the initramfs or the boot
  entries and record the LUKS passphrase. The GRUB password protects the menu only.
  Habit: the laptop is not left alone in untrusted places. Later: a TOTP check of the
  boot state in a lab, a signed unified kernel image when Silverblue supports one
- LUKS `allow-discards` (decision 2026-11-18: kept): TRIM keeps the SSD fast and long-lived;
  a thief can see which blocks are free, not their content or any key
- user namespaces stay on: Flatpak, rootless Podman, Brave's sandbox, glycin, bwrap
  (browsevm viewer) need them
- IPv6: hostfw lets only neighbor discovery / MLD out to the LAN (fc00::/7, fe80::/10,
  ff00::/8 dropped; anything else on the uplink is a leak and dropped); new inbound:
  firewalld drop. The Wi-Fi profiles have IPv6 off (set per profile by hand), the cable
  profile does not; a new network's profile gets IPv6 (until turned off by hand) and the
  network's DNS (until netprivacy runs again)
- time: the clock audit rule leaves out chronyd (it adjusts the clock all the time); NTS
  needs a roughly right clock: far off = set by hand
- browsevm: isolation, not anonymity: it uses the host's VPN exit IP
- Thunderbolt: security level `user`, DMA protection by the IOMMU on (measured
  `iommu_dma_protection` 1); a new device needs approval
- journal: persistent, months of history (2.9 GB, since 2026-07 on 2026-11-18); a time
  limit is still to decide
- browsevm viewer (beta): its sound socket can also record other programs' sound; no
  seccomp filter yet

## Assumptions
- the owner keeps physical control most of the time
- the software sources are trusted: Fedora signing (ostree), Mullvad, Brave, Flathub, the
  Tor Project (supply chain)
- the firmware is trusted (UEFI, embedded controller, Wi-Fi / SSD firmware)

## Not goals
- compliance certification: CIS is the measuring tool, not the target
- hiding that a VPN or Tor is used: the ISP sees an encrypted tunnel
- anti-forensics after a forced unlock
- a published map for an attacker: no account names, no addresses in this repo
