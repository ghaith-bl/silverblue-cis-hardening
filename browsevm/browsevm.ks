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
# Left as shipped except the security level (below, the kiosk's profile): any other
# setting of ours would make this browser different from everybody else's, and looking
# the same is what it is for.
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
  # the browser's own libraries sit next to libxul (its start script sets the path)
  xul=$(rpm -ql mullvad-browser | grep -m1 '/libxul\.so$')
  miss=$(LD_LIBRARY_PATH=${xul%/*} ldd "$xul" 2>/dev/null | awk '/not found/ { print $1 }' | tr '\n' ' ')
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
# the kiosk's profile: a fixed directory (--profile), new at every start of the VM like
# everything else on its disk. user.js = the browser's own security level Safer
# (JavaScript off on non-HTTPS sites, JIT and some fonts / math off everywhere, audio /
# video click to play; NoScript, shipped with the browser, gives a site JavaScript for
# this session only: its button, "Temp. TRUSTED") and that button shown (the Tor
# Project hides it by default, tor-browser#41581). Safer is a level the browser offers
# to everybody: users at Safer look like each other. user.js is root's (the browser
# reads it, never writes it).
P=/home/web/.browsevm/profile
install -d -m 0700 -o web -g web /home/web/.browsevm "$P"
cat > "$P/user.js" <<'USERJS'
// browsevm: the browser's own security level Safer, NoScript's button in the toolbar
user_pref("browser.security_level.security_slider", 2);
user_pref("browser.security_level.security_custom", false);
user_pref("extensions.hideNoScript", false);
USERJS
chmod 0644 "$P/user.js"
say "profile $P, security level $(sed -n 's/.*security_slider", *\([0-9]*\).*/\1/p' "$P/user.js") (2 = Safer)"
# the Mullvad Browser Extension (shipped with the browser) asks for its optional
# permissions (proxy, tabs, all sites) before its proxy feature works, and every VM
# start is a new profile: granted here, before the first start. Firefox keeps granted
# optional permissions in the profile's extension-store; on a new profile it takes them
# over once from extension-preferences.json (the older store's file). Only permissions
# the extension's manifest lists as optional are used.
MBX='{d19a89b9-76c1-4a61-bcd4-49e8de916403}'
printf '{"%s":{"permissions":["proxy","tabs"],"origins":["<all_urls>"]}}\n' "$MBX" > "$P/extension-preferences.json"
chown web:web "$P/extension-preferences.json"
chmod 0600 "$P/extension-preferences.json"
say "browser extensions shipped: $(rpm -ql mullvad-browser 2>/dev/null | grep -o 'distribution/extensions/[^/]*\.xpi$' | sed 's|.*/||' | tr '\n' ' ')"
say "Mullvad extension $MBX permissions preset: proxy tabs <all_urls>"

# what cage runs: the browser in the foreground for as long as it lives (its start
# script may detach). cage ends with its client and the unit starts both again.
# The browser's own default is X11 (the Tor Project keeps Wayland off: one more thing
# that would differ between users), so it runs on cage's Xwayland. Without Xwayland
# (no DISPLAY) it is told to use Wayland: better than no browser.
# First start of every VM start: headless, closed again after its extensions are set
# up. A security level preset before the first start of a new profile was not applied
# until a restart (Tor forum, Tor Browser 12.0; tor-browser#44687 in 16.0a4), and every
# VM start is a new profile: the window only ever shows its second start.
# Report runs (/run/browsevm-report-mode) open the local script test page.
cat > /usr/local/bin/browsevm-kiosk <<'KIOSK'
#!/bin/bash
P=/home/web/.browsevm/profile
S=/home/web/.browsevm/state
me=$(id -u)
running() { pgrep -u "$me" -f 'mullvad-?browser' >/dev/null; }
[ -n "${DISPLAY:-}" ] || export MOZ_ENABLE_WAYLAND=1
mkdir -p "$S"
if [ ! -e "$S/warm" ]; then
  t0=$SECONDS
  mullvad-browser --headless --profile "$P" about:blank >/dev/null 2>&1 &
  for _ in $(seq 40); do [ -s "$P/extensions.json" ] && break; sleep 1; done
  sleep 8
  pkill -TERM -u "$me" -f 'mullvad-?browser'
  for _ in $(seq 20); do running || break; sleep 1; done
  if running; then pkill -KILL -u "$me" -f 'mullvad-?browser'; echo kill > "$S/warm-end"
  else echo term > "$S/warm-end"; fi
  sleep 1
  echo "$((SECONDS - t0))" > "$S/warm"
fi
url=()
[ -e /run/browsevm-report-mode ] && url=(http://127.0.0.1:8088/)
mullvad-browser --profile "$P" "${url[@]}"
while running; do sleep 2; done
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
# way, logind starts no console when a VT is switched to. No login prompt on the serial
# port either (console=ttyS0 from the install made systemd start serial-getty there).
kc=$(rpm -qa 'kmscon*')
if [ -n "$kc" ] && rpm -e $kc >/dev/null 2>&1; then
  say "kmscon removed"
else
  say "kmscon $([ -n "$kc" ] && echo "kept (needed by another package), masked" || echo "not installed")"
fi
systemctl mask kmsconvt@.service getty@.service serial-getty@.service >/dev/null 2>&1
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nNAutoVTs=0\nReserveVT=0\n' > /etc/systemd/logind.conf.d/browsevm.conf

# the kiosk's own state for the host admin. Nobody can log in to look, so a small unit
# writes it to the first serial port. The browsing domain has no serial port (the open
# fails, nothing is sent); "browsevm.sh report" starts the VM once with one.
cat > /usr/local/sbin/browsevm-report <<'REPORT'
#!/bin/bash
( : > /dev/ttyS0 ) 2>/dev/null || exit 0
P=/home/web/.browsevm/profile
S=/home/web/.browsevm/state
# the kiosk's first start is headless (up to about a minute): wait for the test page
for _ in $(seq 30); do
  [ -n "$(journalctl -b -o cat -g '^jstest request: GET / ' -q --no-pager -n 1)" ] && break
  sleep 5
done
sleep 15
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
  systemctl list-units --all --no-legend --no-pager 'getty*' 'serial-getty*' 'kmscon*' 'autovt*' | cut -c1-110
  rpm -q kmscon
  echo "-- SELinux"
  getenforce
  journalctl -b --no-pager -o cat -g 'avc: +denied' -n 12 | cut -c1-220
  echo "-- security level (kiosk profile $P)"
  echo "first start (headless): $(cat "$S/warm" 2>/dev/null || echo none) s, ended by $(cat "$S/warm-end" 2>/dev/null || echo -)"
  p=$(pgrep -u web -o -f 'mullvad-?browser')
  [ -n "$p" ] && echo "browser command: $(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-160)"
  if [ -f "$P/prefs.js" ]; then
    grep -E 'security_level|hideNoScript' "$P/prefs.js" | cut -c1-120
    grep -o 'nav-bar\\":\[[^]]*\]' "$P/prefs.js" | grep 73a6fe31-595d-460b-a920-fcc0f8843232 >/dev/null &&
      echo "NOSCRIPT-BUTTON toolbar" || echo "NOSCRIPT-BUTTON not in the toolbar state"
  else
    echo "no prefs.js in the profile"
  fi
  echo "-- Mullvad extension permissions (preset)"
  echo "extension-preferences.json: $([ -e "$P/extension-preferences.json" ] && echo "still there" || echo "taken over (gone)")"
  ls "$P/extension-store" 2>/dev/null | tr '\n' ' '
  echo
  st=$(grep -a -o -e 'd19a89b9-76c1-4a61-bcd4-49e8de916403' -e '"proxy"' -e '<all_urls>' "$P"/extension-store/* 2>/dev/null | sed 's/^[^:]*://' | sort -u | tr '\n' ' ')
  echo "extension-store: ${st:-nothing}"
  case $st in
    *d19a89b9*proxy*|*proxy*d19a89b9*) echo "MULLVAD-EXT-PERMS stored" ;;
    *) echo "MULLVAD-EXT-PERMS not seen" ;;
  esac
  echo "-- script test (local page http://127.0.0.1:8088/, green = blocked, red = ran)"
  journalctl -b -o cat --no-pager -g '^jstest request: ' | cut -c1-120
  if journalctl -b -o cat --no-pager -g '^jstest request: GET /js-ran ' | grep . >/dev/null; then
    echo "SCRIPT-TEST ran"
  elif journalctl -b -o cat --no-pager -g '^jstest request: GET / ' | grep . >/dev/null; then
    echo "SCRIPT-TEST blocked"
  else
    echo "SCRIPT-TEST no-page"
  fi
  echo "-- network"
  ip -br addr | cut -c1-110
  echo "-- sound cards"
  cat /proc/asound/cards
  echo "-- errors of this boot"
  journalctl -b -p err --no-pager -o cat -n 12 | cut -c1-200
  echo "-- versions"
  rpm -q mullvad-browser cage xorg-x11-server-Xwayland kernel-core | tr '\n' ' '
  echo
  # probes, only when the host asked for them (browsevm.sh report with
  # BROWSEVM_REPORT_PROBE: an SMBIOS OEM string "browsevm-probe <ip>:<port> ..."):
  # TCP to each target once (must not open: host, other bridges, LAN), then rounds of
  # internet checks with the time, for a Mullvad disconnect done by the host meanwhile
  pr=$(tr -c '[:print:]' '\n' < /sys/firmware/dmi/entries/11-0/raw 2>/dev/null |
       grep -o 'browsevm-probe[0-9.: ]*' | head -n 1)
  if [ -n "$pr" ]; then
    echo "-- probes (asked for by the host)"
    for t in ${pr#browsevm-probe}; do
      ip=${t%:*}; port=${t##*:}
      t0=$(date +%s%N)
      timeout 4 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null
      rc=$?
      case $rc in 0) r=OPEN ;; 124) r=timeout ;; *) r=closed ;; esac
      echo "PROBE lateral $t $r $(( ($(date +%s%N) - t0) / 1000000 )) ms"
    done
    mip=$(getent ahostsv4 am.i.mullvad.net | awk 'NR == 1 { print $1 }')
    echo "PROBE internet address of am.i.mullvad.net: ${mip:-none}"
    for n in $(seq "${BROWSEVM_PROBE_ROUNDS:-30}"); do
      st=$(date +%s)
      a=fail
      curl -fsS --max-time 4 https://am.i.mullvad.net/connected 2>/dev/null | grep 'You are connected' >/dev/null && a=ok
      b=fail
      [ -n "$mip" ] && timeout 3 bash -c "exec 3<>/dev/tcp/$mip/443" 2>/dev/null && b=ok
      echo "PROBE round $n start $st mullvad-check $a tcp-443 $b"
      sleep 2
    done
    echo "PROBE done"
  fi
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

# report runs only: a local test page that shows whether JavaScript runs. Served on
# 127.0.0.1:8088 by a socket unit that is never enabled (one tiny service per request,
# DynamicUser, request lines to the journal). Its script, when it runs, turns the page
# red and asks for /js-ran: the report reads that from the journal.
mkdir -p /usr/share/browsevm /usr/local/libexec
cat > /usr/share/browsevm/jstest.html <<'HTML'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>browsevm script test</title>
<style>html,body{margin:0;height:100%;background:#1e7d32;color:#fff;font:bold 44px sans-serif}
#t{padding:80px}</style></head>
<body><div id="t">JavaScript blocked: this page stays green</div>
<noscript><img src="/noscript-shown" alt=""></noscript>
<script>
document.body.style.background = "#b71c1c";
document.getElementById("t").textContent = "JavaScript RAN: the security level is Standard";
new Image().src = "/js-ran";
</script>
</body></html>
HTML
cat > /usr/local/libexec/browsevm-jstest <<'SRV'
#!/bin/bash
IFS= read -r -t 5 line || exit 0
line=${line%$'\r'}
echo "jstest request: ${line:0:100}" >&2
while IFS= read -r -t 2 h && [ -n "${h%$'\r'}" ]; do :; done
f=/usr/share/browsevm/jstest.html
case $line in
  "GET / "*)
    printf 'HTTP/1.0 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' "$(stat -c %s "$f")"
    cat "$f" ;;
  *)
    printf 'HTTP/1.0 204 No Content\r\nConnection: close\r\n\r\n' ;;
esac
SRV
chmod 0755 /usr/local/libexec/browsevm-jstest
cat > /etc/systemd/system/browsevm-jstest.socket <<'UNIT'
[Unit]
Description=browsevm: local script test page (report runs only, never enabled)

[Socket]
ListenStream=127.0.0.1:8088
Accept=yes
UNIT
cat > /etc/systemd/system/browsevm-jstest@.service <<'UNIT'
[Unit]
Description=browsevm: local script test page, one request

[Service]
ExecStart=/usr/local/libexec/browsevm-jstest
StandardInput=socket
StandardOutput=socket
StandardError=journal
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
RuntimeMaxSec=20
UNIT
# a report run = the domain has a serial port: flag for the kiosk, test page up,
# before cage starts
cat > /usr/local/sbin/browsevm-reportmode <<'MODE'
#!/bin/bash
( : > /dev/ttyS0 ) 2>/dev/null || exit 0
: > /run/browsevm-report-mode
systemctl start --no-block browsevm-jstest.socket
MODE
chmod 0755 /usr/local/sbin/browsevm-reportmode
cat > /etc/systemd/system/browsevm-reportmode.service <<'UNIT'
[Unit]
Description=browsevm: report run (a serial port): test page for the kiosk
Before=cage@tty1.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/browsevm-reportmode

[Install]
WantedBy=graphical.target
UNIT
systemctl enable browsevm-reportmode.service >/dev/null 2>&1
restorecon -RF /usr/local/sbin /usr/local/bin /usr/local/libexec /usr/share/browsevm \
  /etc/systemd/system /etc/pam.d/cage /home/web 2>/dev/null

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
say "consoles kmsconvt@ $(systemctl is-enabled kmsconvt@tty1.service 2>&1 | tail -n 1), getty@ $(systemctl is-enabled getty@tty1.service 2>&1 | tail -n 1), serial-getty@ $(systemctl is-enabled serial-getty@ttyS0.service 2>&1 | tail -n 1)"
say "report unit $(systemctl is-enabled browsevm-report.service 2>&1 | tail -n 1), report mode unit $(systemctl is-enabled browsevm-reportmode.service 2>&1 | tail -n 1), test page socket $(systemctl is-enabled browsevm-jstest.socket 2>&1 | tail -n 1)"
say "kiosk script $(test -x /usr/local/bin/browsevm-kiosk && echo present || echo MISSING)"
say "release $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release)"
say "post done"
%end
