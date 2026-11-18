# Threat model

What this is: privacy and security hardening of one Fedora Silverblue laptop, kept in
public as a documented method. The method is public, the private data is not. It is
never finished: protections are studied, tested and added all the time, and this model
changes with them.

In short, what is in place (host measured 2026-11-18):
- three firewall layers: firewalld (inbound: zone `drop`), Mullvad lockdown (nothing
  outside the VPN tunnel, also while disconnected), hostfw from this repo (outbound by
  destination, port and program scope; the LAN blocked; every leak logged)
- kernel hardening (KSPP based): no ptrace for anyone (`ptrace_scope = 3`), no forced
  writes through /proc/<pid>/mem, kernel pointers and logs hidden, no unprivileged
  eBPF, JIT hardened, io_uring and kexec off, page allocator shuffled
  (`page_alloc.shuffle=1`), memory wiped on free (`init_on_free=1`), strict IOMMU, only
  signed modules, Secure Boot + lockdown `integrity`, more address randomization, AF_ALG off
- isolation: random links in a throwaway VM (browsevm: confined, own network, disk in RAM,
  its window in its own sandbox); programs in their own systemd units, so the firewall
  knows who sends
- accounts: a daily user without sudo, an admin only on a text console, root locked
- devices: USBGuard (only known USB devices), microphone off, no camera, location service
  off (host; into the script: planned)
- network privacy: random MAC per network, a generic hostname, no DHCP ids from the
  machine, DNS only through the tunnel, no LLMNR / mDNS
- detection: auditd (73 rules, locked until reboot), journald, sectop (live view)

This file: for whom, what it protects, against which capabilities, what it cannot do.
Every choice: [deviations.md](deviations.md); tests: [verification.md](verification.md).

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
  unlinkability here is Tor Browser; browsevm uses the host's VPN exit unless the Mullvad
  extension's proxy is on; an observer of both ends of a connection can correlate timing (Tor's own design papers
  say Tor does not defend against this)

## Accepted risks (state 2026-11-18)
- root: detection, not prevention. `kernel.yama.ptrace_scope = 3` closes the easiest way
  into another program's memory and makes the rest harder; root still has others (run as
  the user and ask its Secret Service over D-Bus, eBPF, uprobes, change the sysctl file
  and reboot). Logs are on the same disk (`-e 2` locks the rules, not the files)
- boot chain: Secure Boot checks shim, GRUB and the kernel, not the initramfs; `/boot` is
  not encrypted. With repeated access someone can change the initramfs or the boot
  entries and record the LUKS passphrase. The GRUB password protects the menu only.
  The initramfs cannot be encrypted: it is the program that asks for the passphrase and
  runs before the disk is open. The fix is to verify it: a signed unified kernel image
  (kernel + initramfs + command line in one signed file). Fedora 44 has sealed Atomic
  Desktop images built that way as tests (systemd-boot, UKI, composefs with fs-verity),
  not official yet: watch, try in a VM. Until then: the laptop is not left alone in
  untrusted places; a TOTP check of the boot state (tpm2-totp) in a lab
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
- browsevm: Mullvad Browser with the Mullvad extension's proxy on exits from another
  Mullvad server than the host (Mullvad itself sees both); Brave, or the proxy off: the
  host's VPN exit. Tor Browser in browsevm: planned
- Thunderbolt: security level `user`, DMA protection by the IOMMU on (measured
  `iommu_dma_protection` 1); a new device needs approval
- journal: persistent; only journald's default size cap (10 % of the filesystem, at most
  4 GiB): 2.9 GB, history since 2026-07 (measured 2026-11-18). A time limit: decided in
  the journald step
- browsevm viewer (beta): the sound socket it needs for the VM's sound would also let a
  taken-over viewer listen to what other programs play (not the microphone: off); no
  system-call filter (seccomp) yet

## Assumptions
- the owner keeps physical control most of the time
- the software sources are trusted: Fedora signing (ostree), Mullvad, Brave, Flathub, the
  Tor Project (supply chain)
- the firmware is trusted (UEFI, embedded controller, Wi-Fi / SSD firmware)

## Not goals
- compliance certification: CIS is the measuring tool, not the target
- hiding that a VPN or Tor is used: the ISP sees an encrypted tunnel
- anti-forensics after a forced unlock
- a map for an attacker: the method is public, the private data is not. No account
  names, addresses, network names, device ids or raw scan reports in this repo
- a final state: the work goes on (new protections studied, tested, added)
