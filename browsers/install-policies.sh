#!/usr/bin/env bash
#
# install-policies.sh - install the Brave + Firefox enterprise policies
#
#   sudo ./browsers/install-policies.sh           Brave (default)
#   sudo ./browsers/install-policies.sh firefox   Firefox floor policy (optional -
#                                                 my Firefox profiles are set per profile, see user.js)
#   sudo ./browsers/install-policies.sh all       both
#   ./browsers/install-policies.sh --check        read-only status
#   --force   install Brave policy even if installed extensions would be removed
#
# Brave   (flatpak com.brave.Browser) -> /etc/brave/policies/managed/policies.json
#         The Flathub wrapper (brave.sh) links /run/host/etc/brave/policies/managed/*.json
#         into the sandbox at start. Needs the app's default "host-etc" permission,
#         and a REGULAR file - not a symlink.
# Firefox (rpm, Silverblue base image) -> /etc/firefox/policies/policies.json
#
# Existing files are backed up to /var/backups/hardening/<timestamp>/ (same as
# harden-workstation.sh). Restart the browsers afterwards.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAVE_SRC="$HERE/brave/policies.json"
BRAVE_DST="/etc/brave/policies/managed/policies.json"
FF_SRC="$HERE/firefox/policies.json"
FF_DST="/etc/firefox/policies/policies.json"
BRAVE_APP="com.brave.Browser"
BACKUP_DIR="/var/backups/hardening/$(date +%Y%m%d-%H%M%S)"

ok(){ printf '\033[32m  ok \033[0m %s\n' "$*"; }
nn(){ printf '\033[33m  !! \033[0m %s\n' "$*"; }
er(){ printf '\033[31m  xx \033[0m %s\n' "$*" >&2; }
hd(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

valid_json(){ python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; }

brave_host_etc(){
  command -v flatpak >/dev/null 2>&1 || return 2
  flatpak info "$BRAVE_APP" >/dev/null 2>&1 || return 2
  # effective permissions = manifest + system/user overrides
  flatpak info --show-permissions "$BRAVE_APP" 2>/dev/null \
    | grep -E '^filesystems=' | grep -qE '(^|[=;])host-etc(:ro)?(;|$)'
}

install_one(){
  local src="$1" dst="$2"
  valid_json "$src" || { er "$src is not valid JSON - not installed"; return 1; }
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    if cmp -s "$src" "$dst"; then ok "$dst already up to date"; return 0; fi
    mkdir -p "$BACKUP_DIR$(dirname "$dst")"
    cp -a "$dst" "$BACKUP_DIR$dst"
    ok "backup -> $BACKUP_DIR$dst"
    rm -f "$dst"                       # also drops a symlink, if one was there
  fi
  install -D -m 0644 -o root -g root "$src" "$dst"
  command -v restorecon >/dev/null 2>&1 && restorecon -RF "$(dirname "$dst")"
  ok "installed $dst"
}

do_brave(){
  hd "Brave"
  local r=0; brave_host_etc || r=$?
  case $r in
    0) ok "flatpak $BRAVE_APP can read host /etc" ;;
    1) nn "flatpak $BRAVE_APP has NO host-etc access - policies will be ignored"
       echo "       an override removed it; check: flatpak override --show $BRAVE_APP" ;;
    *) nn "flatpak $BRAVE_APP not found - file still installed for a native Brave" ;;
  esac
  brave_extension_guard || return 1
  install_one "$BRAVE_SRC" "$BRAVE_DST"
  echo "   restart Brave, then open brave://policy"
}

# ExtensionInstallBlocklist "*" removes every installed extension that is not
# in ExtensionInstallAllowlist. Refuse to install until each one is listed,
# unless --force is given.
brave_extension_guard(){
  local user="${SUDO_USER:-$(id -un)}" home
  home="$(getent passwd "$user" | cut -d: -f6)"
  local missing
  missing="$(python3 - "$BRAVE_SRC" "$home/.var/app/$BRAVE_APP/config/BraveSoftware/Brave-Browser" \
                     "$home/.config/BraveSoftware/Brave-Browser" <<'PY'
import glob, json, os, sys
pol = json.load(open(sys.argv[1]))
if "*" not in pol.get("ExtensionInstallBlocklist", []):
    sys.exit(0)
allow = set(pol.get("ExtensionInstallAllowlist", []))
seen = {}
for root in sys.argv[2:]:
    for d in glob.glob(os.path.join(root, "*")):
        for f in ("Secure Preferences", "Preferences"):
            try:
                ext = json.load(open(os.path.join(d, f))).get("extensions", {}).get("settings", {})
            except Exception:
                continue
            for eid, e in ext.items():
                # entries without manifest/path are leftovers of removed
                # extensions (only toolbar/ack prefs) - nothing to remove
                if not isinstance(e, dict) or not (e.get("manifest") or e.get("path")):
                    continue
                if e.get("location") not in (5, 10) and eid not in allow:
                    name = (e.get("manifest") or {}).get("name", "?")
                    seen[eid] = "(localized name)" if name.startswith("__MSG_") else name
for eid, name in sorted(seen.items()):
    print(f"{eid}  {name}")
PY
)"
  [ -z "$missing" ] && { ok "every installed extension is in the allowlist"; return 0; }
  nn "these installed extensions would be REMOVED by ExtensionInstallBlocklist \"*\":"
  printf '       %s\n' "$missing" | sed 's/^       $//'
  echo "       add the ones to keep to ExtensionInstallAllowlist in brave/policies.json"
  if [ "$FORCE" = 1 ]; then nn "--force - installing anyway"; return 0; fi
  er "not installing Brave policy (re-run with --force to accept)"
  return 1
}

do_firefox(){
  hd "Firefox"
  if command -v rpm >/dev/null 2>&1 && rpm -q firefox >/dev/null 2>&1; then
    ok "rpm Firefox: $(rpm -q firefox)"
  elif command -v flatpak >/dev/null 2>&1 && flatpak info org.mozilla.firefox >/dev/null 2>&1; then
    nn "only flatpak Firefox found - it does not read host /etc/firefox"
  fi
  install_one "$FF_SRC" "$FF_DST"
  echo "   restart Firefox, then open about:policies (Errors tab must be empty)"
}

check(){
  hd "Status (read-only)"
  for pair in "$BRAVE_SRC:$BRAVE_DST" "$FF_SRC:$FF_DST"; do
    local src="${pair%%:*}" dst="${pair#*:}"
    if [ ! -e "$dst" ];            then nn "$dst missing"
    elif [ -L "$dst" ];            then nn "$dst is a symlink"
    elif ! valid_json "$dst";      then er "$dst invalid JSON"
    elif cmp -s "$src" "$dst";     then ok "$dst matches repo"
    else                                nn "$dst differs from repo copy"; fi
  done
  local r=0; brave_host_etc || r=$?
  case $r in
    0) ok "Brave flatpak has host-etc" ;;
    1) nn "Brave flatpak has NO host-etc" ;;
  esac
}

FORCE=0
ARGS=()
for a in "$@"; do
  if [ "$a" = "--force" ]; then FORCE=1; else ARGS+=("$a"); fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

case "${1:-all}" in
  --check) check; exit 0 ;;
esac

[ "$(id -u)" -eq 0 ] || { er "run with sudo (or use --check)"; exit 1; }
command -v python3 >/dev/null || { er "python3 not found"; exit 1; }

case "${1:-brave}" in
  all)     rc=0; do_brave || rc=1; do_firefox || rc=1; exit $rc ;;
  brave)   do_brave ;;
  firefox) do_firefox ;;
  *) echo "usage: sudo $0 [all|brave|firefox] [--force] | $0 --check"; exit 1 ;;
esac
