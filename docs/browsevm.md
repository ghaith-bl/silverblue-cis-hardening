# browsevm: throwaway VM for random links

Status: step 1 (network) in `harden-workstation.sh browsevm`; step 2 (base image) in
`browsevm/browsevm.sh build`; step 3 (domain, unit, polkit rule, launcher) in
`browsevm/browsevm.sh install`. Steps 4-5 not done yet.

## Goal
- random links never reach the daily user's files or the system
- a browser only (Mullvad Browser), sound on, 4 GiB RAM, CPU graphics (no GPU)
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
- guest: Fedora minimal + `cage` (Wayland kiosk) + Mullvad Browser full screen, auto login
  of a user without sudo. The browser as shipped, security level Safer. Nothing else
- disk: base image `/var/lib/libvirt/images/browsevm-base.qcow2`, never the VM's own
  disk. The VM runs on a qcow2 overlay made new at every start, in RAM (tmpfs), gone at
  stop: every start is clean, downloads / cookies / malware gone at power off and never
  on the disk. The base is read-only for the VM (SELinux label, below)
- updates: admin only: a new base built from the kept ISO (`build --force --iso`, about
  10 min). Weekly or after a Mullvad Browser release
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
- machine q35 + BIOS, the same in the build and in `domain.xml`
- `virt-install --location` (Fedora Everything tree, or `--iso` a local Everything
  netinst ISO: installer from the ISO, `inst.stage2=hd:LABEL=<volume label>`, needs
  xorriso) + `browsevm/browsevm.ks` injected into the initrd (only the kickstart is
  carried over to the installed system: everything else is written from its %post),
  `--graphics none`, serial
  console on a pty logged by virtlogd to `/var/log/libvirt/qemu/browsevm-build-*.serial.log`
  (QEMU never opens a file itself), `--noreboot`; the kickstart powers off. Build domain
  undefined after, disk kept
- progress line every 20 s: minutes, disk size, last installer line (Ctrl+C: domain destroyed)
- before anything is touched: install tree reachable (6 tries, 10 s apart: a VPN that
  just reconnected), speed probe (`images/pxeboot/vmlinuz` of the tree; under
  `BROWSEVM_MIN_KBPS`, 200 KB/s, it stops), Mullvad's rpm repository reachable. Only then
  the old base is moved to `.old`
- network `browse` during the install (started and stopped again if it was off):
  packages come through Mullvad like any VM traffic
- kickstart: Fedora `@core` + cage + Xwayland + gtk3 and the other libraries a Firefox
  build needs + pipewire + mesa (CPU rendering) + DejaVu / Noto Arabic fonts; no firefox,
  openssh-server, qemu-guest-agent,
  spice-vdagent, plymouth. root locked, user `web` locked password, no sudo. SELinux
  enforcing, firewalld zone drop, no sshd, dnf-makecache off, journal volatile, UTC,
  no IPv6
- kiosk: `cage@tty1.service` (cage wiki unit, `PAMName=cage`) runs
  `/usr/local/bin/browsevm-kiosk`: the browser full screen, in the foreground for as long
  as one of its processes lives (its start script may detach), then cage ends and the
  unit starts both again (`RestartSec=2`). CPU renderer (`WLR_RENDERER=pixman`), keyboard us + ara
  (Alt+Shift). `NoNewPrivileges=yes`: nothing the browser starts gains privileges through
  setuid / file capabilities
- no text console on any VT: Fedora 45's console is kmscon (tty1-6), a DRM client that
  holds the display exclusively, so its login prompt was on screen instead of the kiosk
  (first start 2026-11-14). kmscon removed (or masked), `kmsconvt@` / `getty@` masked,
  logind `NAutoVTs=0`, cage `Conflicts=` both
- browser: Mullvad Browser (the Tor Browser without Tor, made by the Tor Project with
  Mullvad; Privacy Guides' pick for anti-fingerprinting together with a VPN). Why not
  Firefox + our policy: every session here is a new profile behind the same VPN, so what
  is left to link sessions is the browser's fingerprint, and that is what this browser
  makes the same for all its users. So it is left as shipped (uBlock Origin, NoScript and
  the Mullvad extension come with it): no policy, no extra add-on of ours, one choice of
  the browser's own: the security level (below)
- installed in `%post` the way Mullvad documents it for Fedora: repo file from
  `repository.mullvad.net/rpm/stable/mullvad.repo`, `dnf install mullvad-browser`.
  `gpgcheck=1` is forced into the repo file and a file without a `gpgkey` line is
  refused: dnf checks the package against Mullvad's key (key from the same site over
  TLS, as in Mullvad's guide). Not installed = `BROWSEVM: MISSING mullvad-browser`
- X11 on cage's Xwayland: the browser's own default (the Tor Project keeps Wayland off
  in it); without Xwayland the kiosk script sets `MOZ_ENABLE_WAYLAND=1`
- to expect: letterboxing (grey margins around the page), English for web pages asked
  at first start, a site may break under its fingerprinting protection, a black screen
  for up to a minute after the start (the browser's first start is headless, below)

## Security level Safer
- the browser's own security level (shield icon), the Tor Project's three levels:
  Standard (shipped default), Safer (JavaScript off on non-HTTPS sites; JIT off, some
  fonts and math symbols off, audio / video click to play, everywhere), Safest (also
  JavaScript off on every site). browsevm: Safer at every start (Safest breaks most
  sites)
- a site that needs JavaScript over plain http: NoScript button in the toolbar ->
  `Temp. TRUSTED` for that site. Session only: gone when the browser closes (cage starts
  it again) and with the VM's disk at stop. A temp-trusted site runs JavaScript with the
  other Safer limits (no JIT: slower)
- Safer is a level the browser offers to all its users: who uses it looks like the others
  at Safer (a smaller crowd than Standard; the attack surface is what counts here: random
  links, JIT bugs are a common browser exploit path)
- how: the kiosk runs the browser with a fixed profile (`--profile
  /home/web/.browsevm/profile`, on the VM's throwaway disk like everything else) with a
  `user.js` (root's, read-only for the browser):
  ```
  user_pref("browser.security_level.security_slider", 2);   // 4 Standard, 2 Safer, 1 Safest
  user_pref("browser.security_level.security_custom", false);
  user_pref("extensions.hideNoScript", false);                // NoScript button shown
  ```
  `extensions.hideNoScript`: the Tor Project hides NoScript's button by default
  (tor-browser#41581, MR 816); false = in the toolbar of a new profile
- first start of every VM start is headless (`--headless about:blank`, closed with TERM
  once `extensions.json` is written + 8 s, KILL after 20 s more): a level set before the
  first start of a new profile was only applied after a restart (Tor forum: Tor Browser
  12.0 `user.js` not respected on first start; tor-browser#44687 in 16.0a4 changelog:
  security level needs a restart in a new profile). The window shows the second start
- changing the level by hand in the VM needs the browser's restart (Privacy Guides 2025:
  the slider is only fully applied after a restart): close the browser, cage starts it
  again with the `user.js` level (Safer). So the level in the VM is always Safer
- checked in every report run: a local test page over http (below) must stay green

## Mullvad Browser Extension: permissions given in the image
- shipped with the browser, on by default. Its proxy feature (Mullvad SOCKS proxy per site
  or for the browser, only inside a Mullvad tunnel) needs optional permissions: `proxy`,
  `tabs`, all sites (`<all_urls>`). Asked at first use, and every VM start is a new
  profile: it would ask in every session
- the image's profile holds `extension-preferences.json` (web, 0600):
  ```
  {"{d19a89b9-76c1-4a61-bcd4-49e8de916403}":{"permissions":["proxy","tabs"],"origins":["<all_urls>"]}}
  ```
  Firefox keeps granted optional permissions in the profile's `extension-store`; a new
  profile takes them over once from this file (the older store's format). Firefox only
  uses stored permissions the extension's manifest lists as optional (Mozilla bug
  1766915)
- the build prints the shipped extensions (`distribution/extensions/*.xpi`, the file
  name is the add-on ID); the report prints whether the file was taken over and what
  `extension-store` holds (`MULLVAD-EXT-PERMS stored`)
- the extension then reaches `api.mullvad.net` (proxy list) and `am.i.mullvad.net`
  (connection check) when its popup opens, like everywhere else
- result lines `BROWSEVM:` (browser version, missing libraries, packages yes / no, SELinux,
  zone, target, units, consoles, release) printed by the build from the serial log
- base image: `/var/lib/libvirt/images/browsevm-base.qcow2`, root 0600, never booted
  for browsing

## Start / view from the daily user (step 3, built)
```
sudo rpm-ostree install virt-viewer && systemctl reboot   # remote-viewer, once
sudo DAILY_USER=<daily user> browsevm/browsevm.sh install # again after a change; VM off
```
Daily user: app grid `browsevm` (or `browsevm` in a terminal). Window closed = VM stopped.
- domain `browsevm` (`browsevm/domain.xml`, copy of what was defined in
  `/etc/browsevm/domain.xml`): 4 GiB, 2 vCPU, host-passthrough CPU, virtio disk + net,
  virtio-gpu 1920x1080 (no GL), virtio tablet (pointer without an agent), ich9 sound with
  the output codec only + SPICE audio, virtio rng. `<controller type='usb' model='none'/>`
  (no USB, so no redirection), `<memballoon model='none'/>`, no serial console, no
  channels (vdagent, guest agent), no shares. SPICE: `<clipboard copypaste='no'/>`,
  `<filetransfer enable='no'/>`, image compression off (local socket)
- disk: `/var/lib/libvirt/browsevm-run/browsevm-run.qcow2`, a qcow2 overlay with the
  base as backing file (`qemu-img create -f qcow2 -F qcow2 -b <base>`) on a tmpfs that
  `browsevm-ctl` mounts at start (`size=2g`, nosuid, nodev, noexec, root directory
  `virt_image_t`) and unmounts at stop: what a session writes is in RAM only (tmpfs pages
  can go to swap: this is for a host whose swap is zram or encrypted), at most 2 GiB (a
  full tmpfs pauses the VM), gone with the unmount; a tmpfs left by a VM that died is
  unmounted at the next start.
  libvirt's own `<transient/>` on the base was dropped after the first run (2026-11-14):
  the base is the domain's disk there, so it kept the VM's read-write label
  (`svirt_image_t` + the VM's MCS pair, owner `qemu`) while the VM ran and after it
  stopped: a taken-over QEMU process could have changed the base for every later start
- `browsevm.service` (oneshot, `RemainAfterExit`, never enabled) runs
  `/usr/local/sbin/browsevm-ctl` as root. start: tmpfs + new overlay, network `browse`
  up if off, `/run/browsevm`, `virsh start`, socket handed over. stop: `virsh shutdown`,
  destroy after 20 s, tmpfs unmounted, base back to root 0600 `virt_image_t`, network down
  (unless a build uses it), `/run/browsevm` removed. A failed start leaves nothing behind
- SPICE socket `/run/browsevm/spice.sock`: made by QEMU itself (user `qemu`, `svirt_t`),
  so the directory is `qemu`'s, type `qemu_var_run_t` (the type `svirt_t` may create
  sockets in; `chcon` at every start, /run is a tmpfs), mode 0750, group = the daily
  user's own group. After the start the socket gets that group and 0660, and directory +
  socket get the VM's MCS pair (`chcon -l`, read from `virsh dominfo`): root and the
  daily user can connect, the QEMU process of another VM (same Unix user `qemu`, other
  pair) cannot. Who connects owns the VM's screen and keyboard, nothing on the host. No
  TCP listener, no password needed
- polkit rule `/etc/polkit-1/rules.d/60-browsevm.rules`: the daily user may `start`
  `browsevm.service` from a local active session and `stop` it from anywhere (logout,
  session closing; `org.freedesktop.systemd1.manage-units`, `action.lookup("unit")`,
  `("verb")`). No other unit, no restart / enable, no libvirt group (= root-equivalent). The user name
  comes from `DAILY_USER` at install (`/etc/browsevm/view-user`), not from the repo
- `/usr/local/bin/browsevm` (desktop entry `browsevm`): `systemctl start`, then
  `remote-viewer --title browsevm --spice-disable-usbredir spice+unix:///run/browsevm/spice.sock`, then
  `systemctl stop` when the window closes. One window at a time (lock). A VM left
  running without a window (logout, crash of the viewer) is stopped first: every window
  is a new clean VM
- the guest's size is fixed (1920x1080, no agent to resize it): the viewer scales it
- links: typed in the VM. No way to hand one over from the host (no clipboard, by design)
- GNOME asks once "Allow inhibiting shortcuts" for Remote Viewer: Allow = Alt+Tab, Super
  ... go to the VM while its window has the focus (Super+Escape gives them back)

## SELinux (host)
- QEMU: `svirt_t` + a random MCS pair per start (sVirt, dynamic label), seccomp sandbox
  and private /dev from libvirt's defaults
- overlay (the VM's disk): `svirt_image_t` + that pair: this VM only, read-write
- base image: `virt_content_t` while the VM runs (libvirt's label for a backing file:
  `svirt_t` may read it, never write it), owner `qemu` for the read. At rest
  `virt_image_t`, root 0600 (`browsevm-ctl` at start and stop: libvirt does not put a
  backing file back)
- SPICE socket + its directory: `qemu_var_run_t` + the VM's MCS pair
- every VM on this host (`harden-workstation.sh svirt`): booleans `virt_use_usb` and
  `virt_use_nfs` off (policy / Fedora default: on), so no QEMU process gets a host USB
  device or a file on NFS; `security_require_confined = 1` in `/etc/libvirt/qemu.conf`:
  a domain with `<seclabel type='none'/>` is refused
- in the guest: SELinux enforcing, but cage and the browser run in the unit's domain
  (not a confined user). Open: `xguest_u` / `user_u` for the kiosk user, a trial of its own
- refs: libvirt "QEMU command-line passthrough" kbase (labels: read-only
  `virt_content_t`, exclusive `svirt_image_t:s0:MCS`; seccomp), RHEL "sVirt labeling",
  selinux-policy `virt.te` (`read_files_pattern(virt_domain, virt_content_t, ...)`,
  `manage_sock_files_pattern(virt_domain, qemu_var_run_t, ...)`)

## Looking inside (report)
```
sudo browsevm/browsevm.sh report     # VM off; about 3 min
```
- nobody can log in to the VM. The image's `browsevm-report.service` writes the kiosk's
  state to the first serial port once the test page was asked for (1-3 min after boot):
  cage unit + its journal, SELinux label and no_new_privs of cage / the browser, X11 or
  Wayland, sessions, consoles, AVC denials, security level, script test, network, sound
  cards, errors
- security level: seconds of the headless first start (ended by TERM / KILL), the
  browser's command line (`--profile`), `prefs.js` lines `security_level` /
  `hideNoScript`, `NOSCRIPT-BUTTON toolbar` when NoScript's button is in the toolbar state
- script test: `browsevm-reportmode.service` (only when the domain has a serial port,
  before cage) flags the run (`/run/browsevm-report-mode`) and starts
  `browsevm-jstest.socket` (127.0.0.1:8088, never enabled; one `DynamicUser` service per
  request, request lines to the journal). The kiosk opens that page: green text, and a
  script that turns it red and asks for `/js-ran`. `SCRIPT-TEST blocked` = page asked
  for, no `/js-ran` (an http page: blocked at Safer and Safest; which one = the
  `prefs.js` line `security_slider", 2` for Safer); `ran` = the script ran (Standard); `no-page` =
  the browser never asked for it. The screenshot shows the page
- the browsing domain has no serial port: the open fails, nothing is sent. `report`
  defines the domain once with a serial port (logged by virtlogd to
  `/var/log/libvirt/qemu/browsevm-report.serial.log`), starts it through the unit, prints
  the report, stops it, defines the normal domain again

## Residual risk
- QEMU / KVM escape + SELinux bypass; CPU side channels
- what is typed in the VM browser is seen there: no logins to real accounts
- a needed file has no way out (by design)

## Steps
1. network: `browse`, firewalld zone + policies, hostfw `if_vm_iso`, kvmlan (done)
2. base image: unattended Fedora minimal install (kickstart), cage + Mullvad Browser (done)
3. domain XML (overlay disk, removed devices, sound), unit, polkit rule, desktop file
   (done)
4. checks: `ps -Z` (svirt_t + MCS), overlay gone after shutdown, no clipboard, sectop flows,
   lab VM and LAN unreachable, Mullvad disconnect = no internet
5. README, deviations, rollback, verification rows
