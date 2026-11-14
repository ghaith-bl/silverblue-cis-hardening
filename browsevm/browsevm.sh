#!/usr/bin/env bash
#
# browsevm.sh - throwaway browsing VM (docs/browsevm.md)
#
#   sudo browsevm/browsevm.sh build [--force] [--iso <netinst.iso>]
#                                        unattended install of the base image
#   sudo DAILY_USER=<daily user> browsevm/browsevm.sh install
#                                        domain, start / stop unit, polkit rule, launcher
#   sudo browsevm/browsevm.sh report     one start with a serial port: the kiosk's own state
#
# build: Fedora minimal + cage + Mullvad Browser from browsevm.ks, network "browse"
# (section browsevm). The browser comes from Mullvad's own rpm repository, added in the
# kickstart's %post the way Mullvad documents it (repo file, signature checked by dnf),
# and is left exactly as shipped: its fingerprint is the same for everybody who uses it.
# The base image is never booted for browsing: the VM (step 3) runs on a throwaway
# overlay.
# --iso: installer (kernel, initrd, stage2) from a local Fedora Everything netinst ISO
# (needs xorriso), packages still from the mirrors. Without it: all from the network tree.
# Output: the install's serial console logged by virtlogd to
# /var/log/libvirt/qemu/browsevm-build-*.serial.log, a progress line every 20 s (minutes,
# disk size, last installer line), the BROWSEVM: lines at the end.
# A download speed probe runs first: under BROWSEVM_MIN_KBPS (default 200 KB/s) the build
# stops (it would take many hours); BROWSEVM_MIN_KBPS=0 builds anyway.
#
# install: defines the domain "browsevm" from domain.xml (disk = an overlay on the base
# image that browsevm-ctl makes at start and deletes at stop, the base read-only for the
# VM; SPICE on a unix socket, no clipboard / USB / shares / agent), installs
# browsevm-ctl (root, run by browsevm.service only), browsevm.service (never enabled), a
# polkit rule (DAILY_USER may start / stop that unit, nothing else), /usr/local/bin/browsevm
# (start + remote-viewer + stop when the window closes) and its desktop entry. The daily
# user gets no libvirt access. Run again after a change here; the VM must be off.
#
# report: nobody can log in to the VM (no shell, no ssh, no agent). The image has a small
# unit that writes the kiosk's state (cage, the browser, its security level, the script
# test page, SELinux, consoles, network, errors) to the first serial port; the browsing
# domain has none, so nothing is ever sent.
# report defines the domain once with a serial port logged by virtlogd, starts it through
# browsevm.service, prints what the guest wrote, stops it and puts the domain back.
# BROWSEVM_REPORT_SHOT=<file> also saves a screenshot before the stop.
#
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FEDORA="${BROWSEVM_FEDORA:-45}"
BASE=/var/lib/libvirt/images/browsevm-base.qcow2
RUNIMG=/var/lib/libvirt/browsevm-run/browsevm-run.qcow2   # the VM's disk, on a tmpfs (same paths in browsevm-ctl.sh)
BUILD=browsevm-build
DOM=browsevm
NET=browse
SOCK=/run/browsevm/spice.sock    # same path in browsevm-ctl.sh and browsevm-view.sh
ETC=/etc/browsevm                # network.xml (section browsevm), domain.xml, view-user
LOGDIR=/var/log/libvirt/qemu     # virtlogd writes here (virt_log_t); QEMU never opens it
MIN_KBPS="${BROWSEVM_MIN_KBPS:-200}"
MULLVAD_REPO=https://repository.mullvad.net/rpm/stable/mullvad.repo   # same URL in browsevm.ks
V=(virsh -q -c qemu:///system)
TMPD=""
trap '[[ -n $TMPD ]] && rm -rf "$TMPD"' EXIT

ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

cmd_build() {
  local force=0 iso="" url tmp log started_net=0 state c probe kbps host
  local location label vi rc t0 size last extra
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1 ;;
      --iso)   iso=${2:-}; shift ;;
      *)       die "unknown option: $1" ;;
    esac
    shift
  done
  [[ $EUID -eq 0 ]] || die "run with sudo"
  [[ $FEDORA =~ ^[0-9]{2}$ ]] || die "BROWSEVM_FEDORA must be a release number (e.g. 45)"
  [[ $MIN_KBPS =~ ^[0-9]+$ ]] || die "BROWSEVM_MIN_KBPS must be a number (KB/s)"
  for c in virt-install virsh curl; do
    command -v "$c" >/dev/null || die "$c missing"
  done
  "${V[@]}" net-info "$NET" >/dev/null 2>&1 || die "network $NET missing: sudo ./harden-workstation.sh browsevm"
  if [[ -n $iso ]]; then
    [[ -f $iso && $iso == *.iso ]] || die "--iso: no such .iso file: $iso"
    command -v xorriso >/dev/null || die "--iso needs xorriso (virt-install reads the kernel from the ISO with it)"
    label=$(blkid -o value -s LABEL "$iso" 2>/dev/null || true)
    [[ $label =~ ^[A-Za-z0-9._-]{1,32}$ ]] || die "--iso: no usable volume label in $iso ('$label')"
  fi
  if "${V[@]}" dominfo "$BUILD" >/dev/null 2>&1; then
    die "a $BUILD domain exists (old run?): sudo virsh destroy $BUILD; sudo virsh undefine $BUILD"
  fi
  if [[ -e $BASE ]] && ((!force)); then die "$BASE exists (--force moves it to $BASE.old)"; fi

  # nothing is touched before the network answers (a VPN that just reconnected needs a
  # moment: 6 tries, 10 s apart)
  url="https://download.fedoraproject.org/pub/fedora/linux/releases/$FEDORA/Everything/x86_64/os/"
  for c in 1 2 3 4 5 6; do
    if curl -fsSL --max-time 30 -o /dev/null "$url.treeinfo"; then c=ok; break; fi
    warn "install tree not reachable yet (try $c of 6)"
    sleep 10
  done
  [[ $c == ok ]] || die "Fedora $FEDORA install tree not reachable: $url"
  ok "install tree: Fedora $FEDORA"

  # speed probe: the install pulls ~2.5 GB (initrd, installer image, packages) through
  # Mullvad; a slow mirror / relay turns that into many hours with a silent screen
  probe=$(curl -fsSL --max-time 40 -o /dev/null -w '%{speed_download} %{url_effective}' \
          "${url}images/pxeboot/vmlinuz" 2>/dev/null || true)
  kbps=${probe%% *}
  kbps=${kbps%%.*}
  [[ $kbps =~ ^[0-9]+$ ]] || kbps=0
  kbps=$(( kbps / 1024 ))
  host=$(sed -E 's|^[^ ]* https?://([^/]+)/.*|\1|' <<<"$probe")
  ok "speed probe: ${kbps} KB/s from ${host:-?} (about $(( kbps > 0 ? 2500 * 1024 / kbps / 60 : 0 )) min for 2.5 GB)"
  if (( kbps < MIN_KBPS )); then
    die "too slow (< $MIN_KBPS KB/s): try another VPN relay, then rerun; BROWSEVM_MIN_KBPS=0 builds anyway"
  fi

  tmp=$(mktemp -d)
  TMPD=$tmp

  # the browser's repository must answer before 10 minutes of install are spent
  curl -fsSL --max-time 30 -o /dev/null "$MULLVAD_REPO" || die "Mullvad's rpm repository not reachable: $MULLVAD_REPO"
  ok "Mullvad rpm repository reachable"

  # kickstart: only the release is filled in (injected into the installer's initrd)
  sed "s|@FEDORA@|$FEDORA|g" "$HERE/browsevm.ks" > "$tmp/browsevm.ks"
  if grep '@[A-Z_0-9]*@' "$tmp/browsevm.ks" >/dev/null; then die "browsevm.ks: a field was not filled"; fi
  ok "kickstart written"

  if [[ -e $BASE ]]; then
    mv -f "$BASE" "$BASE.old"
    warn "old base moved to $BASE.old"
  fi

  if [[ $("${V[@]}" net-info "$NET" | sed -n 's/^Active: *//p') != yes ]]; then
    "${V[@]}" net-start "$NET" >/dev/null && started_net=1 && ok "network $NET started for the install"
  fi
  log="$LOGDIR/$BUILD-$(date +%Y%m%d-%H%M%S).serial.log"
  location=$url
  extra="inst.ks=file:/browsevm.ks inst.text console=ttyS0"
  if [[ -n $iso ]]; then
    location=$iso
    extra="$extra inst.stage2=hd:LABEL=$label"
    ok "installer from $iso (label $label), packages from the mirrors"
  fi

  ok "installing (unattended) - serial log: $log"
  ok "progress every 20 s: minutes, disk MB, last installer line (Ctrl+C stops the build)"
  virt-install --connect qemu:///system --name "$BUILD" \
      --osinfo detect=on,require=off \
      --machine q35 \
      --memory 4096 --vcpus 2 \
      --disk "path=$BASE,size=12,format=qcow2,bus=virtio" \
      --network "network=$NET,model=virtio" \
      --location "$location" \
      --initrd-inject "$tmp/browsevm.ks" \
      --extra-args "$extra" \
      --graphics none --serial "pty,log.file=$log,log.append=off" \
      --noautoconsole --noreboot --wait 300 >"$tmp/virt-install.out" 2>&1 &
  vi=$!
  trap 'kill "$vi" 2>/dev/null; "${V[@]}" destroy "$BUILD" >/dev/null 2>&1; exit 130' INT TERM
  t0=$SECONDS
  while kill -0 "$vi" 2>/dev/null; do
    sleep "${BROWSEVM_PROGRESS_SECS:-20}"
    size=$(du -m "$BASE" 2>/dev/null | cut -f1 || true)
    last=$(tail -c 6000 "$log" 2>/dev/null | tr '\r' '\n' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' |
           LC_ALL=C grep -a '[[:alnum:]]' | tail -n 1 | cut -c1-100 || true)
    [[ -n $last ]] || last="(virt-install) $(tr '\r' '\n' < "$tmp/virt-install.out" |
                            LC_ALL=C grep -a '[[:alnum:]]' | tail -n 1 | cut -c1-90 || true)"
    printf '  %3d min  disk %5s MB  %s\n' $(( (SECONDS - t0) / 60 )) "${size:-0}" "$last"
  done
  if wait "$vi"; then rc=0; else rc=$?; fi
  trap - INT TERM
  if ((rc != 0)); then
    warn "virt-install failed or timed out (rc $rc):"
    tail -n 8 "$tmp/virt-install.out" 2>/dev/null || true
    warn "last lines of $log:"
    tail -n 25 "$log" 2>/dev/null | tr -d '\r' || true
    "${V[@]}" destroy "$BUILD" >/dev/null 2>&1 || true
    "${V[@]}" undefine "$BUILD" >/dev/null 2>&1 || true
    ((started_net)) && "${V[@]}" net-destroy "$NET" >/dev/null 2>&1
    die "build failed (disk left at $BASE for a look; rerun with --force)"
  fi

  state=$("${V[@]}" domstate "$BUILD" 2>/dev/null || echo gone)
  [[ $state == "shut off" ]] || warn "domain state after install: $state"
  "${V[@]}" undefine "$BUILD" >/dev/null && ok "build domain removed (disk kept)"
  ((started_net)) && "${V[@]}" net-destroy "$NET" >/dev/null && ok "network $NET stopped again"
  chown root:root "$BASE"
  chmod 0600 "$BASE"

  echo
  echo "-- checks from the install (serial console)"
  grep -a 'BROWSEVM:' "$log" | tr -d '\r' || warn "no BROWSEVM: lines in $log"
  if grep -aq 'BROWSEVM: post done' "$log"; then
    ok "base image: $BASE ($(du -h "$BASE" | cut -f1))"
  else
    warn "post-install did not finish - read $log"
  fi
}

# root owned copy of a repo file: a root unit / a launcher never runs from a home
put() {   # $1 mode, $2 source, $3 target
  if cmp -s "$2" "$3" && [[ $(stat -c '%a %U %G' "$3") == "${1#0} root root" ]]; then
    ok "$3 up to date"
  else
    install -o root -g root -m "$1" "$2" "$3" || die "could not install $3"
    restorecon -F "$3" 2>/dev/null || true
    ok "installed $3"
  fi
}

cmd_install() {
  local user=${DAILY_USER:-} f st tmp
  [[ $# -eq 0 ]] || die "install takes no option"
  [[ $EUID -eq 0 ]] || die "run with sudo"
  [[ -n $user ]] || die "who may open the VM? sudo DAILY_USER=<daily user> browsevm/browsevm.sh install"
  [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && id "$user" >/dev/null 2>&1 || die "no such user: $user"
  (( $(id -u "$user") >= 1000 )) || die "$user is a system account"
  for f in wheel libvirt; do
    if id -nG "$user" | tr ' ' '\n' | grep -x "$f" >/dev/null; then
      warn "$user is in group $f: the VM is meant for a user without it"
    fi
  done
  for f in virsh systemctl qemu-img mountpoint; do
    command -v "$f" >/dev/null || die "$f missing"
  done
  for f in domain.xml browsevm-ctl.sh browsevm-view.sh browsevm.service 60-browsevm.rules browsevm.desktop; do
    [[ -f $HERE/$f ]] || die "$HERE/$f missing: run from the repo"
  done
  "${V[@]}" net-info "$NET" >/dev/null 2>&1 || die "network $NET missing: sudo ./harden-workstation.sh browsevm"
  [[ -f $BASE ]] || die "$BASE missing: sudo browsevm/browsevm.sh build"
  st=$("${V[@]}" domstate "$DOM" 2>/dev/null || echo gone)
  [[ $st == gone || $st == "shut off" ]] ||
    die "domain $DOM is '$st': sudo systemctl stop browsevm.service, then run again"

  tmp=$(mktemp -d)
  TMPD=$tmp
  install -d -m 0755 "$ETC" /usr/local/share/applications

  # domain: the file libvirt got is kept in $ETC (what to look at, what to define again)
  sed -e "s|@RUNIMG@|$RUNIMG|" -e "s|@NET@|$NET|" -e "s|@SOCK@|$SOCK|" "$HERE/domain.xml" > "$tmp/domain.xml"
  if grep '@[A-Z]*@' "$tmp/domain.xml" >/dev/null; then die "domain.xml: a field was not filled"; fi
  put 0644 "$tmp/domain.xml" "$ETC/domain.xml"
  if [[ $st != gone ]]; then
    "${V[@]}" undefine "$DOM" >/dev/null || die "virsh undefine $DOM failed"
  fi
  "${V[@]}" define --validate "$ETC/domain.xml" >/dev/null ||
    die "virsh define failed: the domain is not defined now (fix, run again)"
  ok "domain $DOM defined (disk $RUNIMG = overlay on the base, SPICE socket $SOCK)"

  printf '%s\n' "$user" > "$tmp/view-user"
  put 0644 "$tmp/view-user" "$ETC/view-user"
  put 0755 "$HERE/browsevm-ctl.sh" /usr/local/sbin/browsevm-ctl
  put 0755 "$HERE/browsevm-view.sh" /usr/local/bin/browsevm
  put 0644 "$HERE/browsevm.service" /etc/systemd/system/browsevm.service
  systemctl daemon-reload
  sed "s|@USER@|$user|" "$HERE/60-browsevm.rules" > "$tmp/60-browsevm.rules"
  put 0644 "$tmp/60-browsevm.rules" /etc/polkit-1/rules.d/60-browsevm.rules
  put 0644 "$HERE/browsevm.desktop" /usr/local/share/applications/browsevm.desktop

  command -v remote-viewer >/dev/null ||
    warn "remote-viewer missing: sudo rpm-ostree install virt-viewer, reboot"
  ok "$user: open 'browsevm' from the app grid (or run: browsevm); closing the window stops the VM"
}

# the normal definition back, whatever happened in cmd_report
report_restore() {
  systemctl stop browsevm.service >/dev/null 2>&1 || true
  "${V[@]}" undefine "$DOM" >/dev/null 2>&1 || true
  "${V[@]}" define "$ETC/domain.xml" >/dev/null ||
    warn "could not define $ETC/domain.xml again: sudo DAILY_USER=<daily user> $0 install"
}

cmd_report() {
  local st tmp log="$LOGDIR/$DOM-report.serial.log" shot=${BROWSEVM_REPORT_SHOT:-}
  local secs=${BROWSEVM_REPORT_SECS:-240} t0
  [[ $# -eq 0 ]] || die "report takes no option"
  [[ $EUID -eq 0 ]] || die "run with sudo"
  [[ $secs =~ ^[0-9]+$ ]] || die "BROWSEVM_REPORT_SECS must be a number"
  [[ -f $ETC/domain.xml ]] || die "$ETC/domain.xml missing: install first"
  st=$("${V[@]}" domstate "$DOM" 2>/dev/null || echo gone)
  [[ $st == "shut off" ]] || die "domain $DOM is '$st': stop it first (or install)"
  if systemctl is-active --quiet browsevm.service; then die "browsevm.service is active: stop it first"; fi

  tmp=$(mktemp -d)
  TMPD=$tmp
  sed "s|</devices>|  <serial type='pty'>\n      <log file='$log' append='off'/>\n    </serial>\n  </devices>|" \
      "$ETC/domain.xml" > "$tmp/report.xml"
  grep "<serial type='pty'>" "$tmp/report.xml" >/dev/null || die "could not add the serial port"

  rm -f -- "$log"     # an old report is never taken for this start's
  trap 'report_restore; [[ -n $TMPD ]] && rm -rf "$TMPD"' EXIT
  trap 'exit 130' INT TERM
  "${V[@]}" undefine "$DOM" >/dev/null || die "virsh undefine $DOM failed"
  "${V[@]}" define --validate "$tmp/report.xml" >/dev/null || die "virsh define (with serial) failed"
  systemctl start browsevm.service || die "browsevm.service did not start (journalctl -u browsevm.service)"
  ok "started with a serial port - the guest writes its report 1-3 min after boot"
  t0=$SECONDS
  while (( SECONDS - t0 < secs )); do
    if grep -a 'BROWSEVM-REPORT end' "$log" >/dev/null 2>&1; then break; fi
    sleep 10
    printf '  %3d s  waiting for the report\n' $(( SECONDS - t0 ))
  done
  if [[ -n $shot ]]; then
    if "${V[@]}" screenshot "$DOM" "$shot" >/dev/null 2>&1; then ok "screenshot: $shot"
    else warn "screenshot failed"; fi
  fi
  echo
  if grep -a 'BROWSEVM-REPORT end' "$log" >/dev/null 2>&1; then
    sed -n '/BROWSEVM-REPORT begin/,/BROWSEVM-REPORT end/p' "$log" | tr -d '\r'
  else
    warn "no complete report in $secs s - what the serial port got:"
    tail -n 40 "$log" 2>/dev/null | tr -d '\r' || true
  fi
  echo
  report_restore
  trap '[[ -n $TMPD ]] && rm -rf "$TMPD"' EXIT
  trap - INT TERM
  ok "stopped, normal domain (no serial port) defined again"
}

case "${1:-}" in
  build)   shift; cmd_build "$@" ;;
  install) shift; cmd_install "$@" ;;
  report)  shift; cmd_report "$@" ;;
  *)       sed -n '3,9p' "$0"; exit 2 ;;
esac
