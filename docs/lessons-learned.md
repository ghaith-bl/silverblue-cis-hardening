# Lessons learned

## auditd

- Fedora ships `-a task,never` in `/etc/audit/rules.d/audit.rules` → syscall auditing **off**.
  Watch rules load fine but never fire. Always check `sudo auditctl -l` for it.
- After removing it, add kernel args so early-boot processes are audited:
  `sudo rpm-ostree kargs --append=audit=1 --append=audit_backlog_limit=8192`
- `-F arch=b64`-only rules miss 32-bit programs (Steam). Use `-w` for file watches or list both arches.
- `auditctl -R` stops at the first failing rule → put `-c` in `01-continue.rules`.
- `augenrules` always moves `-D` first and `-e` last.

## OpenSCAP

- The scanner reads config files, not runtime state → verify with `/proc/cmdline`, `sysctl`, `pwscore`, `ausearch`.
- Silverblue sets kernel args via `rpm-ostree kargs`, not `/etc/default/grub` → GRUB-based checks fail.
- `pwquality.conf.d/` works, but the scanner only checks `/etc/security/pwquality.conf`.
- Never run `--remediate` on a desktop: server-oriented profiles break GUI/VPN.
- Fedora CIS profiles are marked DRAFT — reference, not a contract.

## Silverblue / Fedora

- `/` is overlay (composefs) → never blacklist the `overlay` module.
- `sudo ostree admin config-diff` lists every `/etc` change vs. the image — good for review and for finding leftovers
  (found a dangling `docker.service` symlink and an old firewalld `docker` zone).
- authselect `local` profile is the default since Fedora 40; features: `with-faillock`, `with-pwhistory`, `without-nullok`.
- `with-fingerprint` enabled without a reader + faillock → risk of fast lockouts. Disable it first.

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

- `nftables.service` `ExecStop` = `nft flush ruleset` → stopping it wipes firewalld, libvirt and the VPN kill switch.
  Disable + mask only, never stop it live.
- WireGuard is a kernel socket → `ss` shows the UDP port with no process. Check with `sudo wg show all listen-port`.
  The port changes on every reconnect.
- NetworkManager handles IPv6 RA in userspace → `accept_ra = 0` is safe.
- NetworkManager sets `rp_filter = 2` itself on multihomed hosts → strict `1` is not worth it with a VPN.
- VM traffic goes through the host → with the kill switch active, VMs have no internet either (expected).
- A routing kill switch (Proton: dummy default route + host route to the server) breaks
  when DHCP restarts on wifi roaming (router band steering): the host route goes away,
  transport hits the dummy. Mullvad's kill switch is an nftables table, its routing uses
  a mark: no host route to lose (2026-10-26).
- A VPN client that needs its API before the tunnel is up needs a way out of an egress
  filter: Mullvad marks those calls (privileged), Proton did not (2026-10-26).

## sysctl

- Removing a file from `/etc/sysctl.d/` does not revert values until reboot.
- `kernel.kexec_load_disabled = 1` and `kernel.unprivileged_bpf_disabled = 1` cannot be undone until reboot.
- `ptrace_scope = 1`: `gdb ./prog` / `strace ./prog` still work; attaching to a running process needs sudo.

## Audio

- Laptop mic and speakers share one HDA codec (ALC285) → blacklisting the driver kills all sound.
- Disable capture in WirePlumber (`node.disabled = true` on `alsa_input.pci-*`) → speakers keep working.
- This is a software block; a hardware/firmware block is stronger.
