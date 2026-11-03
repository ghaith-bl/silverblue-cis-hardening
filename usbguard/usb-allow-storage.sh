#!/usr/bin/env bash
#
# usb-allow-storage - allow ONE blocked USB flash drive / disk until it is unplugged.
#
#   sudo usb-allow-storage        list blocked devices; allow the drive if it is the only one
#   sudo usb-allow-storage <id>   allow this device (id = first column of the list)
#
# Installed by harden-workstation.sh (usbguard section) to /usr/local/sbin, root owned:
# a root tool must not run from a folder my user can write.
#
# Allowed only if EVERY interface of the device is mass storage (class 08). A "flash drive"
# that also has a keyboard / mouse / network interface (BadUSB) is refused; allow such a
# device by hand with usbguard if you really want it.
# The allow is not permanent (no -p): unplugged = gone, next time run this again.
# Devices that a block rule in rules.conf matches (Bluetooth adapter) are not listed.
#
# Exit 0 = allowed, 1 = nothing allowed, 2 = error.
set -euo pipefail
export LC_ALL=C

log()  { printf '\e[32m[+]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[!]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[31m[x]\e[0m %s\n' "$1" >&2; exit "${2:-1}"; }

# list-devices line with every quoted value emptied; quotes inside values are escaped
# (\"), so the regex below can only see usbguard's own field names, never text from
# the device (name, serial).
QUOTED='"([^"\\]|\\.)*"'
IFACE='[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}'
LINE_RE="^([0-9]+): block id ([0-9a-f]{4}:[0-9a-f]{4}) serial \"\" name \"\" hash \"\" parent-hash \"\" via-port \"\" with-interface (\\{(( ${IFACE})+) \\}|(${IFACE})) with-connect-type \"\"\$"

# parse <line>: sets D_ID D_VIDPID D_IFS D_NAME D_HASH; 1 = line not in the expected form
parse() {
  local line=$1 bare
  local -a q
  bare="$(sed -E "s/${QUOTED}/\"\"/g" <<<"$line")"
  [[ $bare =~ $LINE_RE ]] || return 1
  D_ID=${BASH_REMATCH[1]}
  D_VIDPID=${BASH_REMATCH[2]}
  D_IFS="${BASH_REMATCH[4]}${BASH_REMATCH[6]}"
  D_IFS=${D_IFS# }
  # quoted values in order: serial name hash parent-hash via-port with-connect-type
  mapfile -t q < <(grep -oE "$QUOTED" <<<"$line")
  (( ${#q[@]} == 6 )) || return 1
  D_NAME="$(tr -cd '[:print:]' <<<"${q[1]}")"
  D_HASH=${q[2]}
}

# only_class <class> <interfaces>: every interface of this class? (08 storage, 09 hub)
only_class() {
  local c=$1 i
  for i in $2; do [[ $i == "$c":* ]] || return 1; done
}

# in_list <value> <list...>
in_list() {
  local v=$1 x
  shift
  for x in "$@"; do [[ $x == "$v" ]] && return 0; done
  return 1
}

main() {
  local want="" line r answer="" chosen="" chosen_name=""
  local -a blocked rules cand=() other=()
  [[ $EUID -eq 0 ]] || die "run with sudo" 2
  (( $# <= 1 )) || die "usage: sudo usb-allow-storage [id]" 2
  if (( $# == 1 )); then
    [[ $1 =~ ^[0-9]+$ ]] || die "id must be a number (first column of the list)" 2
    want=$1
  fi
  systemctl is-active -q usbguard.service || die "usbguard is not running" 2

  mapfile -t blocked < <(usbguard list-devices --blocked)
  mapfile -t rules < <(usbguard list-rules)

  printf '%-4s %-9s %-26s %s\n' id vid:pid interfaces name
  for line in "${blocked[@]}"; do
    [[ -n $line ]] || continue
    if ! parse "$line"; then
      warn "a blocked device line in an unexpected form: skipped (sudo usbguard list-devices --blocked)"
      continue
    fi
    # blocked on purpose by a rule (e.g. the Bluetooth adapter): not offered
    for r in "${rules[@]}"; do
      if [[ $r == *": block "* && $r == *" hash ${D_HASH} "* ]]; then continue 2; fi
    done
    if only_class 08 "$D_IFS"; then
      cand+=("$D_ID")
      printf '%-4s %-9s %-26s %s  <- storage only\n' "$D_ID" "$D_VIDPID" "$D_IFS" "$D_NAME"
    else
      other+=("$D_ID")
      printf '%-4s %-9s %-26s %s  <- NOT storage, stays blocked\n' "$D_ID" "$D_VIDPID" "$D_IFS" "$D_NAME"
      if only_class 09 "$D_IFS"; then
        warn "id $D_ID is a USB hub: devices behind it stay invisible, plug the drive in directly"
      fi
    fi
    if [[ -z $want && ${#cand[@]} -eq 1 && ${cand[0]} == "$D_ID" ]] || [[ $D_ID == "$want" ]]; then
      chosen_name=$D_NAME
    fi
  done

  if [[ -n $want ]]; then
    in_list "$want" "${cand[@]}" "${other[@]}" || die "id $want: not a blocked device in the list"
    in_list "$want" "${cand[@]}" || die "id $want is not storage only: not allowed"
    chosen=$want
  else
    (( ${#cand[@]} > 0 )) || die "no blocked flash drive: plug it in (directly, no hub), then run again"
    (( ${#cand[@]} == 1 )) || die "${#cand[@]} storage devices blocked: run again with the id"
    if (( ${#other[@]} > 0 )); then
      warn "other blocked devices too: if one of them is the drive you just plugged in, do NOT use it"
      die "run again with the id if you are sure"
    fi
    chosen=${cand[0]}
  fi

  read -r -p "allow id $chosen ($chosen_name) until it is unplugged? [y/N] " answer || true
  [[ $answer == y || $answer == Y ]] || die "nothing allowed"
  # the id belongs to this one connection: unplugged and plugged again = new id, blocked
  usbguard allow-device "$chosen" || die "usbguard allow-device $chosen failed (unplugged?)" 2
  log "id $chosen allowed until it is unplugged (no automount: open it in Files)"
}

main "$@"
