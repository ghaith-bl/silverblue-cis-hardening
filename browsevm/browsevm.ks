# browsevm.ks - unattended install of the browsevm base image (Fedora minimal + cage
# kiosk + Mullvad Browser + Brave, one of them per start). Used by browsevm.sh build, which fills the release (@...@)
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

# the second browser: Brave from Brave's own rpm repository, the way Brave documents it
# for Fedora Atomic (its repo file into /etc/yum.repos.d, then install). Same rules as
# above: gpgcheck forced on, a repo file without a gpgkey line refused. Chosen per start
# by the host (browsevm-select below): more sites work in it (fingerprint randomized per
# site instead of one look for everybody).
bb=""
repo=/etc/yum.repos.d/brave-browser.repo
if curl -fsSL --retry 3 --max-time 60 -o "$repo" https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo &&
   grep -q '^gpgkey *= *https://' "$repo"; then
  sed -i -e '/^gpgcheck[ =]/d' -e '/^pkg_gpgcheck[ =]/d' -e 's/^\(\[.*\]\)$/\1\ngpgcheck=1/' "$repo"
  say "brave repo key $(sed -n 's/^gpgkey *= *//p' "$repo" | head -n 1), gpgcheck $(grep -c '^gpgcheck=1' "$repo")"
  dnf -y install brave-browser > /tmp/brave-install.log 2>&1
  bb=$(rpm -q brave-browser 2>/dev/null) || bb=""
else
  rm -f "$repo"
  echo "repo file not downloaded, or without a gpgkey line" > /tmp/brave-install.log
fi
if [ -n "$bb" ]; then
  say "browser $bb"
  say "brave command $(command -v brave-browser || echo MISSING)"
else
  say "MISSING brave-browser"
  tail -n 4 /tmp/brave-install.log | while read -r l; do say "dnf: $l"; done
fi
rm -f /tmp/brave-install.log

# Brave's managed policies (the host's browsers/brave/policies.json, VM edition): nothing
# sent to Brave or Google by itself (P3A, usage ping, Web Discovery, metrics / crash
# reports, surveys), its extra services off (Rewards, Wallet, VPN, Leo AI, News, Talk,
# Tor windows), Shields aggressive, no extension at all, no sign-in / sync / passwords /
# autofill. "Safer" for Brave: JavaScript JIT and V8's optimizers off on every site
# (DefaultJavaScriptJitSetting, DefaultJavaScriptOptimizerSetting = 2), HTTPS only.
mkdir -p /etc/brave/policies/managed
cat > /etc/brave/policies/managed/browsevm.json <<'POLICY'
{
  "MetricsReportingEnabled": false,
  "BraveP3AEnabled": false,
  "BraveStatsPingEnabled": false,
  "BraveWebDiscoveryEnabled": false,
  "UrlKeyedAnonymizedDataCollectionEnabled": false,
  "FeedbackSurveysEnabled": false,
  "UserFeedbackAllowed": false,
  "WebRtcEventLogCollectionAllowed": false,
  "BraveRewardsDisabled": true,
  "BraveWalletDisabled": true,
  "BraveVPNDisabled": true,
  "BraveAIChatEnabled": false,
  "BraveLocalAIEnabled": false,
  "BraveNewsDisabled": true,
  "BraveTalkDisabled": true,
  "BravePlaylistEnabled": false,
  "BraveSpeedreaderEnabled": false,
  "BraveWaybackMachineEnabled": false,
  "EmailAliasesEnabled": false,
  "TorDisabled": true,
  "PromotionsEnabled": false,
  "DefaultBraveAdblockSetting": 2,
  "DefaultBraveFingerprintingV2Setting": 3,
  "DefaultBraveHttpsUpgradeSetting": 2,
  "DefaultBraveReferrersSetting": 2,
  "BraveDeAmpEnabled": true,
  "BraveDebouncingEnabled": true,
  "BraveTrackingQueryParametersFilteringEnabled": true,
  "BraveGlobalPrivacyControlEnabled": true,
  "BraveReduceLanguageEnabled": true,
  "DefaultJavaScriptJitSetting": 2,
  "DefaultJavaScriptOptimizerSetting": 2,
  "VideoCaptureAllowed": false,
  "AudioCaptureAllowed": false,
  "ScreenCaptureAllowed": false,
  "WebRtcIPHandling": "disable_non_proxied_udp",
  "WebRtcLocalIpsAllowedUrls": [],
  "EnableMediaRouter": false,
  "DefaultGeolocationSetting": 2,
  "DefaultSensorsSetting": 2,
  "DefaultSerialGuardSetting": 2,
  "DefaultWebUsbGuardSetting": 2,
  "DefaultWebBluetoothGuardSetting": 2,
  "DefaultWebHidGuardSetting": 2,
  "DefaultFileSystemReadGuardSetting": 2,
  "DefaultFileSystemWriteGuardSetting": 2,
  "DefaultLocalFontsSetting": 2,
  "DefaultWindowManagementSetting": 2,
  "DefaultIdleDetectionSetting": 2,
  "DefaultClipboardSetting": 2,
  "DefaultNotificationsSetting": 2,
  "DefaultPopupsSetting": 2,
  "DefaultAutomaticDownloadsSetting": 2,
  "DefaultInsecureContentSetting": 2,
  "SafeBrowsingProtectionLevel": 1,
  "SafeBrowsingSurveysEnabled": false,
  "SafeBrowsingDeepScanningEnabled": false,
  "PasswordLeakDetectionEnabled": false,
  "BlockThirdPartyCookies": true,
  "HttpsOnlyMode": "force_enabled",
  "HttpsUpgradesEnabled": true,
  "DnsOverHttpsMode": "off",
  "BrowserSignin": 0,
  "SyncDisabled": true,
  "PasswordManagerEnabled": false,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false,
  "PaymentMethodQueryEnabled": false,
  "SearchSuggestEnabled": false,
  "NetworkPredictionOptions": 2,
  "AlternateErrorPagesEnabled": false,
  "BackgroundModeEnabled": false,
  "SpellCheckServiceEnabled": false,
  "TranslateEnabled": false,
  "RemoteDebuggingAllowed": false,
  "DefaultBrowserSettingEnabled": false,
  "ExtensionInstallBlocklist": ["*"]
}
POLICY
chmod 0644 /etc/brave/policies/managed/browsevm.json
say "brave policies $(grep -c '^  "' /etc/brave/policies/managed/browsevm.json) keys, JIT $(sed -n 's/.*"DefaultJavaScriptJitSetting": *\([0-9]*\).*/\1/p' /etc/brave/policies/managed/browsevm.json) (2 = off), Web Discovery $(sed -n 's/.*"BraveWebDiscoveryEnabled": *\([a-z]*\).*/\1/p' /etc/brave/policies/managed/browsevm.json)"

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
# Mullvad Browser's profile: a fixed directory (--profile), new at every start of the VM
# like everything else on its disk. user.js = the browser's own security level Safer
# (JavaScript off on non-HTTPS sites, JIT and some fonts / math off everywhere, audio /
# video click to play). NoScript, shipped with the browser, is what applies the level:
# it stays, its toolbar button stays hidden (the browser's default). Safer is a level the
# browser offers to everybody: users at Safer look like each other. user.js is root's
# (the browser reads it, never writes it).
P=/home/web/.browsevm/profile
install -d -m 0700 -o web -g web /home/web/.browsevm "$P"
cat > "$P/user.js" <<'USERJS'
// browsevm: the browser's own security level Safer
user_pref("browser.security_level.security_slider", 2);
user_pref("browser.security_level.security_custom", false);
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
# Brave (when the host chose it: /run/browsevm-browser, from browsevm-select): its own
# throwaway data directory, no first-run pages, software rendering (no GPU in the VM),
# X11 on cage's Xwayland like the other one.
cat > /usr/local/bin/browsevm-kiosk <<'KIOSK'
#!/bin/bash
P=/home/web/.browsevm/profile
S=/home/web/.browsevm/state
me=$(id -u)
B=$(cat /run/browsevm-browser 2>/dev/null)
if [ "$B" = brave ]; then
  plat=x11
  [ -n "${DISPLAY:-}" ] || plat=wayland
  brave-browser --no-first-run --no-default-browser-check --disable-gpu \
    --ozone-platform="$plat" --user-data-dir=/home/web/.browsevm/brave
  while pgrep -u "$me" -f 'brave.com/brave/brave' >/dev/null; do sleep 2; done
  exit 0
fi
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
mullvad-browser --profile "$P"
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
BP='mullvad-?browser|brave.com/brave/brave'
# Mullvad Browser's first start is headless (up to about a minute): wait for the window.
# The choice is read again every round (written by browsevm-select before cage starts).
for _ in $(seq 30); do
  B=$(cat /run/browsevm-browser 2>/dev/null)
  if pgrep -u web -f "$BP" >/dev/null && { [ "$B" = brave ] || [ -e "$S/warm" ]; }; then break; fi
  sleep 5
done
sleep 20
B=$(cat /run/browsevm-browser 2>/dev/null)
{
  echo "BROWSEVM-REPORT begin"
  echo "BROWSER ${B:-none} (chosen by the host)"
  echo "-- cage unit"
  systemctl show cage@tty1.service -p ActiveState -p SubState -p NRestarts -p ExecMainStatus | tr '\n' ' '
  echo
  journalctl -b -u cage@tty1.service --no-pager -o cat -n 25 | cut -c1-200
  echo "-- processes of web: name, SELinux label, no_new_privs"
  for p in $(pgrep -u web -x cage) $(pgrep -u web -o -f "$BP"); do
    printf '%s  %s  nnp=%s\n' "$(cat /proc/$p/comm)" "$(tr -d '\0' < /proc/$p/attr/current)" \
      "$(sed -n 's/^NoNewPrivs:[[:space:]]*//p' /proc/$p/status)"
  done
  echo "browser processes: $(pgrep -u web -c -f "$BP")"
  p=$(pgrep -u web -n -f "$BP")
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
  if [ "$B" = brave ]; then
  echo "-- Brave"
  p=$(pgrep -u web -o -f 'brave.com/brave/brave')
  [ -n "$p" ] && echo "browser command: $(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-200)"
  f=/etc/brave/policies/managed/browsevm.json
  echo "policies: $(grep -c '^  "' "$f" 2>/dev/null) keys in $f"
  grep -E '"(DefaultJavaScriptJitSetting|DefaultJavaScriptOptimizerSetting|BraveWebDiscoveryEnabled|BraveP3AEnabled|BraveStatsPingEnabled|MetricsReportingEnabled|WebRtcIPHandling)"' "$f" | tr -d ' ,'
  ls /home/web/.browsevm/brave 2>/dev/null | head -n 12 | tr '\n' ' '
  echo
  [ -d /home/web/.browsevm/brave/Default ] && echo "BRAVE-PROFILE present" || echo "BRAVE-PROFILE missing"
  else
  echo "-- security level (kiosk profile $P)"
  echo "first start (headless): $(cat "$S/warm" 2>/dev/null || echo none) s, ended by $(cat "$S/warm-end" 2>/dev/null || echo -)"
  p=$(pgrep -u web -o -f 'mullvad-?browser')
  [ -n "$p" ] && echo "browser command: $(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-160)"
  if [ -f "$P/prefs.js" ]; then
    grep -E 'security_level|hideNoScript' "$P/prefs.js" | cut -c1-120
  else
    echo "no prefs.js in the profile"
  fi
  echo "-- Mullvad extension permissions (preset)"
  echo "extension-preferences.json: $([ -e "$P/extension-preferences.json" ] && echo "still there" || echo "taken over (gone)")"
  fi
  echo "-- network"
  ip -br addr | cut -c1-110
  echo "-- sound cards"
  cat /proc/asound/cards
  echo "-- errors of this boot"
  journalctl -b -p err --no-pager -o cat -n 12 | cut -c1-200
  echo "-- versions"
  rpm -q mullvad-browser brave-browser cage xorg-x11-server-Xwayland kernel-core | tr '\n' ' '
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
# the browser of this start is known only after browsevm-select (multi-user.target comes
# before graphical.target: without this the report read an empty choice)
After=browsevm-select.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/browsevm-report

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable browsevm-report.service >/dev/null 2>&1

# which browser this start: the host puts "browsevm-browser mullvad|brave" into an SMBIOS
# OEM string of the domain (browsevm-ctl, at every start). Read by root before cage
# starts (the DMI table is root's), written to /run/browsevm-browser for the kiosk.
# Anything else, or nothing: Mullvad Browser.
cat > /usr/local/sbin/browsevm-select <<'SELECT'
#!/bin/bash
b=$(tr -c '[:print:]' '\n' < /sys/firmware/dmi/entries/11-0/raw 2>/dev/null |
    grep -o 'browsevm-browser [a-z]*' | head -n 1)
b=${b#browsevm-browser }
case $b in brave) ;; *) b=mullvad ;; esac
echo "$b" > /run/browsevm-browser
chmod 0644 /run/browsevm-browser
SELECT
chmod 0755 /usr/local/sbin/browsevm-select
cat > /etc/systemd/system/browsevm-select.service <<'UNIT'
[Unit]
Description=browsevm: browser of this start (SMBIOS OEM string from the host)
Before=cage@tty1.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/browsevm-select

[Install]
WantedBy=graphical.target
UNIT
systemctl enable browsevm-select.service >/dev/null 2>&1
restorecon -RF /usr/local/sbin /usr/local/bin /etc/systemd/system /etc/pam.d/cage \
  /etc/brave /home/web 2>/dev/null

# the base is updated by the host admin only; every start is a throwaway overlay
systemctl disable dnf-makecache.timer 2>/dev/null
firewall-offline-cmd --set-default-zone=drop >/dev/null
# nothing in the VM is kept anyway
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=volatile\n' > /etc/systemd/journald.conf.d/browsevm.conf

for p in cage mullvad-browser brave-browser xorg-x11-server-Xwayland gtk3 pipewire wireplumber mesa-dri-drivers \
         firefox openssh-server qemu-guest-agent spice-vdagent; do
  if rpm -q "$p" >/dev/null 2>&1; then say "pkg $p yes"; else say "pkg $p no"; fi
done
say "selinux $(sed -n 's/^SELINUX=//p' /etc/selinux/config)"
say "firewall default zone $(firewall-offline-cmd --get-default-zone)"
say "default target $(systemctl get-default)"
say "cage unit $(systemctl is-enabled cage@tty1.service)"
say "consoles kmsconvt@ $(systemctl is-enabled kmsconvt@tty1.service 2>&1 | tail -n 1), getty@ $(systemctl is-enabled getty@tty1.service 2>&1 | tail -n 1), serial-getty@ $(systemctl is-enabled serial-getty@ttyS0.service 2>&1 | tail -n 1)"
say "report unit $(systemctl is-enabled browsevm-report.service 2>&1 | tail -n 1), browser select unit $(systemctl is-enabled browsevm-select.service 2>&1 | tail -n 1)"
say "kiosk script $(test -x /usr/local/bin/browsevm-kiosk && echo present || echo MISSING)"
say "release $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release)"
say "post done"
%end
