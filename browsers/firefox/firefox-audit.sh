#!/usr/bin/env bash
# firefox-audit.sh
# Collects ONLY modified Firefox preferences + extension list + policy status,
# with anything sensitive stripped out.
#
# It does NOT touch or read: logins.json, key4.db, cookies.sqlite,
# places.sqlite, or any other private data.
#
# Usage:  bash firefox-audit.sh
#         PROFILE=/path/to/profile bash firefox-audit.sh
# Output: ~/firefox-audit.txt   (mode 600 - review before sharing)

set -u
umask 077

OUT="$HOME/firefox-audit.txt"
POLICY_FILE="/etc/firefox/policies/policies.json"

# ---- 1. locate the profile, newest prefs.js wins ----
#   ~/.mozilla/firefox          rpm Firefox, profiles created before Firefox 147
#   ~/.config/mozilla/firefox   rpm Firefox, new profiles (XDG, Firefox 147+)
#   ~/.var/app/...              flatpak
PROFILE="${PROFILE:-}"
if [ -z "$PROFILE" ]; then
    for BASE in "$HOME/.mozilla/firefox" \
                "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox" \
                "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox" \
                "$HOME/.var/app/org.mozilla.firefox/config/mozilla/firefox" \
                "$HOME/snap/firefox/common/.mozilla/firefox"; do
        [ -d "$BASE" ] || continue
        FOUND=$(find "$BASE" -maxdepth 2 -name prefs.js -printf '%T@ %h\n' 2>/dev/null \
                | sort -rn | head -1 | cut -d' ' -f2-)
        if [ -n "$FOUND" ]; then PROFILE="$FOUND"; break; fi
    done
fi

if [ -z "$PROFILE" ] || [ ! -f "$PROFILE/prefs.js" ]; then
    echo "ERROR: no Firefox profile found."
    echo "Open about:profiles in Firefox, copy the 'Root Directory' path, then run:"
    echo "  PROFILE=/that/path bash $0"
    exit 1
fi

echo "Profile found: ${PROFILE/#$HOME/\~}"
echo "Writing report..."

# ---- 2. sensitive patterns to drop from prefs.js ----
DROP='token|password|passwd|secret|apikey|api_key|\.key|encryptionKey'
DROP="$DROP"'|services\.sync|fxaccounts|identity\.|account'
DROP="$DROP"'|userAgentID|clientID|client_id|profileID|uuid|deviceId|user_id'
DROP="$DROP"'|newtabpage\.pinned|activity-stream\.impression'
DROP="$DROP"'|download\.dir|lastDir|lastFileDir|folderList|parent_directory'
DROP="$DROP"'|homepage_override|startup\.homepage'
DROP="$DROP"'|sessionstore|places\.database|storage\.vacuum'
DROP="$DROP"'|kinto|nimbus|remote-settings|blocklist\.ping'
DROP="$DROP"'|telemetry\.previous|telemetry\.cached|lastColdStartup'
DROP="$DROP"'|contextual-services|proxy\.autoconfig|contentblocking\.report'
DROP="$DROP"'|region|geo\.provider\.network\.url|print\.printer_|network\.proxy\.'

# Values that identify this machine even under a harmless key name.
redact(){
    sed -E \
      -e "s|$HOME|~|g" \
      -e 's#(^|["[:space:]])(/var)?/home/[^/"[:space:]]+#\1~#g' \
      -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<uuid>/g' \
      -e 's/\{[0-9a-fA-F-]{36}\}/{<uuid>}/g'
}

{
echo "###############################################"
echo "# Firefox audit  -  $(date '+%Y-%m-%d %H:%M %Z')"
echo "###############################################"
echo
echo "=== PROFILE PATH ==="
echo "$PROFILE" | redact
echo

echo "=== FIREFOX VERSION ==="
firefox --version 2>/dev/null \
  || flatpak run org.mozilla.firefox --version 2>/dev/null \
  || echo "(could not detect)"
echo

echo "=== INSTALL TYPE ==="
if command -v rpm >/dev/null 2>&1 && rpm -q firefox >/dev/null 2>&1; then
    echo "rpm: $(rpm -q firefox)"
    if command -v rpm-ostree >/dev/null 2>&1; then
        if rpm-ostree status --json 2>/dev/null | python3 -c '
import json, sys
d = [x for x in json.load(sys.stdin)["deployments"] if x.get("booted")][0]
sys.exit(0 if any(p.startswith("firefox") for p in d.get("requested-packages", [])) else 1)'; then
            echo "  (layered with rpm-ostree)"
        else
            echo "  (part of the base image)"
        fi
    fi
fi
if command -v flatpak >/dev/null 2>&1; then
    flatpak list --app --columns=application,version 2>/dev/null | grep -i firefox \
      || echo "flatpak: not installed"
fi
echo

echo "=== SYSTEM POLICIES ($POLICY_FILE) ==="
if [ -f "$POLICY_FILE" ]; then
    if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("policies",{})), "policies, valid JSON")' "$POLICY_FILE" 2>/dev/null; then :
    else echo "PRESENT BUT INVALID JSON - Firefox ignores it"; fi
    echo "check about:policies -> 'Active' tab, and 'Errors' tab must be empty"
else
    echo "missing"
fi
echo

echo "=== EXISTING user.js ==="
if [ -f "$PROFILE/user.js" ]; then
    echo "present, $(grep -c '^user_pref' "$PROFILE/user.js" || true) prefs"
else
    echo "none"
fi
echo

echo "=== PRIMARY PASSWORD / SAVED LOGINS ==="
if [ -f "$PROFILE/logins.json" ]; then
    echo "logins.json exists - saved logins present (password manager is disabled by policy)"
else
    echo "no logins.json - no saved passwords"
fi
echo

echo "=== EXTENSIONS ==="
if [ -f "$PROFILE/extensions.json" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$PROFILE/extensions.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("(could not parse extensions.json: %s)" % e); sys.exit()
rows = []
for a in d.get("addons", []):
    if a.get("location") in ("app-system-defaults", "app-builtin", "app-builtin-addons"):
        continue
    if a.get("type") not in ("extension", "theme"):
        continue
    name = (a.get("defaultLocale") or {}).get("name") or a.get("id")
    rows.append("%-34s %-10s %-9s %s" % (
        str(name)[:34], a.get("version", "?"),
        "enabled" if a.get("active") else "disabled", a.get("id", "?")))
print("\n".join(sorted(rows)) if rows else "(none)")
PY
else
    echo "(no extensions.json)"
fi
echo

echo "=== SEARCH ENGINE ==="
SEARCH=$(grep -E '^user_pref\("browser\.(search|urlbar)\.' "$PROFILE/prefs.js" 2>/dev/null \
  | grep -viE "$DROP" | redact)
echo "${SEARCH:-(defaults)}"
echo

echo "=== MODIFIED PREFS (sanitized) ==="
echo "# sensitive lines removed, home paths and UUIDs masked"
echo
grep '^user_pref' "$PROFILE/prefs.js" 2>/dev/null \
  | grep -viE "$DROP" \
  | redact \
  | sort
echo

echo "=== END ==="
} > "$OUT" 2>&1

TOTAL=$(grep -c '^user_pref' "$PROFILE/prefs.js" 2>/dev/null || true)
KEPT=$(grep '^user_pref' "$PROFILE/prefs.js" 2>/dev/null | grep -viEc "$DROP" || true)
TOTAL=${TOTAL:-0}; KEPT=${KEPT:-0}

echo
echo "Done -> ${OUT/#$HOME/\~}"
echo "  prefs in profile : $TOTAL"
echo "  prefs in report  : $KEPT  ($((TOTAL - KEPT)) removed as sensitive)"
echo
echo "Review before sharing:"
echo "  less $OUT"
