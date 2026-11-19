#!/usr/bin/env bash
# tools/check-accounts.sh - read-only check of the admin / daily account split.
#
# usage: sudo tools/check-accounts.sh <admin user> <daily user>
#
# - changes nothing: reads group/passwd data, PAM and AccountsService files,
#   /proc credentials, unit states, sudo.log, owners / modes in /usr/local/{bin,sbin},
#   the admin's shell start files (against accounts/admin.* of this repo) and file flags
# - one line per check: PASS / FAIL / INFO
# - keeps a copy readable by the daily user in /tmp/check-accounts.XXXXXX
#   (no secrets: group lists, modes, unit states; tty consoles can't copy/paste)
# - exit 0 = no FAIL, 1 = at least one FAIL, 2 = usage error
#
# refs: CIS Controls v8.1 5.4, NIST SP 800-53 AC-6(2), NSA/CISA AA23-278A
set -uo pipefail
umask 077

die() { printf 'check-accounts: %s\n' "$*" >&2; exit 2; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

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

# no 'cmd | grep -q' under pipefail: grep -q quits at the first match, the writer can get
# SIGPIPE and the pipe fails although the line was there (docs/lessons-learned.md)
in_group() { [[ " $(id -nG "$1" 2>/dev/null) " == *" $2 "* ]]; }

stale() {  # $1 uid, $2 gid: running processes of uid that still hold gid
  awk -v u="$1" -v g="$2" '
    FNR == 1  { uid = ""; hit = 0 }
    /^Uid:/   { uid = $2 }
    /^Groups:/ { for (i = 2; i <= NF; i++) if ($i == g) hit = 1
                 if (uid == u && hit) n++ }
    END       { print n + 0 }' /proc/[0-9]*/status 2>/dev/null
}

# immutable <path>: chattr +i set (first lsattr field holds a lowercase i; no link followed)
immutable() { [[ ! -L $1 && $(lsattr -d -- "$1" 2>/dev/null) =~ ^[^[:space:]]*i ]]; }

# pam_auth <service>: its auth lines, include / substack expanded, as "control module args"
# (a [..] control without spaces)
PAM_RE='^[[:space:]]*-?auth[[:space:]]+(\[[^]]*\]|[^[:space:]]+)[[:space:]]+([^[:space:]]+)(.*)$'
pam_auth() {
  local f=/etc/pam.d/$1 d=${2:-0} line ctl
  [[ -r $f ]] && (( d < 5 )) || return 0
  while IFS= read -r line; do
    line=${line%%#*}
    [[ $line =~ $PAM_RE ]] || continue
    ctl=${BASH_REMATCH[1]}
    if [[ $ctl == include || $ctl == substack ]]; then
      pam_auth "${BASH_REMATCH[2]}" $((d + 1))
    else
      printf '%s %s%s\n' "${ctl// /,}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    fi
  done < "$f"
}

# refuses_all <service>: its auth stack fails for every user: required / requisite pam_deny,
# or pam_debug returning an error (authselect's stub), before any line that can end the
# stack with success (sufficient, [..] with done / jumps): those make it unprovable
refuses_all() {
  local ctl mod rest
  while read -r ctl mod rest; do
    case $ctl in
      required|requisite)
        [[ $mod == pam_deny.so ]] && return 0
        [[ $mod == pam_debug.so && " $rest " == *" auth="* && " $rest " != *" auth=success "* ]] && return 0 ;;
      optional) ;;
      *) return 1 ;;
    esac
  done < <(pam_auth "$1")
  return 1
}

unit_file() { # $1 unit: does its unit file exist (template for name@inst)
  local u=$1 f
  [[ $u == *@* ]] && f="${u%%@*}@.${u##*.}" || f=$u
  [[ -e /etc/systemd/system/$f || -e /usr/lib/systemd/system/$f ]]
}

main() {
  local daily_uid g gid n home mode line f s rc src ha bad
  daily_uid=$(id -u "$DAILY")
  printf 'check-accounts  admin=%s  daily=%s  %s\n\n' "$ADMIN" "$DAILY" "$(date -Is)"

  # --- privileged groups: admin only
  expect "wheel members" "$(members wheel)" "$ADMIN"
  if getent group mullvad >/dev/null; then
    expect "mullvad members" "$(members mullvad)" "$ADMIN"
  fi
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
  if sudo -n -l -U "$DAILY" 2>&1 | grep 'is not allowed to run sudo' >/dev/null; then
    out PASS "sudo: daily" "not allowed"
  else
    out FAIL "sudo: daily" "allowed | want: not allowed"
  fi
  if sudo -n -l -U "$ADMIN" 2>&1 | grep -F '(ALL) ALL' >/dev/null; then
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
  # every GDM PAM service (review A-4): refuses the admin, refuses everyone, or is unused
  for f in /etc/pam.d/gdm-*; do
    [[ -f $f ]] || continue
    s=${f##*/}
    [[ $s == *-auth-substack ]] && continue        # GDM 51: wrappers, read through the services
    if grep -qE "^[[:space:]]*auth[[:space:]]+requisite[[:space:]]+pam_succeed_if\.so[[:space:]]+user[[:space:]]+!=[[:space:]]+$ADMIN([[:space:]]|$)" "$f"; then
      out PASS "${s/-/ }" "admin refused (pam_succeed_if)"
    elif refuses_all "$s"; then
      out PASS "${s/-/ }" "refuses every user (stub / pam_deny in its auth stack)"
    elif [[ $s == gdm-autologin ]]; then
      if grep -iqE '^[[:space:]]*(AutomaticLoginEnable|TimedLoginEnable)[[:space:]]*=[[:space:]]*(true|1|yes)' \
           /etc/gdm/custom.conf 2>/dev/null; then
        out FAIL "${s/-/ }" "automatic / timed login on in /etc/gdm/custom.conf"
      else
        out PASS "${s/-/ }" "unused: no automatic / timed login in /etc/gdm/custom.conf"
      fi
    elif [[ $s == gdm-launch-environment ]]; then
      out INFO "${s/-/ }" "the greeter's own session (GDM's user), no user login"
    else
      out FAIL "${s/-/ }" "admin not refused and the stack is not a stub: look at it"
    fi
  done
  bad=""
  for s in switchable passkey web smartcard; do
    grep -qx "enable-$s-authentication=false" /etc/dconf/db/gdm.d/90-cis-hardening 2>/dev/null &&
      grep -qx "/org/gnome/login-screen/enable-$s-authentication" \
        /etc/dconf/db/gdm.d/locks/90-cis-hardening 2>/dev/null || bad+="$s "
  done
  if [[ -z $bad ]]; then out PASS "gdm methods" "password only: switchable, passkey, web, smartcard off + locked"
  else out FAIL "gdm methods" "not off + locked: ${bad% } (gnome section)"; fi
  for u in "$ADMIN" "$DAILY"; do
    home=$(getent passwd "$u" | cut -d: -f6)
    mode=$(stat -c '%a %U' "$home" 2>/dev/null)
    expect "home $u" "$mode" "700 $u"
  done

  # --- admin home (review A-3): shell start files = accounts/admin.* of this repo, owner
  # the admin, 640, immutable; files read at shell start absent; top of the home and its
  # config dirs immutable (nothing new there); no known place that runs code inside them
  ha=$(getent passwd "$ADMIN" | cut -d: -f6)
  for rc in bash_profile bashrc bash_logout inputrc; do
    f=$ha/.$rc src=$HERE/accounts/admin.$rc
    if [[ ! -f $src ]]; then out FAIL "rc .$rc" "no $src to compare with"
    elif [[ -L $f || ! -f $f ]]; then out FAIL "rc .$rc" "missing or a link"
    elif ! cmp -s "$f" "$src"; then out FAIL "rc .$rc" "differs from accounts/admin.$rc"
    elif [[ $(stat -c '%U %a' "$f") != "$ADMIN 640" ]]; then
      out FAIL "rc .$rc" "have: $(stat -c '%U %a' "$f") | want: $ADMIN 640"
    elif ! immutable "$f"; then out FAIL "rc .$rc" "not immutable (chattr +i)"
    else out PASS "rc .$rc" "as accounts/, 640, immutable, sha256 $(sha256sum < "$f" | cut -c1-8)"; fi
  done
  bad=""
  for f in .profile .bash_login .bash_completion .i18n .config/bash_completion; do
    [[ -e $ha/$f || -L $ha/$f ]] && bad+="$f "
  done
  if [[ -z $bad ]]; then out PASS "start files" "none of .profile .bash_login .bash_completion .i18n .config/bash_completion"
  else out FAIL "start files" "present: ${bad% } (accounts section removes them)"; fi
  bad="" line=""
  for f in "" .config .local .local/share .config/systemd .local/share/systemd .local/share/flatpak; do
    s=$ha${f:+/$f}
    if [[ -L $s ]]; then bad+="${f:-home}(link) "
    elif [[ -d $s ]]; then
      if immutable "$s"; then line+="${f:-home} "; else bad+="${f:-home} "; fi
    fi
  done
  if [[ -z $bad ]]; then out PASS "frozen dirs" "immutable: ${line% }"
  else out FAIL "frozen dirs" "not immutable: ${bad% }"; fi
  bad=""
  for f in .config/systemd/user .local/share/systemd/user .config/git .config/environment.d \
           .local/share/bash-completion .local/share/flatpak/exports; do
    [[ -e $ha/$f || -L $ha/$f ]] && bad+="$f "
  done
  if [[ -z $bad ]]; then out PASS "code places" "no user units, completions, git config, flatpak exports"
  else out FAIL "code places" "present (writable, run code): ${bad% }"; fi
  line=""
  for f in "" .config .local .local/share; do
    [[ -d $ha${f:+/$f} && ! -L $ha${f:+/$f} ]] || continue
    while IFS= read -r s; do
      [[ $f == "" && ( $s == .config || $s == .local ) ]] && continue
      [[ $f == .local && $s == share ]] && continue
      immutable "$ha${f:+/$f}/$s" || line+="${f:+$f/}$s "
    done < <(find "$ha${f:+/$f}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  done
  line=${line% }
  out INFO "writable dirs" "${line:-none}"

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
    if mullvad lockdown-mode get 2>/dev/null | grep -iE '(:|[[:space:]])on$' >/dev/null; then
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

  # --- programs on the admin's PATH: a file the daily user (or anyone but root) can
  # change there runs with the admin's rights the next time the admin types its name
  for d in /usr/local/bin /usr/local/sbin; do
    [[ -d $d ]] || continue
    line=$(find -L "$d" -mindepth 1 -maxdepth 1 \( ! -user root -o -perm /022 \) -printf '%f(%u) ' 2>/dev/null)
    if [[ -z $line ]]; then out PASS "path ${d#/usr/}" "root-owned, not group/world writable"
    else out FAIL "path ${d#/usr/}" "${line% }: owner must be root, no group/world write"; fi
  done

  # --- evidence and policy notes
  if [[ -r /var/log/sudo.log ]]; then
    line=$(grep -F " : $DAILY : " /var/log/sudo.log | grep -iE 'not in sudoers|not allowed' | tail -n 1)
    out INFO "sudo.log daily" "${line:-no refused attempt logged yet}"
  fi
  for u in "$ADMIN" "$DAILY"; do
    out INFO "aging $u" "$(LC_ALL=C chage -l "$u" | awk -F': ' '/^Minimum/ {m = $2} /^Maximum/ {x = $2}
      END {print "min days " m ", max days " x}')"
  done

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
