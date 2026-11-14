# browsevm: throwaway VM for random links

Status: step 1 (network) in `harden-workstation.sh browsevm`; step 2 (base image) in
`browsevm/browsevm.sh build`. Steps 3-5 not built yet.

## Goal
- random links never reach the daily user's files or the system
- a browser only (Firefox), sound on, 4 GiB RAM, CPU graphics (no GPU)
- nothing leaves the VM: no clipboard, no shared folder, no USB, no file export
- refs: NIST SP 800-53 SC-44 (detonation chambers), SC-39 (process isolation), AC-6;
  CIS Controls v8 Control 9 (email and web browser protections); Qubes OS disposable VMs

## Why a VM, not a third user
- a third user = DAC on the same kernel: browser exploit + kernel LPE = the whole host
- VM: the exploit must also escape QEMU, and lands in `svirt_t` with its own MCS
  category (sVirt), as user `qemu`: no access to the homes, /etc, other VM disks
- `qemu:///system` only. GNOME Boxes / `qemu:///session`: QEMU runs as the daily user,
  an escape = the daily user's files

## Shape
- guest: Fedora minimal + `cage` (Wayland kiosk) + Firefox full screen, auto login of a
  user without sudo. Firefox floor policy from `browsers/firefox/policies.json`. Nothing else
- disk: base image `/var/lib/libvirt/images/browsevm-base.qcow2`; the domain disk has
  `<transient/>` (overlay made at start, deleted at shutdown): every start is clean,
  downloads / cookies / malware gone at power off
- updates: admin only, the base booted without `<transient/>`, `dnf upgrade --refresh`,
  shutdown. Weekly or after a Firefox security release
- 4 GiB RAM, 2 vCPU, base disk ~12 GiB
- removed: spice-vdagent / spicevmc channel (clipboard), virtiofs / 9p, USB redirection,
  smartcard, GL. Sound: ich9 + SPICE audio (the host has no capture nodes: `mic` section)
- display: SPICE on a unix socket only, never TCP

## Network (step 1, built)
- libvirt network `browse` on `virbr-browse`, the /24 of `BROWSEVM_NET` (default 192.168.123), NAT, not autostarted
- not `default`: hostfw accepts virbr0 <-> virbr0 (`fwd_vm_cross`): lab VMs reachable
- hostfw `if_vm_iso`: out to the tunnel only; no new flow to / from another bridge or the
  uplink (rule `fwd_vm_iso`, counter / log `fwd_vm_lan`)
- firewalld: zone `browsevm`; policy `browsevm-to-host` REJECT with DHCP + DNS only;
  policy `browsevm-nat-out` ACCEPT (hostfw + Mullvad decide where). Same shape as
  libvirt's own `libvirt.zone`, `libvirt-to-host.policy`, `libvirt-nat-out.policy`
- kvmlan marks the bridge: lease + DNS with Mullvad's Allow LAN off
- Mullvad disconnected = no internet in the VM

## Base image (step 2, built)
```
sudo browsevm/browsevm.sh build            # once; --force rebuilds (old one -> .old)
BROWSEVM_FEDORA=44 sudo -E browsevm/browsevm.sh build   # other release
```
- `virt-install --location` (Fedora Everything tree, or `--iso` a local Everything
  netinst ISO: installer from the ISO, `inst.stage2=hd:LABEL=<volume label>`, needs
  xorriso) + `browsevm/browsevm.ks` injected into the initrd (the Firefox policy is written
  inside the kickstart: other injected files are gone after the installer's switch_root),
  `--graphics none`, serial
  console on a pty logged by virtlogd to `/var/log/libvirt/qemu/browsevm-build-*.serial.log`
  (QEMU never opens a file itself), `--noreboot`; the kickstart powers off. Build domain
  undefined after, disk kept
- progress line every 20 s: minutes, disk size, last installer line (Ctrl+C: domain destroyed)
- speed probe first (`images/pxeboot/vmlinuz` of the tree): under `BROWSEVM_MIN_KBPS`
  (200 KB/s) it stops
- network `browse` during the install (started and stopped again if it was off):
  packages come through Mullvad like any VM traffic
- kickstart: Fedora `@core` + cage + firefox + mozilla-ublock-origin + pipewire +
  mesa (CPU rendering) + DejaVu / Noto Arabic fonts; no openssh-server, qemu-guest-agent,
  spice-vdagent, plymouth. root locked, user `web` locked password, no sudo. SELinux
  enforcing, firewalld zone drop, no sshd, dnf-makecache off, journal volatile, UTC,
  no IPv6
- kiosk: `cage@tty1.service` (cage wiki unit, `PAMName=cage`), Firefox full screen,
  restarted when closed, CPU renderer (`WLR_RENDERER=pixman`), keyboard us + ara
  (Alt+Shift)
- Firefox: `/etc/firefox/policies/policies.json` = `browsers/firefox/policies.json` +
  uBlock Origin force-installed from the Fedora package's local .xpi + Mullvad Browser
  Extension + no first-run / post-update pages + no profile import. Interface English
  (en_US, no langpacks); Arabic fonts only so Arabic text on pages is readable
- Mullvad Browser Extension (beta): Mullvad ships it itself, not on addons.mozilla.org.
  The host downloads `cdn.mullvad.net/browser-extension/<v>/...xpi`
  (`BROWSEVM_MULLVAD_EXT`, default 0.9.11) at build through Mullvad, its add-on ID is read
  from the xpi's manifest and its sha256 written into the kickstart; `%post` downloads the
  same URL into the image (`/usr/share/browsevm/`) and keeps it only if the sha256
  matches; Firefox force-installs it from there: no download at every start. The xpi is Mozilla-signed:
  Firefox checks the signature at install. Shows the connection (Mullvad server, DNS),
  WebRTC toggle; its SOCKS5 proxy (other exit location) works because the VM is inside
  the host's tunnel. Optional permissions (proxy, tabs, all URLs) only if the proxy is
  turned on. Not downloaded = built without it (warning)
- result lines `BROWSEVM:` (packages yes / no, SELinux, zone, target, unit, policy,
  release) printed by the build from the serial log
- base image: `/var/lib/libvirt/images/browsevm-base.qcow2`, root 0600, never booted
  for browsing

## Start / view from the daily user (step 3)
- system unit `browsevm.service` (oneshot): `virsh start` / `virsh shutdown`, then destroy
- polkit rule: the daily user may start / stop `browsevm.service` only
  (`org.freedesktop.systemd1.manage-units`, `action.lookup("unit")`, verb). No libvirt
  group (= root-equivalent)
- view: `remote-viewer spice+unix:///run/browsevm/spice.sock` from a desktop file, socket
  for one group with the daily user only. To test: owner / mode / SELinux label libvirt
  gives the socket; fallback = small socket proxy unit

## Residual risk
- QEMU / KVM escape + SELinux bypass; CPU side channels
- what is typed in the VM browser is seen there: no logins to real accounts
- a needed file has no way out (by design)

## Steps
1. network: `browse`, firewalld zone + policies, hostfw `if_vm_iso`, kvmlan (done)
2. base image: unattended Fedora minimal install (kickstart), cage + Firefox + policy (done)
3. domain XML (transient disk, removed devices, sound), unit, polkit rule, desktop file
4. checks: `ps -Z` (svirt_t + MCS), overlay gone after shutdown, no clipboard, sectop flows,
   lab VM and LAN unreachable, Mullvad disconnect = no internet
5. README, deviations, rollback, verification rows
