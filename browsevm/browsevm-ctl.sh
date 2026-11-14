#!/usr/bin/env bash
#
# browsevm-ctl - start / stop the throwaway browsing VM (docs/browsevm.md)
#
# Installed as /usr/local/sbin/browsevm-ctl by "browsevm.sh install". Run as root by
# browsevm.service only: the daily user starts / stops that unit (polkit rule) and never
# talks to libvirt itself (libvirt access = root).
#
#   browsevm-ctl start   network "browse" up, /run/browsevm for the SPICE socket,
#                        virsh start, socket handed to the viewing user (group, 0660)
#   browsevm-ctl stop    virsh shutdown, destroy after STOP_SECS, network down,
#                        /run/browsevm removed
#
# The disk is <transient/>: libvirt deletes the overlay when the VM stops, shut down or
# destroyed, so nothing of a session is left.
#
set -uo pipefail

DOM=browsevm
NET=browse
RUN=/run/browsevm
SOCK=$RUN/spice.sock
VIEW_USER_FILE=/etc/browsevm/view-user   # one line: the user who may view (written by install)
QEMU_USER=qemu                           # user of the QEMU process (qemu.conf default)
SOCK_TYPE=qemu_var_run_t                 # svirt_t may create a socket in a dir of this type
SOCK_WAIT=30                             # x 0.5 s
STOP_SECS=20
V=(virsh -q -c qemu:///system)

say() { printf 'browsevm-ctl: %s\n' "$*"; }
die() { printf 'browsevm-ctl: %s\n' "$*" >&2; exit 1; }

state() { "${V[@]}" domstate "$DOM" 2>/dev/null || echo gone; }

net_active() { [[ $("${V[@]}" net-info "$NET" 2>/dev/null | sed -n 's/^Active: *//p') == yes ]]; }

# another running domain on the network (a base image build): the network stays up
net_used_by_others() {
  local d
  while read -r d; do
    [[ -n $d && $d != "$DOM" ]] || continue
    "${V[@]}" domiflist "$d" 2>/dev/null |
      awk -v n="$NET" '$2 == "network" && $3 == n { f = 1 } END { exit !f }' && return 0
  done < <("${V[@]}" list --name 2>/dev/null)
  return 1
}

view_gid() {
  local user
  [[ -f $VIEW_USER_FILE ]] || die "$VIEW_USER_FILE missing: browsevm.sh install"
  read -r user < "$VIEW_USER_FILE" || true
  [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "$VIEW_USER_FILE: not a user name"
  id -g "$user" 2>/dev/null || die "$VIEW_USER_FILE: no such user"
}

# the socket is made by QEMU (owner qemu, 0775 minus the dir): group = the viewing user's
# own group, 0660. Nobody else gets past the directory (0750).
hand_over() {
  local gid=$1 i
  for ((i = 0; i < SOCK_WAIT; i++)); do
    [[ -S $SOCK ]] && break
    sleep 0.5
  done
  [[ -S $SOCK ]] || return 1
  chgrp "$gid" "$SOCK" && chmod 0660 "$SOCK"
}

down() {
  if net_active && ! net_used_by_others; then
    "${V[@]}" net-destroy "$NET" >/dev/null && say "network $NET stopped"
  fi
  rm -rf -- "$RUN"
}

cmd_start() {
  local gid st
  gid=$(view_gid) || exit 1
  id "$QEMU_USER" >/dev/null 2>&1 || die "no user $QEMU_USER"
  st=$(state)
  case $st in
    running)    hand_over "$gid" || die "running, but no socket $SOCK (stop it first)"
                say "already running"; return 0 ;;
    "shut off") ;;
    gone)       die "domain $DOM missing: browsevm.sh install" ;;
    *)          die "domain state '$st': stop it first" ;;
  esac

  if ! net_active; then
    "${V[@]}" net-start "$NET" >/dev/null || die "network $NET did not start"
    say "network $NET started"
  fi

  # QEMU makes the SPICE socket here itself: a directory of its own user, with a type
  # svirt_t may create sockets in. Group = the viewing user (search only).
  rm -rf -- "$RUN"
  install -d -m 0750 -o "$QEMU_USER" -g "$gid" "$RUN" || { down; die "could not create $RUN"; }
  if command -v selinuxenabled >/dev/null && selinuxenabled; then
    chcon -t "$SOCK_TYPE" "$RUN" || { down; die "chcon $SOCK_TYPE $RUN failed"; }
  fi

  if ! "${V[@]}" start "$DOM" >/dev/null; then
    down
    die "virsh start failed (journalctl -u virtqemud, /var/log/libvirt/qemu/$DOM.log)"
  fi
  if ! hand_over "$gid"; then
    "${V[@]}" destroy "$DOM" >/dev/null 2>&1
    down
    die "no SPICE socket $SOCK after $((SOCK_WAIT / 2)) s"
  fi
  say "started (clean overlay), socket $SOCK"
}

cmd_stop() {
  local st i
  st=$(state)
  if [[ $st != "shut off" && $st != gone ]]; then
    "${V[@]}" shutdown "$DOM" >/dev/null 2>&1
    for ((i = 0; i < STOP_SECS; i++)); do
      [[ $(state) == "shut off" ]] && break
      sleep 1
    done
    if [[ $(state) != "shut off" ]]; then
      "${V[@]}" destroy "$DOM" >/dev/null 2>&1
      say "no shutdown in $STOP_SECS s: destroyed"
    fi
  fi
  down
  say "stopped (overlay deleted by libvirt)"
}

[[ $EUID -eq 0 ]] || die "run as root (by browsevm.service)"
case "${1:-}" in
  start) cmd_start ;;
  stop)  cmd_stop ;;
  *)     echo "usage: browsevm-ctl start|stop" >&2; exit 2 ;;
esac
