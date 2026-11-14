# browsevm.ks - unattended install of the browsevm base image (Fedora minimal + cage
# kiosk + Mullvad Browser). Used by browsevm.sh build, which fills the release (@...@)
# and injects this file into the installer's initrd (only the kickstart is carried over
# to the installed system, so everything else is written from %post).
# Nothing here is a secret: the only user has a locked password and no sudo.

text
lang en_US.UTF-8
keyboard us
timezone Etc/UTC --utc
network --bootproto=dhcp --device=link --activate --hostname=browsevm --noipv6
url --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-@FEDORA@&arch=x86_64
repo --name=updates --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f@FEDORA@&arch=x86_64
rootpw --lock
user --name=web --lock --gecos="browsevm"
selinux --enforcing
firewall --enabled
bootloader --timeout=1 --append="quiet"
zerombr
clearpart --all --initlabel
autopart --type=plain --nohome --noswap
poweroff

%packages
@core
cage
xorg-x11-server-Xwayland
gtk3
dbus-glib
libXt
libX11-xcb
alsa-lib
pulseaudio-libs
pciutils-libs
pipewire
pipewire-pulseaudio
wireplumber
mesa-dri-drivers
dejavu-sans-fonts
dejavu-serif-fonts
dejavu-sans-mono-fonts
google-noto-sans-arabic-vf-fonts
google-noto-naskh-arabic-vf-fonts
-openssh-server
-qemu-guest-agent
-spice-vdagent
-plymouth
%end

%post
say() { echo "BROWSEVM: $*" > /dev/ttyS0; }

# the browser: Mullvad Browser from Mullvad's own rpm repository, the way Mullvad
# documents it for Fedora (its repo file, then dnf install). Installed here with dnf so
# the package's signature is checked: gpgcheck is forced on in the repo file whatever it
# says, and a file without a gpgkey line is refused. dnf takes Mullvad's key from that
# URL (same site, over TLS: the trust is Mullvad's web server, as in their own guide).
# Left exactly as shipped: any setting of ours would make this browser different from
# everybody else's, and looking the same is what it is for.
mb=""
repo=/etc/yum.repos.d/mullvad.repo
if curl -fsSL --retry 3 --max-time 60 -o "$repo" https://repository.mullvad.net/rpm/stable/mullvad.repo &&
   grep -q '^gpgkey *= *https://' "$repo"; then
  sed -i -e '/^gpgcheck[ =]/d' -e '/^pkg_gpgcheck[ =]/d' -e 's/^\(\[.*\]\)$/\1\ngpgcheck=1/' "$repo"
  say "browser repo key $(sed -n 's/^gpgkey *= *//p' "$repo" | head -n 1), gpgcheck $(grep -c '^gpgcheck=1' "$repo")"
  dnf -y install mullvad-browser > /tmp/mullvad-install.log 2>&1
  mb=$(rpm -q mullvad-browser 2>/dev/null) || mb=""
else
  rm -f "$repo"
  echo "repo file not downloaded, or without a gpgkey line" > /tmp/mullvad-install.log
fi
if [ -n "$mb" ]; then
  say "browser $mb"
  say "browser command $(command -v mullvad-browser || echo MISSING)"
  xul=$(rpm -ql mullvad-browser | grep -m1 '/libxul\.so$')
  miss=$(ldd "$xul" 2>/dev/null | awk '/not found/ { print $1 }' | tr '\n' ' ')
  say "browser libraries missing: ${miss:-none}"
else
  say "MISSING mullvad-browser"
  tail -n 4 /tmp/mullvad-install.log | while read -r l; do say "dnf: $l"; done
fi
rm -f /tmp/mullvad-install.log

# kiosk: cage on tty1 as user web, the browser full screen, restarted when closed.
# Unit from cage's wiki "Starting Cage on boot with systemd". pixman = CPU renderer.
# Added: kmsconvt@ next to getty@ (Fedora 45: kmscon is the console of tty1-6 and takes
# the display for itself), NoNewPrivileges (no setuid / file capability gain for
# anything the browser starts: sudo, su, pkexec are dead ends).
cat > /etc/systemd/system/cage@.service <<'UNIT'
[Unit]
Description=Cage Wayland kiosk on %I
After=systemd-user-sessions.service plymouth-quit-wait.service
Before=graphical.target
ConditionPathExists=/dev/tty0
Wants=dbus.socket systemd-logind.service
After=dbus.socket systemd-logind.service
Conflicts=getty@%i.service kmsconvt@%i.service
After=getty@%i.service kmsconvt@%i.service

[Service]
Type=simple
NoNewPrivileges=yes
Environment=WLR_RENDERER=pixman
Environment=XKB_DEFAULT_LAYOUT=us,ara
Environment=XKB_DEFAULT_OPTIONS=grp:alt_shift_toggle
ExecStart=/usr/bin/cage -- /usr/local/bin/browsevm-kiosk
ExecStartPost=+sh -c "tty_name='%i'; exec chvt $${tty_name#tty}"
Restart=always
RestartSec=2
User=web
UtmpIdentifier=%I
UtmpMode=user
TTYPath=/dev/%I
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-fail
PAMName=cage

[Install]
WantedBy=graphical.target
Alias=display-manager.service
DefaultInstance=tty1
UNIT
# what cage runs: the browser in the foreground for as long as it lives (its start
# script may detach). cage ends with its client and the unit starts both again.
# The browser's own default is X11 (the Tor Project keeps Wayland off: one more thing
# that would differ between users), so it runs on cage's Xwayland. Without Xwayland
# (no DISPLAY) it is told to use Wayland: better than no browser.
cat > /usr/local/bin/browsevm-kiosk <<'KIOSK'
#!/bin/bash
[ -n "${DISPLAY:-}" ] || export MOZ_ENABLE_WAYLAND=1
mullvad-browser "$@"
while pgrep -u "$(id -u)" -f 'mullvad-?browser' >/dev/null; do sleep 2; done
KIOSK
chmod 0755 /usr/local/bin/browsevm-kiosk
cat > /etc/pam.d/cage <<'PAM'
auth           required        pam_unix.so nullok
account        required        pam_unix.so
session        required        pam_unix.so
session        required        pam_systemd.so
PAM
systemctl enable cage@tty1.service
systemctl set-default graphical.target

# no text console on any VT: nobody can log in anyway (both accounts locked), and on
# Fedora 45 the console (kmscon) holds the display exclusively, so it showed its login
# prompt instead of the kiosk. Package removed if nothing needs it, units masked either
# way, logind starts no console when a VT is switched to.
kc=$(rpm -qa 'kmscon*')
if [ -n "$kc" ] && rpm -e $kc >/dev/null 2>&1; then
  say "kmscon removed"
else
  say "kmscon $([ -n "$kc" ] && echo "kept (needed by another package), masked" || echo "not installed")"
fi
systemctl mask kmsconvt@.service getty@.service >/dev/null 2>&1
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nNAutoVTs=0\nReserveVT=0\n' > /etc/systemd/logind.conf.d/browsevm.conf

# the kiosk's own state for the host admin. Nobody can log in to look, so a small unit
# writes it to the first serial port. The browsing domain has no serial port (the open
# fails, nothing is sent); "browsevm.sh report" starts the VM once with one.
cat > /usr/local/sbin/browsevm-report <<'REPORT'
#!/bin/bash
( : > /dev/ttyS0 ) 2>/dev/null || exit 0
sleep 45
{
  echo "BROWSEVM-REPORT begin"
  echo "-- cage unit"
  systemctl show cage@tty1.service -p ActiveState -p SubState -p NRestarts -p ExecMainStatus | tr '\n' ' '
  echo
  journalctl -b -u cage@tty1.service --no-pager -o cat -n 25 | cut -c1-200
  echo "-- processes of web: name, SELinux label, no_new_privs"
  for p in $(pgrep -u web -x cage) $(pgrep -u web -o -f 'mullvad-?browser'); do
    printf '%s  %s  nnp=%s\n' "$(cat /proc/$p/comm)" "$(tr -d '\0' < /proc/$p/attr/current)" \
      "$(sed -n 's/^NoNewPrivs:[[:space:]]*//p' /proc/$p/status)"
  done
  echo "browser processes: $(pgrep -u web -c -f 'mullvad-?browser')"
  p=$(pgrep -u web -n -f 'mullvad-?browser')
  [ -n "$p" ] && echo "display: $(tr '\0' '\n' < /proc/$p/environ | grep -E '^(DISPLAY|WAYLAND_DISPLAY|MOZ_ENABLE_WAYLAND)=' | tr '\n' ' ')"
  pgrep -a Xwayland | cut -c1-100
  echo "-- sessions"
  loginctl list-sessions --no-legend --no-pager
  echo "-- consoles"
  systemctl list-units --all --no-legend --no-pager 'getty*' 'kmscon*' 'autovt*' | cut -c1-110
  rpm -q kmscon
  echo "-- SELinux"
  getenforce
  journalctl -b --no-pager -o cat -g 'avc: +denied' -n 12 | cut -c1-220
  echo "-- network"
  ip -br addr | cut -c1-110
  echo "-- sound cards"
  cat /proc/asound/cards
  echo "-- errors of this boot"
  journalctl -b -p err --no-pager -o cat -n 12 | cut -c1-200
  echo "-- versions"
  rpm -q mullvad-browser cage xorg-x11-server-Xwayland kernel-core | tr '\n' ' '
  echo
  echo "BROWSEVM-REPORT end"
} > /dev/ttyS0 2>&1
REPORT
chmod 0755 /usr/local/sbin/browsevm-report
cat > /etc/systemd/system/browsevm-report.service <<'UNIT'
[Unit]
Description=browsevm: kiosk state to the serial port (only a domain that has one)

[Service]
Type=simple
ExecStart=/usr/local/sbin/browsevm-report

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable browsevm-report.service >/dev/null 2>&1
restorecon -F /usr/local/sbin/browsevm-report /usr/local/bin/browsevm-kiosk \
  /etc/systemd/system/browsevm-report.service /etc/systemd/system/cage@.service \
  /etc/pam.d/cage 2>/dev/null

# the base is updated by the host admin only; every start is a throwaway overlay
systemctl disable dnf-makecache.timer 2>/dev/null
firewall-offline-cmd --set-default-zone=drop >/dev/null
# nothing in the VM is kept anyway
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=volatile\n' > /etc/systemd/journald.conf.d/browsevm.conf

for p in cage mullvad-browser xorg-x11-server-Xwayland gtk3 pipewire wireplumber mesa-dri-drivers \
         firefox openssh-server qemu-guest-agent spice-vdagent; do
  if rpm -q "$p" >/dev/null 2>&1; then say "pkg $p yes"; else say "pkg $p no"; fi
done
say "selinux $(sed -n 's/^SELINUX=//p' /etc/selinux/config)"
say "firewall default zone $(firewall-offline-cmd --get-default-zone)"
say "default target $(systemctl get-default)"
say "cage unit $(systemctl is-enabled cage@tty1.service)"
say "consoles kmsconvt@ $(systemctl is-enabled kmsconvt@tty1.service 2>&1 | tail -n 1), getty@ $(systemctl is-enabled getty@tty1.service 2>&1 | tail -n 1)"
say "report unit $(systemctl is-enabled browsevm-report.service 2>&1 | tail -n 1)"
say "kiosk script $(test -x /usr/local/bin/browsevm-kiosk && echo present || echo MISSING)"
say "release $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release)"
say "post done"
%end
