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
#
set -uo pipefail

BROWSER=${1:-mullvad}
SOCK=/run/browsevm/spice.sock
BUILD_LOCK=/run/browsevm-build.lock   # held while the base image is rebuilt

note() {
  printf 'browsevm: %s\n' "$*" >&2
  if command -v notify-send >/dev/null; then
    notify-send -a browsevm -i dialog-warning "browsevm" "$*" 2>/dev/null || true
  fi
}

[[ $EUID -ne 0 ]] || { echo "browsevm: run as the daily user, not root" >&2; exit 2; }
case $BROWSER in
  mullvad|brave) ;;
  *) echo "usage: browsevm [mullvad|brave]" >&2; exit 2 ;;
esac
UNIT=browsevm@$BROWSER.service
command -v remote-viewer >/dev/null ||
  { note "remote-viewer missing (rpm-ostree install virt-viewer, reboot)"; exit 1; }

exec 9> "${XDG_RUNTIME_DIR:-/tmp}/browsevm.lock"
flock -n 9 || { note "already open"; exit 0; }

started=0
finish() {
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

# no USB redirection from this side either (the VM has no USB controller).
# GTK 3 on Wayland ends a client with _exit(1) when its socket to GNOME Shell is full
# ("Gdk-Message: Error flushing display: Resource temporarily unavailable"; seen with
# Brave's busy pages, 2026-11-15; known for virt-viewer under Wayland). The VM is fine
# then: the viewer is opened again on the same VM (same session), up to 5 times in a
# row. Any other end (window closed, an error of its own) stops the VM as before.
err=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/browsevm-viewer.XXXXXX")
crashes=0
while :; do
  t0=$SECONDS
  remote-viewer --title "browsevm $BROWSER" --spice-disable-usbredir "spice+unix://$SOCK" \
    9>&- 2> "$err"
  cat "$err" >&2
  if ! grep -E 'Error flushing display|dispatching to Wayland display' "$err" >/dev/null; then
    break
  fi
  systemctl is-active --quiet "$UNIT" || break
  ((SECONDS - t0 > 120)) && crashes=0
  crashes=$((crashes + 1))
  if ((crashes > 5)); then note "the viewer keeps crashing: VM stopped"; break; fi
  : > "$err"
  sleep 1
done
rm -f "$err"
