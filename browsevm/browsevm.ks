# browsevm.ks - unattended install of the browsevm base image (Fedora minimal +
# cage kiosk + Firefox). Used by browsevm.sh build, which fills the @...@ fields:
# release, the Firefox policy (written here: files injected into the initrd are gone
# after the installer's switch_root, only the kickstart is carried over) and the
# Mullvad extension URL + sha256 (downloaded in %post, checked against the host's hash).
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
firefox
mozilla-ublock-origin
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

# Firefox floor policy (built on the host from browsers/firefox/policies.json)
mkdir -p /etc/firefox/policies
cat > /etc/firefox/policies/policies.json <<'BROWSEVM_POLICY'
@POLICY_JSON@
BROWSEVM_POLICY
chmod 0644 /etc/firefox/policies/policies.json

# Mullvad Browser Extension: same file the host checked (sha256), Mozilla-signed
xpi_url='@MULLVAD_XPI_URL@'
xpi_sha='@MULLVAD_XPI_SHA256@'
xpi=/usr/share/browsevm/mullvad-browser-extension.xpi
if [ -n "$xpi_url" ]; then
  mkdir -p /usr/share/browsevm
  if curl -fsSL --retry 3 --max-time 120 -o "$xpi" "$xpi_url" &&
     echo "$xpi_sha  $xpi" | sha256sum -c --quiet >/dev/null 2>&1; then
    chmod 0644 "$xpi"
    say "mullvad xpi sha256 ok"
  else
    rm -f "$xpi"
    say "MISSING mullvad xpi (download or sha256 failed)"
  fi
fi

# kiosk: cage on tty1 as user web, Firefox full screen, restarted when closed.
# Unit from cage's wiki "Starting Cage on boot with systemd". pixman = CPU renderer.
cat > /etc/systemd/system/cage@.service <<'UNIT'
[Unit]
Description=Cage Wayland kiosk on %I
After=systemd-user-sessions.service plymouth-quit-wait.service
Before=graphical.target
ConditionPathExists=/dev/tty0
Wants=dbus.socket systemd-logind.service
After=dbus.socket systemd-logind.service
Conflicts=getty@%i.service
After=getty@%i.service

[Service]
Type=simple
Environment=WLR_RENDERER=pixman
Environment=XKB_DEFAULT_LAYOUT=us,ara
Environment=XKB_DEFAULT_OPTIONS=grp:alt_shift_toggle
ExecStart=/usr/bin/cage -- /usr/bin/firefox
ExecStartPost=+sh -c "tty_name='%i'; exec chvt $${tty_name#tty}"
Restart=always
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
cat > /etc/pam.d/cage <<'PAM'
auth           required        pam_unix.so nullok
account        required        pam_unix.so
session        required        pam_unix.so
session        required        pam_systemd.so
PAM
systemctl enable cage@tty1.service
systemctl set-default graphical.target

# uBlock Origin from the Fedora package, force-installed from the local file
xpi=$(rpm -ql mozilla-ublock-origin 2>/dev/null | grep -m1 '\.xpi$')
if [ -n "$xpi" ]; then
  sed -i "s|@UBLOCK_XPI@|$xpi|" /etc/firefox/policies/policies.json
  say "ublock $xpi"
else
  say "MISSING ublock xpi (policy points nowhere)"
fi

# the base is updated by the host admin only; every start is a throwaway overlay
systemctl disable dnf-makecache.timer 2>/dev/null
firewall-offline-cmd --set-default-zone=drop >/dev/null
# nothing in the VM is kept anyway
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=volatile\n' > /etc/systemd/journald.conf.d/browsevm.conf

for p in cage firefox mozilla-ublock-origin pipewire wireplumber mesa-dri-drivers \
         google-noto-sans-arabic-vf-fonts openssh-server qemu-guest-agent spice-vdagent; do
  if rpm -q "$p" >/dev/null 2>&1; then say "pkg $p yes"; else say "pkg $p no"; fi
done
say "selinux $(sed -n 's/^SELINUX=//p' /etc/selinux/config)"
say "firewall default zone $(firewall-offline-cmd --get-default-zone)"
say "default target $(systemctl get-default)"
say "cage unit $(systemctl is-enabled cage@tty1.service)"
say "policy $(test -s /etc/firefox/policies/policies.json && echo present || echo MISSING)"
say "mullvad extension $(test -s /usr/share/browsevm/mullvad-browser-extension.xpi && echo present || echo absent)"
say "firefox language $(sed -n 's/^LANG=//p' /etc/locale.conf) (no langpacks)"
say "release $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release)"
say "post done"
%end
