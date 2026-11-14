#!/usr/bin/env bash
#
# browsevm-ctl - start / stop the throwaway browsing VM (docs/browsevm.md)
#
# Installed as /usr/local/sbin/browsevm-ctl by "browsevm.sh install". Run as root by
# browsevm.service only: the daily user starts / stops that unit (polkit rule) and never
# talks to libvirt itself (libvirt access = root).
#
#   browsevm-ctl start   a tmpfs for the VM's disk, new empty overlay on the base image
#                        in it, network "browse" up, /run/browsevm for the SPICE socket,
#                        virsh start, socket handed to the viewing user (group, 0660, the
#                        VM's MCS pair)
#   browsevm-ctl stop    virsh shutdown, destroy after STOP_SECS, tmpfs unmounted (the
#                        overlay with it), base image back to root 0600 + its file
#                        context, network down, /run/browsevm removed
#
# The base image is never the VM's disk: it is the backing file of the overlay, which
# libvirt labels virt_content_t (read-only for every VM process). Whatever a session
# wrote is in the overlay, and the overlay lives in RAM only (tmpfs, RUN_SIZE at most):
# nothing of a session ever reaches the disk, and nothing is left after the stop. A full
# tmpfs pauses the VM (write error); closing the window ends it like any session.
#
set -uo pipefail

DOM=browsevm
NET=browse
BASE=/var/lib/libvirt/images/browsevm-base.qcow2   # same paths in browsevm.sh
RUNDISK=/var/lib/libvirt/browsevm-run               # mount point of the tmpfs
RUNIMG=$RUNDISK/browsevm-run.qcow2
RUN_SIZE=2g                              # most a session can write (RAM, only what is used)
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

selinux_on() { command -v selinuxenabled >/dev/null && selinuxenabled; }

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

# the base image while no VM runs: root 0600, the file context of its directory
# (virt_image_t). libvirt gives a backing file to QEMU's user for the run (read-only by
# its label) and does not take it back at stop.
base_at_rest() {
  [[ -f $BASE ]] || return 0
  chown root:root "$BASE" && chmod 0600 "$BASE"
  if selinux_on; then restorecon -F "$BASE" 2>/dev/null || true; fi
}

# the socket is made by QEMU (owner qemu): group = the viewing user's own group, 0660.
# Nobody else gets past the directory (0750). Directory and socket then get the MCS pair
# of this VM, like its disk: the QEMU process of another VM (same Unix user, other pair)
# cannot reach this VM's screen and keyboard.
hand_over() {
  local gid=$1 i label level
  for ((i = 0; i < SOCK_WAIT; i++)); do
    [[ -S $SOCK ]] && break
    sleep 0.5
  done
  [[ -S $SOCK ]] || return 1
  chgrp "$gid" "$SOCK" || return 1
  chmod 0660 "$SOCK" || return 1
  if selinux_on; then
    label=$("${V[@]}" dominfo "$DOM" 2>/dev/null | awk '/^Security label:/ { print $3 }')
    level=${label#*:*:*:}
    if [[ $level =~ ^s0:c[0-9]+,c[0-9]+$ ]]; then
      chcon -l "$level" "$RUN" "$SOCK" || say "warning: MCS pair $level not set on $RUN"
    else
      say "warning: no MCS pair in the domain's label '$label': $RUN stays s0"
    fi
  fi
}

# the VM's disk lives here: RAM only, a directory of the image type so QEMU may enter it
# (the overlay itself gets the VM's own label from libvirt)
disk_up() {
  local opts="size=$RUN_SIZE,mode=0711,nosuid,nodev,noexec"
  disk_down || return 1
  install -d -m 0711 -o root -g root "$RUNDISK" || return 1
  if selinux_on; then opts+=",rootcontext=system_u:object_r:virt_image_t:s0"; fi
  mount -t tmpfs -o "$opts" browsevm-run "$RUNDISK"
}

disk_down() {
  if mountpoint -q "$RUNDISK"; then
    umount "$RUNDISK" || { say "warning: $RUNDISK is busy, not unmounted"; return 1; }
  fi
  return 0
}

down() {
  if net_active && ! net_used_by_others; then
    "${V[@]}" net-destroy "$NET" >/dev/null && say "network $NET stopped"
  fi
  rm -rf -- "$RUN"
  disk_down
  base_at_rest
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
  [[ -f $BASE ]] || die "$BASE missing: browsevm.sh build"

  # a new empty overlay in a new tmpfs: the VM's only writable disk. A leftover tmpfs
  # (the VM died without a stop) is unmounted first.
  base_at_rest
  disk_up || die "could not mount a tmpfs on $RUNDISK"
  ( umask 077; qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$RUNIMG" ) ||
    { disk_down; die "qemu-img could not create $RUNIMG"; }

  if ! net_active; then
    "${V[@]}" net-start "$NET" >/dev/null || { down; die "network $NET did not start"; }
    say "network $NET started"
  fi

  # QEMU makes the SPICE socket here itself: a directory of its own user, with a type
  # svirt_t may create sockets in. Group = the viewing user (search only).
  rm -rf -- "$RUN"
  install -d -m 0750 -o "$QEMU_USER" -g "$gid" "$RUN" || { down; die "could not create $RUN"; }
  if selinux_on; then
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
  say "started (new overlay in RAM), socket $SOCK"
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
    st=$(state)
    # still alive: its disk and its base are left alone
    [[ $st == "shut off" || $st == gone ]] || die "domain is still '$st': not cleaned up"
  fi
  down
  say "stopped (overlay gone with its tmpfs)"
}

[[ $EUID -eq 0 ]] || die "run as root (by browsevm.service)"
case "${1:-}" in
  start) cmd_start ;;
  stop)  cmd_stop ;;
  *)     echo "usage: browsevm-ctl start|stop" >&2; exit 2 ;;
esac
