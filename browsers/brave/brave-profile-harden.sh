#!/usr/bin/env bash
#
# brave-profile-harden.sh - per-profile leftovers for Brave
#
# Almost everything is now enforced system-wide by policies.json
# (/etc/brave/policies/managed/). This script only covers what has
# NO policy, and lets me check a profile without changing it.
#
#   --list                 show profiles it can find
#   --inspect [profile]    print privacy-relevant keys, change nothing
#   --apply   [profile]    back up, then set the non-policy keys
#   --restore [profile]    roll back to the newest backup
#
# Safety rules:
#   * refuses to run --apply/--restore while Brave is open
#     (Brave rewrites Preferences on exit)
#   * never touches "Secure Preferences" (HMAC-signed; editing it makes
#     Brave reset settings and show a warning)
#   * writes to a temp file first, then renames (no half-written JSON)
#
set -euo pipefail

ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/BraveSoftware/Brave-Browser"
POLICY_FILE="/etc/brave/policies/managed/policies.json"

ok(){ printf '\033[32m  ok \033[0m %s\n' "$*"; }
nn(){ printf '\033[33m  !! \033[0m %s\n' "$*"; }
er(){ printf '\033[31m  xx \033[0m %s\n' "$*" >&2; }
hd(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

command -v python3 >/dev/null || { er "python3 not found"; exit 1; }

find_root(){
  if [ -d "$ROOT" ]; then echo "$ROOT"
  else
    er "no Brave profile directory found"
    echo "     looked in: $ROOT" >&2
    exit 1
  fi
}

check_closed(){
  if pgrep -x brave >/dev/null 2>&1; then
    er "Brave is running. Close it completely first:"
    echo "       pkill -x brave" >&2
    exit 1
  fi
}

PROFILE="${2:-Default}"
case "$PROFILE" in
  */*|..*) er "profile must be a directory name like 'Default' or 'Profile 1'"; exit 1 ;;
esac
pref_file(){ echo "$(find_root)/$PROFILE/Preferences"; }

list_profiles(){
  local root d found=0
  root="$(find_root)"
  hd "Profiles in ${root/#$HOME/\~}"
  for d in "$root"/*/; do
    [ -f "$d/Preferences" ] || continue
    found=1
    printf '   %-14s  %-20s %s\n' "$(basename "$d")" \
      "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("profile",{}).get("name","?")[:20])' "$d/Preferences" 2>/dev/null)" \
      "$(du -sh "$d" 2>/dev/null | cut -f1)"
  done
  [ "$found" = 1 ] || nn "no profile with a Preferences file"
  echo
  echo "   Use the directory name (left column) as the profile argument."
  echo "   (profile names are shown on screen only, never written anywhere)"
}

policy_status(){
  hd "System policy"
  if [ -f "$POLICY_FILE" ]; then
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$POLICY_FILE" 2>/dev/null; then
      ok "$POLICY_FILE present, valid JSON"
    else
      er "$POLICY_FILE is NOT valid JSON - Brave ignores the whole file"
    fi
    [ -L "$POLICY_FILE" ] && nn "it is a symlink - install-policies.sh installs a regular file"
  else
    nn "$POLICY_FILE missing - run browsers/install-policies.sh"
  fi
  echo "   confirm in the browser: brave://policy  (every row 'OK', no errors)"
}

inspect(){
  local f; f="$(pref_file)"
  [ -f "$f" ] || { er "no Preferences at ${f/#$HOME/\~}"; exit 1; }
  policy_status
  hd "Profile: $PROFILE"
  python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))

def get(path):
    o = d
    for p in path.split("."):
        if not isinstance(o, dict) or p not in o:
            return "(not set)"
        o = o[p]
    return o

print("\n   -- keys with no policy (this script sets them) --")
for k in ["profile.default_content_setting_values.midi_sysex",
          "webrtc.multiple_routes_enabled",
          "webrtc.nonproxied_udp_enabled",
          "enable_do_not_track"]:
    print(f"      {k} = {get(k)}")

print("\n   -- content setting defaults stored in profile (policy wins over these) --")
cs = d.get("profile", {}).get("default_content_setting_values", {})
for k in sorted(cs) or ["(none)"]:
    print(f"      {k} = {cs.get(k, '')}")
PY
  echo
  echo "   Nothing was changed."
}

apply(){
  local f; f="$(pref_file)"
  [ -f "$f" ] || { er "no Preferences at ${f/#$HOME/\~}"; exit 1; }
  check_closed

  local bak; bak="$f.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "$bak"
  ok "backup -> ${bak/#$HOME/\~}"

  python3 - "$f" <<'PY'
import json, os, sys, tempfile
p = sys.argv[1]
d = json.load(open(p))

def setp(path, val):
    o = d
    parts = path.split(".")
    for k in parts[:-1]:
        o = o.setdefault(k, {})
        if not isinstance(o, dict):
            return (path, "SKIPPED - parent is not an object", val)
    old = o.get(parts[-1], "(not set)")
    o[parts[-1]] = val
    return (path, old, val)

def delp(path):
    o = d
    parts = path.split(".")
    for k in parts[:-1]:
        o = o.get(k, {})
        if not isinstance(o, dict):
            return None
    if parts[-1] in o:
        old = o.pop(parts[-1])
        return (path, old, "(removed)")
    return None

# 2 = block. These have no enterprise policy.
rows = [
    setp("profile.default_content_setting_values.midi_sysex", 2),
    setp("webrtc.multiple_routes_enabled", False),
    setp("webrtc.nonproxied_udp_enabled", False),
]
# Do Not Track is deprecated and adds fingerprinting entropy; GPC replaces it
# (BraveGlobalPrivacyControlEnabled in policies.json).
r = delp("enable_do_not_track")
if r: rows.append(r)

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix=".Preferences.")
with os.fdopen(fd, "w") as fh:
    json.dump(d, fh, separators=(",", ":"))
os.chmod(tmp, os.stat(p).st_mode & 0o777)
os.replace(tmp, p)

print()
for path, old, new in rows:
    flag = "  " if old == new else "->"
    print(f"      {path}\n         {old}  {flag}  {new}")
PY

  echo
  ok "written"
  cat <<'NEXT'

   UI-only (no policy exists for these):
       brave://settings/shields
           Trackers & ads blocking ...... Aggressive
           (policy only forces "block"; Aggressive is a UI level)
       brave://settings/socialBlocking
           all four off

   Then check brave://policy - every row should say OK.
NEXT
}

restore(){
  local f last
  f="$(pref_file)"
  last="$(ls -1t "$f".bak.* 2>/dev/null | head -1 || true)"
  [ -n "$last" ] || { er "no backup found for $PROFILE"; exit 1; }
  check_closed
  cp -a "$last" "$f"
  ok "restored from ${last/#$HOME/\~}"
}

case "${1:---list}" in
  --list)    list_profiles ;;
  --inspect) inspect ;;
  --apply)   apply ;;
  --restore) restore ;;
  *) echo "usage: $0 [--list | --inspect PROFILE | --apply PROFILE | --restore PROFILE]"; exit 1 ;;
esac
