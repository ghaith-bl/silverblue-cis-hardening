#!/usr/bin/env bash
#
# firefox-apply-userjs.sh - install a user.js from this repo into a profile
#
#   ./browsers/firefox/firefox-apply-userjs.sh <profile-dir> <file.user.js>
#   ./browsers/firefox/firefox-apply-userjs.sh --restore <profile-dir>
#
# Firefox reads user.js at every start and writes its values into prefs.js,
# so the profile is put back to the repo state on each launch.
#
# Rules:
#   * Firefox must be closed (it rewrites prefs.js on exit)
#   * an existing user.js is backed up first: user.js.bak.<timestamp>
#   * removing a line from user.js later does NOT reset that pref -
#     reset it in about:config (or delete it from prefs.js while Firefox is closed)
#
set -euo pipefail

ROOTS=(
  "$HOME/.mozilla/firefox"
  "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox"
  "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
)

ok(){ printf '\033[32m  ok \033[0m %s\n' "$*"; }
er(){ printf '\033[31m  xx \033[0m %s\n' "$*" >&2; }

find_profile(){
  local name="$1" r
  case "$name" in */*|..*|"") er "give the profile directory name (see firefox-export-userjs.sh --list)"; exit 1 ;; esac
  for r in "${ROOTS[@]}"; do
    [ -f "$r/$name/prefs.js" ] && { echo "$r/$name"; return; }
  done
  er "profile '$name' not found"; exit 1
}

check_closed(){
  if pgrep -x firefox >/dev/null 2>&1 || pgrep -x firefox-bin >/dev/null 2>&1 ||
     pgrep -f '/usr/lib64/firefox/firefox' >/dev/null 2>&1; then
    er "Firefox is running - close every window first"
    exit 1
  fi
}

apply(){
  local dir src bak
  dir="$(find_profile "$1")"; src="$2"
  [ -f "$src" ] || { er "no such file: $src"; exit 1; }
  grep -q '^user_pref(' "$src" || { er "$src has no user_pref lines"; exit 1; }
  # every line must be a comment, blank, or a well-formed user_pref
  if grep -vnE '^\s*$|^\s*//|^user_pref\("[^"]+",\s*(true|false|-?[0-9]+|"[^"]*")\);\s*$' "$src"; then
    er "lines above are not valid user_pref syntax - not installed"; exit 1
  fi
  check_closed
  if [ -f "$dir/user.js" ]; then
    bak="$dir/user.js.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$dir/user.js" "$bak"
    ok "backup -> ${bak/#$HOME/\~}"
  fi
  install -m 0600 "$src" "$dir/user.js"
  ok "installed $(grep -c '^user_pref(' "$src") prefs -> ${dir/#$HOME/\~}/user.js"
  echo "   start Firefox with this profile, then check about:config / about:preferences#privacy"
}

restore(){
  local dir last
  dir="$(find_profile "$1")"
  check_closed
  last="$(find "$dir" -maxdepth 1 -name 'user.js.bak.*' -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)"
  if [ -n "$last" ]; then
    cp -a "$last" "$dir/user.js"; ok "restored ${last/#$HOME/\~}"
  else
    rm -f "$dir/user.js"; ok "no backup - user.js removed (prefs already written stay until reset)"
  fi
}

case "${1:-}" in
  --restore) restore "${2:-}" ;;
  ""|-*)     echo "usage: $0 <profile-dir> <file.user.js> | --restore <profile-dir>"; exit 1 ;;
  *)         apply "$1" "${2:-}" ;;
esac
