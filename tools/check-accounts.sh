#!/usr/bin/env bash
# tools/check-accounts.sh - read-only check of the admin / daily account split.
#
# usage: sudo tools/check-accounts.sh <admin user> <daily user>
#
# - changes nothing: reads group/passwd data, PAM and AccountsService files,
#   /proc credentials, unit states, sudo.log
# - one line per check: PASS / FAIL / INFO
# - keeps a copy readable by the daily user in /tmp/check-accounts.XXXXXX
#   (no secrets: group lists, modes, unit states; tty consoles can't copy/paste)
# - exit 0 = no FAIL, 1 = at least one FAIL, 2 = usage error
#
# refs: CIS Controls v8 5.4, NIST SP 800-53 AC-6(2), NSA/CISA AA23-278A
set -uo pipefail
umask 077

die() { printf 'check-accounts: %s\n' "$*" >&2; exit 2; }

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ $# -eq 2 ]] || die "usage: sudo $0 <admin user> <daily user>"
ADMIN=$1 DAILY=$2
for u in "$ADMIN" "$DAILY"; do
  [[ $u =~ ^[a-z_][a-z0-9_-]*$ && $u != root ]] || die "bad user name: $u"
  id "$u" >/dev/null 2>&1 || die "no such user: $u"
done
[[ $ADMIN != "$DAILY" ]] || die "admin and daily user must differ"

fails=0

out() {    # $1 PASS|FAIL|INFO, $2 check, $3 text
  printf '%-4s  %-20s  %s\n' "$1" "$2" "$3"
  [[ $1 == FAIL ]] && fails=$((fails + 1))
  return 0
}

expect() { # $1 check, $2 have, $3 want: PASS when equal
  if [[ $2 == "$3" ]]; then out PASS "$1" "$2"
  else out FAIL "$1" "have: ${2:--} | want: ${3:--}"; fi
}

members() { # $1 group: its member list, sorted, comma separated
  getent group "$1" | cut -d: -f4 | tr ',' '\n' | sed '/^$/d' | sort | paste -sd, -
}

in_group() { id -nG "$1" | tr ' ' '\n' | grep -qx "$2"; }

stale() {  # $1 uid, $2 gid: running processes of uid that still hold gid
  awk -v u="$1" -v g="$2" '
    FNR == 1  { uid = ""; hit = 0 }
    /^Uid:/   { uid = $2 }
    /^Groups:/ { for (i = 2; i <= NF; i++) if ($i == g) hit = 1
                 if (uid == u && hit) n++ }
    END       { print n + 0 }' /proc/[0-9]*/status 2>/dev/null
}

unit_file() { # $1 unit: does its unit file exist (template for name@inst)
  local u=$1 f
  [[ $u == *@* ]] && f="${u%%@*}@.${u##*.}" || f=$u
  [[ -e /etc/systemd/system/$f || -e /usr/lib/systemd/system/$f ]]
}

main() {
  local daily_uid g gid n home mode line
  daily_uid=$(id -u "$DAILY")
  printf 'check-accounts  admin=%s  daily=%s  %s\n\n' "$ADMIN" "$DAILY" "$(date -Is)"

  # --- privileged groups: admin only
  expect "wheel members" "$(members wheel)" "$ADMIN"
  for g in mullvad; do
    getent group "$g" >/dev/null || continue
    expect "$g members" "$(members "$g")" "$ADMIN"
  done
  if getent group sectop >/dev/null; then
    in_group "$ADMIN" sectop && out PASS "sectop: admin" "member" \
                             || out FAIL "sectop: admin" "not a member"
    in_group "$DAILY" sectop && out FAIL "sectop: daily" "member | want: not a member" \
                             || out PASS "sectop: daily" "not a member"
  fi
  if getent group sectop-feed >/dev/null; then      # sectop 2026-11-05: unit Group= only
    expect "sectop-feed members" "$(members sectop-feed)" ""
    expect "helper dir" "$(stat -c '%U:%G %a' "/run/sectop-user/$DAILY" 2>/dev/null)" \
           "$DAILY:sectop-feed 750"
  fi
  out INFO "daily groups" "$(id -nG "$DAILY")"

  # --- old credentials: daily processes started before the change
  for g in wheel mullvad; do
    gid=$(getent group "$g" | cut -d: -f3) || continue
    [[ -n $gid ]] || continue
    n=$(stale "$daily_uid" "$gid")
    if [[ $n == 0 ]]; then out PASS "live $g" "no $DAILY process holds it"
    else out FAIL "live $g" "$n $DAILY processes still hold it: log out or reboot"; fi
  done

  # --- sudo policy
  if sudo -n -l -U "$DAILY" 2>&1 | grep -q 'is not allowed to run sudo'; then
    out PASS "sudo: daily" "not allowed"
  else
    out FAIL "sudo: daily" "allowed | want: not allowed"
  fi
  if sudo -n -l -U "$ADMIN" 2>&1 | grep -q '(ALL) ALL'; then
    out PASS "sudo: admin" "(ALL) ALL"
  else
    out FAIL "sudo: admin" "no (ALL) ALL rule: fix before anything else"
  fi
  line=$(passwd -S root 2>/dev/null | awk '{print $2}')
  [[ $line == L || $line == LK ]] && out PASS "root password" "locked" \
                                   || out FAIL "root password" "have: ${line:--} | want: locked"

  # --- admin: text console only
  if grep -qx 'SystemAccount=true' "/var/lib/AccountsService/users/$ADMIN" 2>/dev/null; then
    out PASS "gdm list" "admin hidden"
  else
    out FAIL "gdm list" "admin shown | want: SystemAccount=true"
  fi
  if grep -qE "^auth[[:space:]]+requisite[[:space:]]+pam_succeed_if\.so[[:space:]]+user[[:space:]]+!=[[:space:]]+$ADMIN([[:space:]]|$)" \
       /etc/pam.d/gdm-password 2>/dev/null; then
    out PASS "gdm login" "admin refused (pam_succeed_if)"
  else
    out FAIL "gdm login" "no pam_succeed_if line for $ADMIN in gdm-password"
  fi
  for u in "$ADMIN" "$DAILY"; do
    home=$(getent passwd "$u" | cut -d: -f6)
    mode=$(stat -c '%a %U' "$home" 2>/dev/null)
    expect "home $u" "$mode" "700 $u"
  done

  # --- sectop sysusers: re-applied at every boot
  if [[ -e /etc/sysusers.d/sectop.conf ]]; then
    grep -qx "m $ADMIN sectop" /etc/sysusers.d/sectop.conf \
      && out PASS "sysusers admin" "m $ADMIN sectop" \
      || out FAIL "sysusers admin" "no 'm $ADMIN sectop' line"
    grep -qx "m $DAILY sectop" /etc/sysusers.d/sectop.conf \
      && out FAIL "sysusers daily" "'m $DAILY sectop' re-adds it at boot" \
      || out PASS "sysusers daily" "no line"
  fi

  # --- VPN still enforced after moving the mullvad group
  if command -v mullvad >/dev/null; then
    if mullvad lockdown-mode get 2>/dev/null | grep -qiE '(:|[[:space:]])on$'; then
      out PASS "mullvad lockdown" "on"
    else
      out FAIL "mullvad lockdown" "not on"
    fi
    out INFO "mullvad status" "$(mullvad status 2>&1 | head -n 1)"
  fi

  # --- sectop units
  for u in sectop.service sectop-net.service "sectop-user@$DAILY.service" sectop-whois.socket; do
    unit_file "$u" || continue
    expect "unit ${u%.*}" "$(systemctl is-active "$u")" active
  done

  # --- evidence and policy notes
  if [[ -r /var/log/sudo.log ]]; then
    line=$(grep -F " : $DAILY : " /var/log/sudo.log | grep -iE 'not in sudoers|not allowed' | tail -n 1)
    out INFO "sudo.log daily" "${line:-no refused attempt logged yet}"
  fi
  out INFO "expiry $ADMIN" "$(chage -l "$ADMIN" | awk -F': ' '/^Maximum/ {print "max days " $2}')"

  printf '\n%s FAIL\n' "$fails"
  return $(( fails > 0 ))
}

report=$(mktemp /tmp/check-accounts.XXXXXX) || die "mktemp failed"
main > "$report"
rc=$?
chmod 0644 "$report"
cat "$report"
printf 'copy: %s\n' "$report"
exit "$rc"
