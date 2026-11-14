#!/usr/bin/env bash
#
# browsevm - open the throwaway browsing VM in a window (docs/browsevm.md)
#
# Installed as /usr/local/bin/browsevm by "browsevm.sh install"; run by the daily user
# (desktop entry "browsevm"), never as root.
#
# - starts browsevm.service (the polkit rule lets this user start / stop that unit and
#   nothing else), opens the VM's SPICE socket with remote-viewer
# - window closed = VM stopped = its overlay deleted: nothing is kept
# - a VM left running without a window (logout, crash) is never reused: stopped first,
#   so every window is a new clean VM
# - one window at a time (lock)
#
set -uo pipefail

UNIT=browsevm.service
SOCK=/run/browsevm/spice.sock

note() {
  printf 'browsevm: %s\n' "$*" >&2
  if command -v notify-send >/dev/null; then
    notify-send -a browsevm -i dialog-warning "browsevm" "$*" 2>/dev/null || true
  fi
}

[[ $EUID -ne 0 ]] || { echo "browsevm: run as the daily user, not root" >&2; exit 2; }
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

if systemctl is-active --quiet "$UNIT"; then
  systemctl stop "$UNIT" || { note "an old VM is running and could not be stopped"; exit 1; }
fi
started=1
systemctl start "$UNIT" || { note "could not start $UNIT (journalctl -u $UNIT)"; exit 1; }
[[ -S $SOCK && -w $SOCK ]] || { note "no access to $SOCK"; exit 1; }

remote-viewer --title browsevm "spice+unix://$SOCK" 9>&-
