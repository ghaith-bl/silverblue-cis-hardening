# browsevm: throwaway VM for random links

Status: step 1 (network) in `harden-workstation.sh browsevm`; step 2 (base image) in
`browsevm/browsevm.sh build`; step 3 (domain, unit, polkit rule, launcher) in
`browsevm/browsevm.sh install`; step 4 (checks) in `browsevm/browsevm.sh report` and the
list below; updates in `browsevm/browsevm.sh update` + a daily timer. README,
deviations, rollback, verification rows: done (2026-11-17). Viewer relay + sandbox:
beta (2026-11-18).

## Goal
- random links kept away from the daily user's files and the system: an exploit must
  escape the browser, the guest kernel and QEMU (sVirt, below) first
- a browser only (Mullvad Browser or Brave, chosen per start), sound on, 4 GiB RAM, CPU
  graphics (no GPU)
- nothing leaves the VM: no clipboard, no shared folder, no USB, no file export
- refs: NIST SP 800-53 SC-44 (detonation chambers), SC-39 (process isolation), AC-6;
  CIS Controls v8.1 Control 9 (email and web browser protections); Qubes OS disposable VMs

## Why a VM, not a third user
- a third user = DAC on the same kernel: browser exploit + kernel LPE = the whole host
- VM: the exploit must also escape QEMU, and lands in `svirt_t` with its own MCS
  category (sVirt), as user `qemu`: no access to the homes, /etc, other VM disks
- `qemu:///system` only. GNOME Boxes / `qemu:///session`: QEMU runs as the daily user,
  an escape = the daily user's files

## Shape
- guest: Fedora minimal + `cage` (Wayland kiosk) + one browser full screen, auto login of
  a user without sudo: Mullvad Browser (as shipped, security level Safer) or Brave
  (managed policies), the host picks per start (two app grid entries). Nothing else
- disk: base image `/var/lib/libvirt/images/browsevm-base.qcow2`, never the VM's own
  disk. The VM runs on a qcow2 overlay made new at every start, in RAM (tmpfs), gone at
  stop: every start is clean, downloads / cookies / malware gone at power off, not
  written to the disk itself (tmpfs; its pages may go to swap, below). The base is
  read-only for the VM (SELinux label, below)
- updates: a new base built from the kept ISO (`update`, about 10 min, both browsers and
  Fedora at their newest): `browsevm-update.timer` checks daily, rebuilds when the base
  is 7 days old (below)
- 4 GiB RAM, 2 vCPU, base disk ~12 GiB
- removed: spice-vdagent / spicevmc channel (clipboard), virtiofs / 9p, USB redirection,
  smartcard, GL. Sound: ich9 + SPICE audio (the host has no capture nodes: `mic` section)
- display: SPICE on a unix socket only, never TCP

## Network (step 1, built)
- libvirt network `browse` on `virbr-browse`, the /24 of `BROWSEVM_NET` (default 192.168.123), NAT, not autostarted
- not `default`: hostfw accepts virbr0 <-> virbr0 (`fwd_vm_cross`): lab VMs reachable
- hostfw `if_vm_iso`: out to the tunnel only; no new flow to / from another bridge or the
  uplink (rule `fwd_vm_iso`, counter / log `fwd_vm_lan`)
- firewalld: zone `browsevm`; policy `browsevm-to-host` REJECT with DHCP and DNS to
  192.168.123.1 only (rich rule: a service in a policy is open on every host address; the
  lab network's dnsmasq on 192.168.122.1:53 answered the VM, probe 2026-11-17);
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
- refused while the VM runs (`browsevm@<browser>.service` active) or while any domain's
  XML names the base (a running VM: its overlay's backing file; an old definition with
  the base as its disk): stop / undefine first. Holds `/run/browsevm-build.lock` (flock):
  no VM start (`browsevm-ctl`, the launcher) while the base is being replaced
- `/run/browsevm-last-build`: path of this build's serial log (for `update`)
- before anything is touched: install tree reachable (6 tries, 10 s apart: a VPN that
  just reconnected), speed probe (`images/pxeboot/vmlinuz` of the tree; under
  `BROWSEVM_MIN_KBPS`, 200 KB/s, it stops), Mullvad's and Brave's rpm repositories
  reachable. Only then the old base is moved to `.old`
- network `browse` during the install (started and stopped again if it was off):
  packages come through Mullvad like any VM traffic
- kickstart: Fedora `@core` + cage + Xwayland + gtk3 and the other libraries a Firefox
  build needs + pipewire + mesa (CPU rendering) + DejaVu / Noto Arabic fonts; no firefox,
  openssh-server, qemu-guest-agent,
  spice-vdagent, plymouth. root locked, user `web` locked password, no sudo. SELinux
  enforcing, firewalld zone drop, no sshd, dnf-makecache off, journal volatile, UTC,
  no IPv6
- kiosk: `cage@tty1.service` (cage wiki unit, `PAMName=cage`) runs
  `/usr/local/bin/browsevm-kiosk`: the chosen browser full screen, in the foreground for as long
  as one of its processes lives (its start script may detach), then cage ends and the
  unit starts both again (`RestartSec=2`). CPU renderer (`WLR_RENDERER=pixman`), keyboard us + ara
  (Alt+Shift). `NoNewPrivileges=yes`: nothing the browser starts gains privileges through
  setuid / file capabilities. cage, Xwayland and the browser run as the confined SELinux
  user `user_u` (below). Its output goes to the journal
- no text console on any VT: Fedora 45's console is kmscon (tty1-6), a DRM client that
  holds the display exclusively, so its login prompt was on screen instead of the kiosk
  (first start 2026-11-14). kmscon removed (or masked), `kmsconvt@` / `getty@` masked,
  logind `NAutoVTs=0`, cage `Conflicts=` both. `serial-getty@` masked too (the install's
  `console=ttyS0` stays on the kernel line: systemd started a login prompt on the serial
  port of report runs)
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
- second browser: Brave (Chromium; fingerprint randomized per site and session instead
  of one look for everybody: more sites work, where Mullvad Browser's protections or its
  shared look break them). Installed the way Brave documents it for Fedora Atomic: repo
  file `brave-browser-rpm-release.s3.brave.com/brave-browser.repo` into
  `/etc/yum.repos.d`, `dnf install brave-browser`; same `gpgcheck=1` / `gpgkey` rules.
  Not installed = `BROWSEVM: MISSING brave-browser`
- Brave policies `/etc/brave/policies/managed/browsevm.json`: the host's
  `browsers/brave/policies.json` without its extension allowlist (no extension at all)
  plus `DefaultJavaScriptJitSetting` 2 and `DefaultJavaScriptOptimizerSetting` 2 (V8 JIT
  and optimizers off on every site: Brave's "Safer"; JIT off = slower JavaScript, fewer
  exploitable engine paths). Nothing sent by itself: P3A, usage ping, Web Discovery
  (sends browsing data to build Brave Search's index), metrics / crash reports, surveys
  all off; Rewards, Wallet, VPN, Leo, News, Talk, Tor windows off; Shields aggressive,
  HTTPS only, WebRTC `disable_non_proxied_udp`, no sign-in / sync / passwords / autofill
- Brave in the kiosk: `brave-browser --no-first-run --no-default-browser-check
  --disable-gpu --ozone-platform=x11 --user-data-dir=/home/web/.browsevm/brave` (Wayland
  without Xwayland), throwaway like the rest. Its sandbox: user namespaces (the setuid
  helper is useless under `NoNewPrivileges`)
- which one: `browsevm-select.service` (root, before cage) reads the SMBIOS OEM string
  `browsevm-browser mullvad|brave` (`/sys/firmware/dmi/entries/11-0/raw`, root only),
  writes `/run/browsevm-browser` (0644, for the report) and `/run/browsevm-browser.env`
  (`BROWSEVM_BROWSER=<name>`, read by systemd: cage unit `EnvironmentFile=`, the confined
  kiosk user needs no read in /run); nothing / anything else = Mullvad
- to expect: letterboxing (grey margins around the page), English for web pages asked
  at first start, a site may break under its fingerprinting protection, a black screen
  for up to a minute after the start (the browser's first start is headless, below).
  Such a site: try it in Brave

## Security level Safer
- the browser's own security level (shield icon), the Tor Project's three levels:
  Standard (shipped default), Safer (JavaScript off on non-HTTPS sites; JIT off, some
  fonts and math symbols off, audio / video click to play, everywhere), Safest (also
  JavaScript off on every site). browsevm: Safer at every start (Safest breaks most
  sites)
- NoScript (shipped) is what applies the level: it stays; its toolbar button stays
  hidden (the Tor Project's default, tor-browser#41581). A site that breaks: Brave
- Safer is a level the browser offers to all its users: who uses it looks like the others
  at Safer (a smaller crowd than Standard; the attack surface is what counts here: random
  links, JIT bugs are a common browser exploit path)
- how: the kiosk runs the browser with a fixed profile (`--profile
  /home/web/.browsevm/profile`, on the VM's throwaway disk like everything else) with a
  `user.js` (root's, read-only for the browser):
  ```
  user_pref("browser.security_level.security_slider", 2);   // 4 Standard, 2 Safer, 1 Safest
  user_pref("browser.security_level.security_custom", false);
  ```
- first start of every VM start is headless (`--headless about:blank`, closed with TERM
  once `extensions.json` is written + 8 s, KILL after 20 s more): a level set before the
  first start of a new profile was only applied after a restart (Tor forum: Tor Browser
  12.0 `user.js` not respected on first start; tor-browser#44687 in 16.0a4 changelog:
  security level needs a restart in a new profile). The window shows the second start
- changing the level by hand in the VM needs the browser's restart (Privacy Guides 2025:
  the slider is only fully applied after a restart): close the browser, cage starts it
  again with the `user.js` level (Safer). So the level in the VM is always Safer
- checked in every report run: `prefs.js` line `security_slider", 2` (below). The first
  report runs (2026-11-14) also opened a local http test page: JavaScript blocked on the
  first window of a new VM

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
  1766915). Mullvad Browser 16.0.1 reads this file in place (no `extension-store` was
  made): proxy settings opened without a prompt (2026-11-14)
- the build prints the shipped extensions (`distribution/extensions/*.xpi`, the file
  name is the add-on ID); the report prints whether the file is still there
- the extension then reaches `api.mullvad.net` (proxy list) and `am.i.mullvad.net`
  (connection check) when its popup opens, like everywhere else
- result lines `BROWSEVM:` (browser version, missing libraries, packages yes / no, SELinux,
  zone, target, units, consoles, release) printed by the build from the serial log.
  Missing libraries = `ldd` of `libxul.so` with `LD_LIBRARY_PATH` = its own directory
  (the browser's own libraries are there; its start script sets the same path)
- base image: `/var/lib/libvirt/images/browsevm-base.qcow2`, root 0600, never booted
  for browsing

## Start / view from the daily user (step 3, built)
```
sudo rpm-ostree install virt-viewer && systemctl reboot   # remote-viewer, once
sudo DAILY_USER=<daily user> browsevm/browsevm.sh install # again after a change; VM off
```
Daily user: app grid `browsevm Mullvad` / `browsevm Brave` (or `browsevm [mullvad|brave]`
in a terminal). Window closed = VM stopped.
- domain `browsevm` (`browsevm/domain.xml`, copy of what was defined in
  `/etc/browsevm/domain.xml`): 4 GiB, 2 vCPU, host-passthrough CPU (below), virtio disk +
  net, virtio-gpu 1920x1080 (no GL), virtio tablet (pointer without an agent), ich9 sound with
  the output codec only + SPICE audio, virtio rng. `<controller type='usb' model='none'/>`
  (no USB, so no redirection), `<memballoon model='none'/>`, no serial console, no
  channels (vdagent, guest agent), no shares. SPICE: `<clipboard copypaste='no'/>`,
  `<filetransfer enable='no'/>`, image compression off (local socket). `<sysinfo
  type='smbios'><oemStrings><entry>browsevm-browser mullvad</entry>` + `<os><smbios
  mode='sysinfo'/>`: the browser of the next start
- CPU `host-passthrough` (decision 2026-11-17): QEMU's recommended mode when a VM is never
  live-migrated. The guest gets the host CPU's mitigation flags (`spec-ctrl`, `md-clear`,
  `ssbd`, ...) and its kernel uses them: it runs hostile code. Fingerprint: no web API
  gives the CPU model; the core count is a fixed value in Mullvad Browser and randomized
  per site and session in Brave. Code that escaped the browser can read the model in the
  guest (`/proc/cpuinfo`): a CPU type, not this laptop. `host-model` not tested: no gain
  here
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
- `browsevm@.service` (instances `browsevm@mullvad`, `browsevm@brave`; oneshot,
  `RemainAfterExit`, never enabled) runs `/usr/local/sbin/browsevm-ctl` as root. start
  `<browser>`: refused while a build holds the lock or the VM runs with the other
  browser; the browser into the domain's OEM string (`virsh dumpxml --inactive`, `sed`
  on the entry, `virsh define`: a report run's serial port stays), tmpfs + new overlay,
  network `browse` up if off, `/run/browsevm`, `virsh start`, socket handed over. stop: `virsh shutdown`,
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
  `browsevm@mullvad.service` / `browsevm@brave.service` from a local active session and
  `stop` them from anywhere (logout,
  session closing; `org.freedesktop.systemd1.manage-units`, `action.lookup("unit")`,
  `("verb")`). No other unit, no restart / enable, no libvirt group (= root-equivalent). The user name
  comes from `DAILY_USER` at install (`/etc/browsevm/view-user`), not from the repo
- `/usr/local/bin/browsevm [mullvad|brave]` (desktop entries `browsevm Mullvad`,
  `browsevm Brave`): `systemctl start browsevm@<browser>`, then `/usr/bin/remote-viewer
  --title "browsevm <browser>" --spice-disable-usbredir
  spice+unix:///run/browsevm/spice.sock` (through the relay and the sandbox below), then
  `systemctl stop` when the window closes. One window at a time (lock). A VM left
  running without a window (logout, crash of the viewer) is stopped first: every window
  is a new clean VM. While the base is rebuilt (build lock taken): a note, no start.
  Wayland only: no Wayland session = refused; the viewer gets `GDK_BACKEND=wayland` and
  no `DISPLAY`
- viewer crash on Wayland: GTK 3 ends a client with `_exit(1)` when its socket to GNOME
  Shell is full (`Gdk-Message: Error flushing display: Resource temporarily unavailable`,
  Brave on a busy page, 2026-11-15; 6 drops in 2 min on 2026-11-18 = VM stopped). Fix:
  the relay below. Kept as a second line: with that line (or `dispatching to Wayland
  display`, or the relay's `queue limit`) in the viewer's stderr and the unit still
  active, the launcher opens the viewer again on the same VM (up to 5 times in 2 min).
  Not `GDK_BACKEND=x11`: on Xwayland other X11 clients could read what is typed into the
  VM
- install removes an old `browsevm.service` (before 2026-11-15: one browser)
- the guest's size is fixed (1920x1080, no agent to resize it): the viewer scales it
- links: typed in the VM. No way to hand one over from the host (no clipboard, by design)
- GNOME asks once "Allow inhibiting shortcuts" for Remote Viewer: Allow = Alt+Tab, Super
  ... go to the VM while its window has the focus (Super+Escape gives them back)

## Viewer: relay + sandbox (beta, 2026-11-18)
What the window path carries: the VM's screen and sound to the host, keys and pointer
into the VM. Risks, in order: (1) another host program reads the keys / the screen, (2)
the viewer as a way in: it parses data the VM controls (pictures, cursor shapes, sound)
and ran as the daily user (home, network, session bus), (3) the window drops (only
availability; it fails safe: VM stopped, overlay gone). A fix for (3) may not weaken (1)
or (2).

Rejected: `GDK_BACKEND=x11` (breaks 1); bigger socket buffers for every program
(`net.core.wmem_default`: system-wide for one program, only delays the drop); a preload
library inside remote-viewer (compiler / binary in the repo, the window freezes
instead); QEMU drawing the window itself (gives `svirt_t` the desktop); another viewer /
protocol (no sound, or not packaged; same parsing risk).

Relay (`browsevm/browsevm-wlrelay.py`, installed `/usr/local/lib/browsevm/`, run with
`python3 -I`):
- why: GTK 3 calls `_exit(1)` on any `wl_display_flush()` error, EAGAIN included
  (`gdk/wayland/gdkeventsource.c`, still so on gtk-3-24 2026-10); a busy GNOME Shell
  that reads late = a full socket. Firefox ships the same kind of relay (wayland-proxy,
  Firefox 121)
- connects to GNOME Shell first, then starts the viewer with its end of a socketpair as
  `WAYLAND_SOCKET` (no path on disk: no other process can connect; `WAYLAND_DISPLAY` and
  `DISPLAY` removed: the relay is the viewer's only way to the screen). No compositor =
  the viewer is not started (no X11 fallback)
- reads both sides at once, keeps what the other side cannot take yet; bytes and fds
  passed on unchanged, never parsed (no new parser = almost no new attack surface); fds
  leave with or before their bytes, at most 28 per send (libwayland `MAX_FDS_OUT`, the
  most its receiver takes at once)
- limits per direction: 64 MiB, 8192 waiting fds: above one the viewer is ended (exit
  75, `browsevm-wlrelay: queue limit`) and the launcher opens it again
- one line at the end (stderr + the launcher's journal line): largest queue, longest
  wait per direction (= how long GNOME Shell did not read), end reason. No content
- tested off the host (2026-11-18, a libwayland 1.22 test client + compositor; the client
  exits like GTK 3 on a failed flush): compositor busy 3 s, 400000 requests (8000 with
  an fd): without the relay `Error flushing display` at once; with it no drop, every fd
  matched its request, longest wait 3.06 s. Same with the launcher + bwrap as an
  unprivileged user. Unit tests: `tests/` (CI)

Sandbox (`bwrap`, from Silverblue's base: Flatpak uses it):
- `--unshare-all --unshare-user --disable-userns --die-with-parent --new-session
  --clearenv`: own user / pid / ipc / uts / cgroup / network namespace (loopback only),
  no new user namespace inside (a common kernel exploit path), no capabilities,
  no_new_privs, no terminal to push keys into
- files: `/usr` read-only; from `/etc` only fonts, ld.so.cache, nsswitch.conf,
  localtime, pulse, crypto-policies, xdg, gtk-3.0 and a passwd / group with this user's
  own line; home = empty tmpfs (gone at the end: no recent-files list of the socket);
  `/tmp` tmpfs; `/dev` minimal (no `/dev/snd`, no `/dev/dri`: no direct sound devices,
  no GPU driver surface); no `/sys`
- sockets: the SPICE socket, the relay's fd, the PulseAudio socket
  (`$XDG_RUNTIME_DIR/pulse/native`, pipewire-pulse) for sound. No session bus (no
  systemd user manager, no Secret Service), no X11, no other runtime socket
- env: `GDK_BACKEND=wayland`, `GSETTINGS_BACKEND=memory`, `NO_AT_BRIDGE=1`,
  `GIO_USE_VFS=local`
- why so little: through the SPICE socket the viewer still talks to the VM (keys,
  pointer): a taken-over viewer could pass what it reads back into the VM, which has the
  internet. So it gets nothing worth taking
- user namespaces: already on (deviations: Flatpak, Podman, Brave); the launcher tests
  the sandbox before it starts the VM and refuses if it fails

Left (beta):
- the sound socket can also record (other programs' sound: monitor sources); no
  microphone (`mic` section). Per-client PipeWire permissions: later
- no seccomp filter yet (Flatpak's list would be next), the viewer is still
  `unconfined_t` (an SELinux domain for it: later)
- the relay runs outside the sandbox (it must reach GNOME Shell); it only moves bytes
- GNOME Shell sees the relay's pid as the client's (app found by its app id)

Switches (per start, a note says when one is off): `BROWSEVM_RELAY=0` /
`BROWSEVM_SANDBOX=0 browsevm brave`. Every end of the viewer: `journalctl -t browsevm`
as the daily user (exit status, layers, seconds, the relay's numbers).

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

## SELinux (guest): the kiosk as a confined user (2026-11-17)
- user `web` mapped to `user_u` in `%post` (`usermod -Z user_u web`): cage, Xwayland, both
  browsers, PipeWire, the user's systemd run as `user_u:user_r:user_t` (dbus-broker:
  `user_dbusd_t`). Before: `unconfined_service_t` (the unit's domain)
- user_t: no su / sudo / setuid gain (with `NoNewPrivileges` on top), no admin rights,
  own home + tmp only, no access to system files a service domain may touch
- how: `/etc/pam.d/cage` `pam_selinux.so close` ... `pam_selinux.so open`, as
  `/etc/pam.d/systemd-user` and login do. Policy (fedora-selinux selinux-policy):
  `user_u_default_contexts` maps `system_r:init_t:s0` to `user_r:user_t:s0`; `init.te`
  `userdom_transition_login_userdomain(init_t)` +
  `userdom_nnp_transition_login_userdomain(init_t)`: the transition is allowed under
  `NoNewPrivileges`; `allow login_userdomain self:user_namespace create` (both browsers'
  sandboxes)
- the tty: pam_selinux relabels tty1 `user_tty_device_t` for the session (back at close,
  like login). With `nottys` (as systemd-user) cage was refused its tty
  (`user_t -> tty_device_t {read write}`) and exited at once (trial 1)
- `user_u`, not `xguest_u`: Fedora's confined user tests run against user_u; xguest is
  made for GDM guest logins, its network only http / generic ports
  (`xguest_connect_network`)
- report: `seuser web: user_u`, `kiosk id -Z`, label of every process of `web`, tty1
  label, AVC count grouped by program / types. 2026-11-17: every process `user_t`
  (except `(sd-pam)` = `init_t`, PAM's own helper), tty1 `user_tty_device_t`
- known AVC, harmless: `Xwayland` / `glxtest` / the browser `user_t -> dma_device_t
  {read write}` on `/dev/udmabuf` (GPU buffer sharing; CPU rendering here). The rtkit
  `setsched` AVC of the unconfined kiosk is gone
- way back: `semanage login -d web` in the image (or the kickstart before 2026-11-17)
- refs: libvirt "QEMU command-line passthrough" kbase (labels: read-only
  `virt_content_t`, exclusive `svirt_image_t:s0:MCS`; seccomp), RHEL "sVirt labeling",
  selinux-policy `virt.te` (`read_files_pattern(virt_domain, virt_content_t, ...)`,
  `manage_sock_files_pattern(virt_domain, qemu_var_run_t, ...)`)

## Looking inside (report)
```
sudo browsevm/browsevm.sh report            # VM off; Mullvad Browser; about 3 min
sudo browsevm/browsevm.sh report brave      # the same with Brave
```
- nobody can log in to the VM. The image's `browsevm-report.service` (after
  `browsevm-select`) writes the kiosk's state to the first serial port once the browser's
  window is up (1-3 min after boot):
  `BROWSER <name>`, cage unit + its journal, SELinux label and no_new_privs of cage / the
  browser, X11 or Wayland, sessions, consoles, AVC denials, the browser's own section,
  network, sound cards, errors, versions
- Mullvad Browser: seconds of the headless first start (ended by TERM / KILL), its
  command line (`--profile`), `prefs.js` lines `security_level`, whether
  `extension-preferences.json` is there
- Brave: its command line, number of policy keys, the JIT / optimizer / telemetry lines of
  the policy file, `BRAVE-PROFILE present` (its data directory was made)
- the browsing domain has no serial port: the open fails, nothing is sent. `report`
  defines the domain once with a serial port (logged by virtlogd to
  `/var/log/libvirt/qemu/browsevm-report.serial.log`), starts it through the unit, prints
  the report, stops it, defines the normal domain again
- probes (step 4): `BROWSEVM_REPORT_PROBE="<ip>:<port> ..."` puts the targets into an
  SMBIOS OEM string of that one start (one more `<entry>` next to the browser's); the
  guest reads `/sys/firmware/dmi/entries/11-0/raw`. Per target one
  TCP connect (`PROBE lateral <target> OPEN|closed|timeout`), then 30 rounds (`PROBE round
  <n> start <epoch> mullvad-check ok|fail tcp-443 ok|fail`: `am.i.mullvad.net/connected`
  says connected, TCP to its address without DNS). The normal domain has no probe entry:
  nothing is probed
- known lines, harmless: `virt/tdx: TDX not supported by the host platform` (kernel, no
  TDX on this CPU); AVC on `/dev/udmabuf` (SELinux (guest), above)

## Checks (step 4)
Admin, VM off. One report run with probes, then one normal start:
- QEMU `svirt_t` + its own MCS pair, overlay `svirt_image_t:<pair>` on the tmpfs, base
  `virt_content_t` while running, root 0600 `virt_image_t` + same sha256 after, tmpfs and
  `/run/browsevm` gone after the stop (`ps -Z`, `ls -Z`, `findmnt`, `sha256sum`)
- no clipboard: live XML has `<clipboard copypaste='no'/>`, `<filetransfer
  enable='no'/>`, no `<channel>`, no `<redirdev>`, USB controller `none`; QEMU's
  `-spice` has `disable-copy-paste=on`, `disable-agent-file-xfer=on`; no `spicevmc` /
  `vdagent` on its command line. In the guest: no spice-vdagent (`pkg spice-vdagent no`)
- lab VMs / LAN / host unreachable: probes to the host on `virbr-browse` (22), the host on
  `virbr0` (22, 53), every running lab VM (22, 53, 80), the LAN gateway (80): none `OPEN`;
  192.168.123.1:53 `OPEN` (its own DNS). 2026-11-17 with `virbr0` up and lab VM running:
  only the lab network's DNS answered -> DNS rule (Network, above), then `closed`. hostfw counter
  `fwd_vm_lan` grows (forwarded tries), `tcpdump` on `virbr0`: no packet from the
  browse /24
- Mullvad disconnect = no internet: the host disconnects after round 4 and connects after
  round 10: rounds that start while disconnected all `fail fail`, rounds before `ok`, an
  `ok` again after the connect. hostfw `fwd_vm_new` grows with the VM's flows
- sectop: the firewall screen shows the VM's flows (`fwd_vm_new` lines from the browse
  /24, the counter card); looked at by hand during a session
- security level: `security_slider", 2` in `prefs.js` (2026-11-14 also: the http test
  page stayed green on the first window)
- Mullvad extension: in a session its proxy settings open without a permission prompt
- Brave: `BROWSER brave`, `BRAVE-PROFILE present`, policy lines JIT / optimizer 2,
  telemetry false; screenshot = Brave's new tab page

## Updates
```
sudo browsevm/browsevm.sh update                 # now; old base back if it fails
sudo browsevm/browsevm.sh update --if-older 7    # only when the base is 7 days old
journalctl -u browsevm-update.service            # what the daily runs did
cat /var/lib/browsevm/base.info                  # date + browser versions of the base
```
- nothing in the VM updates itself (every start is the base again): a new base is the
  update. `update` = `build --force` from the newest kept
  `Fedora-Everything-netinst-x86_64-<release>-*.iso` in `/var/lib/libvirt/images`
  (installer only; packages, both browsers and their keys from the network: always the
  newest), in a subshell, then: good (rc 0, `post done`, both browser lines) = `.old`
  deleted, `base.info` written, versions before / now printed; not good = the old base
  back (root 0600, its label). A stale `.old` from an older failed run is deleted first
- `--if-older N`: the age from `base.info` (`built <epoch>`), else the file's mtime;
  younger = exit 0. VM in use = exit 0 (the next day tries again)
- `browsevm-update.timer`: `OnCalendar=daily`, `RandomizedDelaySec=2h`, `Persistent=true`,
  `OnBootSec=15min` -> `browsevm-update.service` (oneshot, `Nice=10`, idle I/O,
  `TimeoutStartSec=3h`) runs `/usr/local/lib/browsevm/browsevm.sh update --if-older 7`:
  the root-owned copy that `install` puts there (with the kickstart), never the repo in a
  home. Enabled by `install`; off: `sudo systemctl disable --now browsevm-update.timer`
- Mullvad settings are not touched: the build runs with DAITA / multihop on (slower; under
  `BROWSEVM_MIN_KBPS` it stops before anything is replaced and the next day tries again)
- a new Fedora release: put its netinst ISO into `/var/lib/libvirt/images`, set
  `BROWSEVM_FEDORA` (or the default in `browsevm.sh`), install again

## Residual risk
- QEMU / KVM escape + SELinux bypass; CPU side channels
- what is typed in the VM browser is seen there: no logins to real accounts
- a needed file has no way out (by design)
- the viewer (beta layers): see "Viewer: relay + sandbox" (sound socket, no seccomp yet)

## Steps
1. network: `browse`, firewalld zone + policies, hostfw `if_vm_iso`, kvmlan (done)
2. base image: unattended Fedora minimal install (kickstart), cage + Mullvad Browser (done)
3. domain XML (overlay disk, removed devices, sound), unit, polkit rule, desktop file
   (done)
4. checks: `ps -Z` (svirt_t + MCS), overlay gone after shutdown, no clipboard, sectop flows,
   lab VM and LAN unreachable, Mullvad disconnect = no internet (list above) (done)
5. Brave as the second browser, `update` + daily timer (2026-11-15)
6. README, deviations, rollback, verification rows; kiosk as `user_u`; DNS to its own
   bridge only (2026-11-17)
7. viewer: Wayland relay + bwrap sandbox, beta (2026-11-18)
