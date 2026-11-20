# Threat model

Why I harden my laptop, how I think about it, and what it can and cannot stop. The
technical reference is at the end.

## Why I do this

Privacy. More and more people care about privacy, and at the same time it is
being taken away. Our data is collected, sold and used to track us. Many
companies speak well of privacy in general words, but their terms and policies
often say something else. For me, privacy is a human right, not a crime, and
not something I have to explain. Today I, like everyone, spend a big part of my
day on my phone and my computer. That time is our life, and our life is being
sold without our consent. It is a complicated subject, but it is clearly worth
protecting, as humans. So I want my machine to give away as little as
possible, and my activity to be hard to link to me, not only hard to break
into.

Security. I love this field, Linux and open source: so many choices, and the
freedom to read, change and understand every part. I like to think like an
attacker, so I can close the door before malware comes. With AI, weaknesses
are found and used faster than before, so security has to be taken seriously:
fast security updates, layers of defense, and good habits that make risks
smaller. I also use AI as a study partner: it helps me find and test ways to
harden my system, at the level of the kernel, the firewall, the browser and the
services. I check every idea myself before it runs on my machine.

So this project is personal. It is not a commercial product and not a theory.
It is my method, and the things I learn every day. It is where I show how I
think about security: clear rules, tested controls, and a strict method. I
would rather write what my setup cannot do than claim more than I have tested.
The method is public; my private data is not. It is never finished: I keep
studying, testing and adding, and this page changes with it.

## My rules
- private by default: nothing leaves the machine unless I decided it
- least privilege: my daily account has no admin rights; programs get only what they need
- layers: no single control is trusted alone (three firewalls, not one)
- standards as the measure: CIS Benchmark, KSPP, DISA STIG, NIST; every deviation has a
  written reason ([deviations.md](deviations.md))
- measure, do not believe: a setting counts when a test shows it
  ([verification.md](verification.md))
- every change has a way back ([rollback.md](rollback.md))
- say the limits: what this cannot stop is written below

## A normal day
- **I turn the laptop on.** The firmware asks for its password, Secure Boot checks the
  boot loader and the kernel, I type the disk passphrase. Stolen while off, the disk is
  only noise.
- **I log in.** My daily account has no admin rights. The admin account exists only on
  a text console; I never type its password in the desktop.
- **I join a cafe Wi-Fi.** The laptop shows a new random MAC and no real name. Nothing
  goes out except the VPN tunnel, DNS too; new connections from the cafe network are
  dropped. A network I have never used gets the same on its first connect: its DNS is
  never used, IPv6 goes off within seconds (until then only neighbor discovery leaves).
- **I browse.** My browsers are hardened, with separate profiles for separate uses.
  A link I do not trust opens in a throwaway VM that is gone when I close it.
- **A program goes bad.** It cannot attach to other programs to read or change their
  memory (ptrace off for everyone), cannot use sudo or su, and the firewall sees which
  program unit sends what. It still runs as me: my files, browser profiles and unlocked
  keyring are open to it. The kernel is hardened to make the step to root harder.
- **I plug in a USB stick I do not know.** It is blocked until I allow it as admin.
- **Updates.** System updates are prepared every day and used at the next reboot; apps
  every day; the browsing VM is rebuilt every week.
- **I walk away.** The screen locks after 15 minutes idle; new USB devices stay blocked.
- **I check.** sectop shows what goes out and what tries to come in; audit rules record
  sensitive changes.

## What is in place (host measured 2026-11-18)
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
- accounts: a daily user without sudo, an admin only on a text console (its shell files
  locked, nothing new can be put in its home), root locked; the login screen takes a
  password only
- devices: USBGuard (only known USB devices), microphone off, no camera, location service
  off (host; into the script: planned)
- network privacy: random MAC per network, a generic hostname, no DHCP ids from the
  machine, DNS only through the tunnel, no LLMNR / mDNS
- detection: auditd (73 rules, locked until reboot), journald, sectop (live view)

## Reference

### For whom
- me: one daily-driver laptop (Fedora Silverblue 44), two accounts (daily GUI user without
  sudo, admin only on a text console)
- networks: home and public / foreign Wi-Fi; all traffic through a VPN
- this repo: my documented method and portfolio. Not a product for other people

### Goals (all top priority)
- G1 privacy and anonymity: as few identifiers as possible; my activity hard to link by
  networks, ISPs, sites, trackers, data brokers and service providers
- G2 security: a smaller attack surface, a hardened kernel and exploit mitigations, so a
  vulnerability is harder to exploit and does less harm. Measured against CIS Benchmark
  (OpenSCAP), KSPP, DISA STIG RHEL 9, NIST SP 800-53 / 800-63B, CIS Controls v8.1
- G3 verifiable: measured (OpenSCAP, sectop, before / after on the host), documented,
  reversible

### What I protect
| Asset | Main controls |
|-------|---------------|
| data on the disk | LUKS2 (aes-xts-plain64, 512-bit key), Secure Boot, lockdown |
| the disk passphrase | memorized; argon2id (t=8, 1 GiB, 4 threads); typed only at boot |
| the admin password | root locked; admin only on the text console, never typed in the desktop; its shell files locked, so a script I run as the admin cannot plant an alias or a PATH entry for the next sudo (14 tries refused, 2026-11-19); a process it leaves running: open (below) |
| browser sessions, cookies, saved logins | profiles per use, hardened policies; random links only in browsevm |
| network identity: real IP, DNS queries, VPN account and keys | VPN lockdown mode + hostfw, DNS only in the tunnel, VPN control for one group only |
| identifiers: MAC, hostname, DHCP ids, IPv6 addresses, browser fingerprint | netprivacy (random MAC, generic hostname, ids from the random MAC), IPv6 off on Wi-Fi / cable profiles (a new one on its first connect), Mullvad Browser / Tor Browser |
| GitHub / SSH keys | in the daily home (0700) |
| logs (journal, audit) | detection, and at the same time a record of my activity (a G1 cost) |

### Who I protect it from (capabilities, not names)
| # | Capability | Covered |
|---|------------|---------|
| A1 | web content: trackers, fingerprinting, browser exploits | yes: browser hardening, browsevm for unknown links |
| A2 | malware in my daily session, no root | partly: no sudo, ptrace off, firewall per program scope, kernel hardening against the step to root; what my daily user can read (files, browser profiles, the unlocked keyring) is open to it |
| A3 | the local network: public Wi-Fi, router, other devices | yes: inbound drop, no LAN traffic outside the tunnel, no LLMNR / mDNS / hostname |
| A4 | network observers (ISP, upstream): metadata, DNS, time | partly: they see an encrypted tunnel to the VPN, its size and timing |
| A5 | service providers, data brokers: linking identities | partly: separate profiles, fingerprint-resistant browsers; a login links sessions whatever the network does |
| A6 | a thief, laptop powered off | yes: full-disk encryption, strong passphrase parameters |
| A7 | repeated physical access (evil maid) | partly: firmware and GRUB passwords, USBGuard, IOMMU; the initramfs is not signed (risks below) |
| A8 | an attacker with root | detection only, best effort: logs live on the same disk, root can delete them |

Beyond what any workstation config can stop (a limit of the tool, not a statement about
anyone): hardware / firmware implants, an exploit chain made for this one machine,
compulsion of me or of a provider, an observer who sees both ends of every connection.
Tor, Qubes and Tails list the same kind of limits.

### Which part does what
| Section(s) | Against |
|------------|---------|
| sysctl, modules, guesttools, kargs, autoupdate | A2: the step from a user to the kernel / root (kargs `iommu`: A7 DMA devices; `rd.shell=0`: a person at the console) |
| coredump | secrets in crash dumps (A2, A8) |
| journald, auditd, audit-rules (+ sectop) | detection (A8); keeping logs is a G1 cost |
| gnome | a person at an unlocked laptop; media that start by themselves |
| sudo, su, pam, accounts | A2 reaching the admin / root; guessing at the lock screen |
| pwage | compliance only: no direct adversary |
| services, sshd, loopback, hostfw (firewall/) | A3; data sent out by A2; leaks outside the tunnel |
| cron, perms | persistence; reading other config |
| mic, netprivacy, browsers/ | A2 listening; A1 / A3 / A5 tracking (MAC, hostname, DHCP ids) |
| mullvad, time | A4; a local user changing the VPN; clock attacks on certificates |
| kvmlan | none by itself: lets VMs work with the LAN blocked |
| browsevm, svirt | A1 contained in a VM; a VM escape lands confined |
| usbguard | BadUSB; A7 while locked |
| appunit | firewall attribution (programs hidden in GNOME Shell's cgroup) |

### Where anonymity ends
- network: VPN (sites do not see my real IP, the ISP does not see where I go), DNS only
  through the tunnel, a random MAC per network, no hostname or stable DHCP ids, IPv6 off
  on Wi-Fi / cable profiles, NTS time through the tunnel
- browser: fingerprint resistance (Mullvad Browser, Tor Browser), separate profiles per
  identity, browsevm for unknown links
- device: microphone off (WirePlumber), no camera, location service masked
- account / behavior: an anonymous VPN account; logging in to an account links sessions
  whatever the network does (my practice, not something a config can enforce)
- limits: a VPN moves trust to the provider (pseudonymity, not anonymity); the strongest
  unlinkability here is Tor Browser; browsevm uses the host's VPN exit unless the Mullvad
  extension's proxy is on; an observer of both ends of a connection can correlate timing
  (Tor's own design papers say Tor does not defend against this)

### Risks I accept, and why (state 2026-11-18)
- root: detection, not prevention. `kernel.yama.ptrace_scope = 3` closes the easiest way
  into another program's memory and makes the rest harder; root still has others (run as
  the user and ask its Secret Service over D-Bus, eBPF, uprobes, change the sysctl file
  and reboot). Logs are on the same disk (`-e 2` locks the rules, not the files)
- boot chain: Secure Boot checks shim, GRUB and the kernel, not the initramfs; `/boot` is
  not encrypted. With repeated access someone can change the initramfs or the boot
  entries and record the disk passphrase. The GRUB password protects the menu only.
  The initramfs cannot be encrypted: it is the program that asks for the passphrase and
  runs before the disk is open. The fix is to verify it: a signed unified kernel image
  (kernel + initramfs + command line in one signed file). Fedora 44 has sealed Atomic
  Desktop images built that way as tests (systemd-boot, UKI, composefs with fs-verity),
  not official yet: I watch it and will try it in a VM. Until then: I do not leave the
  laptop alone in untrusted places; a TOTP check of the boot state (tpm2-totp) in a lab
- LUKS `allow-discards` (decision 2026-11-18: kept): TRIM keeps the SSD fast and
  long-lived; a thief can see which blocks are free, not their content or any key
- user namespaces stay on: Flatpak, rootless Podman, Brave's sandbox, glycin, bwrap
  (browsevm viewer) need them
- IPv6: hostfw lets only neighbor discovery / MLD out to the LAN (fc00::/7, fe80::/10,
  ff00::/8 dropped; anything else on the uplink is a leak and dropped); new inbound:
  firewalld drop. Wi-Fi / cable profiles have IPv6 off; a new network's profile has it on
  for a few seconds on its first connect (until the netprivacy dispatcher hook turns it
  off). A network's DNS is never used (NetworkManager hands resolved none)
- time: the clock audit rule leaves out chronyd (it adjusts the clock all the time); NTS
  needs a roughly right clock: far off = set by hand from a trusted device
  ([rollback.md](rollback.md), "Clock far off"), not `nocerttimecheck`
- browsevm: Mullvad Browser with the Mullvad extension's proxy on exits from another
  Mullvad server than the host (Mullvad itself sees both); Brave, or the proxy off: the
  host's VPN exit. Tor Browser in browsevm: planned
- Thunderbolt: security level `user`, DMA protection by the IOMMU on (measured
  `iommu_dma_protection` 1); a new device needs approval
- journal: persistent; only journald's default size cap (10 % of the filesystem, at most
  4 GiB): 2.9 GB, history since 2026-07 (measured 2026-11-18). Decided: one month,
  applied in the journald step
- admin account: scripts from my daily session run as the admin, after I read them in
  full (`tools/admin-run.sh`). If a bad one gets through, it cannot hide in the admin's
  shell (14 plant tries refused on the host, 2026-11-19): the shell files are locked, PATH has no folder from the home, and nothing new
  can be created at the top of the home or in its config folders. Two ways stay open,
  both planned: a process the script leaves running until I log out or reboot, and the
  admin's own clones of these repos (a changed file there runs with sudo later). Root
  in the end comes from the review, not from these locks
- browsevm viewer (beta): the sound socket it needs for the VM's sound would also let a
  taken-over viewer listen to what other programs play (not the microphone: off); no
  system-call filter (seccomp) yet

### What I assume
- I keep physical control of the laptop most of the time
- the software sources are trusted: Fedora signing (ostree), Mullvad, Brave, Flathub, the
  Tor Project (supply chain)
- the firmware is trusted (UEFI, embedded controller, Wi-Fi / SSD firmware)

### What this is not
- a compliance certificate: CIS is the measuring tool, not the target
- a way to hide that a VPN or Tor is used: the ISP sees an encrypted tunnel
- anti-forensics after a forced unlock
- a map for an attacker: the method is public, my private data is not. No account
  names, addresses, network names, device ids or raw scan reports in this repo
- finished: the work goes on (new protections studied, tested, added)
