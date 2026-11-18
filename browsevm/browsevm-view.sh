#!/usr/bin/env bash
#
# browsevm - open the throwaway browsing VM in a window (docs/browsevm.md)
#
# Installed as /usr/local/bin/browsevm by "browsevm.sh install"; run by the daily user
# (desktop entries "browsevm Mullvad", "browsevm Brave"), never as root.
#
#   browsevm [mullvad|brave]     (default mullvad)
#
# - starts browsevm@<browser>.service (the polkit rule lets this user start / stop those
#   units and nothing else), opens the VM's SPICE socket with remote-viewer
# - window closed = VM stopped = its overlay deleted: nothing is kept
# - a VM left running without a window (logout, crash) is never reused: stopped first,
#   so every window is a new clean VM
# - one window at a time (lock)
# - Wayland only: no Wayland session = refused; remote-viewer gets GDK_BACKEND=wayland and
#   no DISPLAY, so GTK never falls back to X11 (Xwayland clients could read the keys)
# - beta layers (2026-11-18, docs/browsevm.md "Viewer: relay + sandbox"), both on:
#     relay    remote-viewer reaches GNOME Shell only through browsevm-wlrelay, which
#              keeps what GNOME Shell cannot take yet (GTK 3 drops the window otherwise)
#     sandbox  remote-viewer in bwrap: no network, no home, no session bus, no devices,
#              /usr read-only; only the SPICE socket, the relay's socket, the sound socket
#   BROWSEVM_RELAY=0 / BROWSEVM_SANDBOX=0 in front: that layer off for this start
# - every end of the viewer: one line to the journal (journalctl -t browsevm):
#   exit status, layers, the relay's queue / wait numbers. No content
#
set -uo pipefail

BROWSER=${1:-mullvad}
SOCK=/run/browsevm/spice.sock
BUILD_LOCK=/run/browsevm-build.lock   # held while the base image is rebuilt
RELAY_PY=/usr/local/lib/browsevm/browsevm-wlrelay.py
RV=/usr/bin/remote-viewer
PY=/usr/bin/python3
BWRAP=/usr/bin/bwrap
RELAY=${BROWSEVM_RELAY:-1}
SANDBOX=${BROWSEVM_SANDBOX:-1}
RT=${XDG_RUNTIME_DIR:-}

note() {
  printf 'browsevm: %s\n' "$*" >&2
  if command -v notify-send >/dev/null; then
    notify-send -a browsevm -i dialog-warning "browsevm" "$*" 2>/dev/null || true
  fi
}

log() { logger -t browsevm -- "$*" 2>/dev/null || true; }

[[ $EUID -ne 0 ]] || { echo "browsevm: run as the daily user, not root" >&2; exit 2; }
case $BROWSER in
  mullvad|brave) ;;
  *) echo "usage: browsevm [mullvad|brave]" >&2; exit 2 ;;
esac
[[ $RELAY == [01] && $SANDBOX == [01] ]] ||
  { echo "browsevm: BROWSEVM_RELAY / BROWSEVM_SANDBOX take 0 or 1" >&2; exit 2; }
UNIT=browsevm@$BROWSER.service
[[ -x $RV ]] || { note "remote-viewer missing (rpm-ostree install virt-viewer, reboot)"; exit 1; }
[[ -n ${WAYLAND_DISPLAY:-} && $RT == /* && -d $RT ]] ||
  { note "not a Wayland session: refused (the viewer never runs on X11)"; exit 1; }
WL=$WAYLAND_DISPLAY
[[ $WL == /* ]] || WL=$RT/$WL
if ((RELAY)); then
  [[ -x $PY && -f $RELAY_PY ]] ||
    { note "relay missing ($RELAY_PY: browsevm.sh install); BROWSEVM_RELAY=0 starts without it"; exit 1; }
fi
if ((SANDBOX)); then
  [[ -x $BWRAP ]] ||
    { note "bwrap missing: no sandbox; BROWSEVM_SANDBOX=0 starts without it"; exit 1; }
  "$BWRAP" --unshare-all --unshare-user --disable-userns --ro-bind /usr /usr \
    --symlink usr/lib64 /lib64 --symlink usr/lib /lib --symlink usr/bin /bin /usr/bin/true 2>/dev/null ||
    { note "the sandbox does not start here (user namespaces off?); BROWSEVM_SANDBOX=0 starts without it"; exit 1; }
fi
((RELAY)) || note "beta layer off for this start: relay (BROWSEVM_RELAY=0)"
((SANDBOX)) || note "beta layer off for this start: sandbox (BROWSEVM_SANDBOX=0)"

exec 9> "$RT/browsevm.lock"
flock -n 9 || { note "already open"; exit 0; }

started=0
err=""
sbdir=""
finish() {
  [[ -n $err ]] && rm -f "$err"
  [[ -n $sbdir ]] && rm -rf "$sbdir"
  err="" sbdir=""
  ((started)) || return 0
  started=0
  systemctl stop "$UNIT" || note "could not stop $UNIT - the VM may still run"
}
trap finish EXIT
trap 'exit 143' INT TERM HUP

if [[ -e $BUILD_LOCK ]] && exec 7< "$BUILD_LOCK" && ! flock -n -s 7; then
  note "the VM's image is being rebuilt (weekly update): try again in about 15 min"; exit 1
fi
exec 7<&-
for u in browsevm@mullvad.service browsevm@brave.service; do
  if systemctl is-active --quiet "$u"; then
    systemctl stop "$u" || { note "an old VM is running and could not be stopped"; exit 1; }
  fi
done
started=1
systemctl start "$UNIT" || { note "could not start $UNIT (journalctl -u $UNIT)"; exit 1; }
[[ -S $SOCK && -w $SOCK ]] || { note "no access to $SOCK"; exit 1; }

# sandbox: what remote-viewer sees. Through the SPICE socket it can still talk to the VM
# (its keys and pointer), so it gets nothing worth taking: no home (empty tmpfs), no
# machine-id, this user's own passwd / group line only, no network, no session bus, no
# /dev/snd or /dev/dri (sound only through the PulseAudio socket), no new user namespace
# inside, a new session (no terminal to push keys into).
SB=()
sandbox_cmd() {
  local e pulse=$RT/pulse/native
  SB=("$BWRAP" --unshare-all --unshare-user --disable-userns --die-with-parent --new-session
      --clearenv
      --ro-bind /usr /usr
      --symlink usr/bin /bin --symlink usr/sbin /sbin --symlink usr/lib /lib --symlink usr/lib64 /lib64
      --proc /proc --dev /dev --tmpfs /tmp
      --ro-bind "$sbdir/passwd" /etc/passwd --ro-bind "$sbdir/group" /etc/group)
  for e in fonts ld.so.cache nsswitch.conf localtime pulse crypto-policies xdg gtk-3.0; do
    SB+=(--ro-bind-try "/etc/$e" "/etc/$e")
  done
  SB+=(--perms 0700 --dir "$RT"
       --ro-bind "$SOCK" "$SOCK"
       --tmpfs "$HOME" --chdir "$HOME"
       --setenv HOME "$HOME" --setenv USER "$(id -un)" --setenv PATH /usr/bin
       --setenv LANG "${LANG:-C.UTF-8}" --setenv XDG_RUNTIME_DIR "$RT"
       --setenv GDK_BACKEND wayland --setenv GSETTINGS_BACKEND memory --setenv NO_AT_BRIDGE 1
       --setenv GIO_USE_VFS local)
  if [[ -S $pulse ]]; then
    SB+=(--ro-bind "$pulse" "$pulse" --setenv PULSE_SERVER "unix:$pulse")
  fi
  if ((RELAY)); then
    SB+=(--setenv WAYLAND_SOCKET @WAYLAND_SOCKET@)   # the relay puts its fd number here
  else
    SB+=(--ro-bind "$WL" "$WL" --setenv WAYLAND_DISPLAY "$WL")
  fi
  SB+=(--)
}

# no USB redirection from this side either (the VM has no USB controller).
# GTK 3 on Wayland ends a client with _exit(1) when its socket to GNOME Shell is full
# ("Gdk-Message: Error flushing display: Resource temporarily unavailable"; Brave's busy
# pages, 2026-11-15 and -18). The relay should stop that; if it still happens, or the
# relay hits its limit, the viewer is opened again on the same VM (same session), up to
# 5 times in a row. Any other end (window closed, an error) stops the VM as before.
err=$(mktemp "$RT/browsevm-viewer.XXXXXX")
if ((SANDBOX)); then
  sbdir=$(mktemp -d "$RT/browsevm-sandbox.XXXXXX")
  getent passwd "$(id -u)" > "$sbdir/passwd"
  getent group "$(id -g)" > "$sbdir/group"
fi
viewer=("$RV" --title "browsevm $BROWSER" --spice-disable-usbredir "spice+unix://$SOCK")
crashes=0
while :; do
  cmd=()
  ((RELAY)) && cmd+=("$PY" -I "$RELAY_PY" --)
  if ((SANDBOX)); then sandbox_cmd; cmd+=("${SB[@]}"); fi
  t0=$SECONDS
  env -u DISPLAY GDK_BACKEND=wayland "${cmd[@]}" "${viewer[@]}" 9>&- 2> "$err"
  rc=$?
  cat "$err" >&2
  stats=$(grep '^browsevm-wlrelay: viewer->desktop' "$err" | tail -n 1)
  log "viewer end: exit $rc, relay $RELAY, sandbox $SANDBOX, $((SECONDS - t0)) s${stats:+; ${stats#browsevm-wlrelay: }}"
  if ! grep -E 'Error flushing display|dispatching to Wayland display|browsevm-wlrelay: queue limit' \
       "$err" >/dev/null; then
    if ((rc != 0)); then
      log "viewer error: $(grep -v '^browsevm-wlrelay: viewer->desktop' "$err" | tail -n 3 | tr '\n' ' ')"
      note "the viewer ended with an error (exit $rc): VM stopped (journalctl -t browsevm)"
    fi
    break
  fi
  systemctl is-active --quiet "$UNIT" || break
  ((SECONDS - t0 > 120)) && crashes=0
  crashes=$((crashes + 1))
  if ((crashes > 5)); then note "the viewer keeps crashing: VM stopped"; break; fi
  : > "$err"
  sleep 1
done
