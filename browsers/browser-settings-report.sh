#!/usr/bin/env bash
#
# browser-settings-report.sh - read-only report of the privacy/security
#                              settings currently in force in Brave and Firefox
#
#   bash browsers/browser-settings-report.sh
#   -> ~/browser-settings-report.txt   (mode 600, review before sharing)
#
# WHITELIST approach: only known setting keys are printed. Never read or
# printed: history, cookies, logins, bookmarks, site lists, per-site
# exceptions (only their count), sync/account data, wallet, rewards,
# extension storage, profile names, paths under $HOME.
#
# Safe to run while the browsers are open. No sudo needed. Changes nothing.
#
set -uo pipefail
umask 077

OUT="$HOME/browser-settings-report.txt"
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }

BRAVE_ROOTS=(
  "$HOME/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser"
  "${XDG_CONFIG_HOME:-$HOME/.config}/BraveSoftware/Brave-Browser"
)
FF_ROOTS=(
  "$HOME/.mozilla/firefox"
  "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox"
  "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
)

hd(){ printf '\n=== %s ===\n' "$*"; }

show_policy_file(){  # path
  if [ -f "$1" ]; then
    echo "-- $1  ($( [ -L "$1" ] && echo symlink || echo file ))"
    python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2, sort_keys=True))' "$1" 2>/dev/null \
      || echo "   INVALID JSON - the browser ignores this file"
  fi
}

{
echo "# Browser settings report - $(date '+%Y-%m-%d %H:%M')"
echo "# whitelisted keys only; no personal data"

# ===========================================================================
hd "BRAVE - install"
if command -v flatpak >/dev/null 2>&1 && flatpak info com.brave.Browser >/dev/null 2>&1; then
  echo "flatpak: $(flatpak info com.brave.Browser 2>/dev/null | awk -F': ' '/Version:/{print $2; exit}')"
  echo "-- effective filesystem permissions:"
  flatpak info --show-permissions com.brave.Browser 2>/dev/null | grep -E '^filesystems=' | tr ';' '\n' | sed 's/^/   /'
  echo "-- user/system overrides:"
  { flatpak override --user   --show com.brave.Browser 2>/dev/null
    flatpak override --system --show com.brave.Browser 2>/dev/null; } | sed 's/^/   /' | grep . || echo "   (none)"
else
  command -v brave-browser >/dev/null 2>&1 && echo "native: $(brave-browser --version 2>/dev/null)" || echo "(brave not found)"
fi

hd "BRAVE - system policies"
found=0
for d in /etc/brave/policies/managed /etc/brave/policies/recommended; do
  for f in "$d"/*.json; do [ -e "$f" ] || continue; found=1; show_policy_file "$f"; done
done
[ "$found" = 1 ] || echo "(no policy files in /etc/brave/policies)"

hd "BRAVE - profiles"
for root in "${BRAVE_ROOTS[@]}"; do
  [ -d "$root" ] || continue
  python3 - "$root" <<'PY'
import json, os, sys, glob

root = sys.argv[1]
print("location:", "flatpak" if "/.var/app/" in root else "native")

def load(p):
    try:
        with open(p) as fh: return json.load(fh)
    except Exception: return {}

def get(d, path, default="(not set)"):
    for k in path.split("."):
        if not isinstance(d, dict) or k not in d: return default
        d = d[k]
    return d

KEYS = [
  "profile.cookie_controls_mode", "profile.block_third_party_cookies",
  "profile.password_manager_enabled", "credentials_enable_service", "credentials_enable_autosignin",
  "autofill.profile_enabled", "autofill.credit_card_enabled", "payments.can_make_payment_enabled",
  "search.suggest_enabled", "alternate_error_pages.enabled", "net.network_prediction_options",
  "safebrowsing.enabled", "safebrowsing.enhanced", "safebrowsing.scout_reporting_enabled",
  "translate.enabled", "spellcheck.use_spelling_service", "dns_over_https.mode",
  "webrtc.ip_handling_policy", "webrtc.multiple_routes_enabled", "webrtc.nonproxied_udp_enabled",
  "enable_do_not_track", "https_only_mode_enabled", "printing.enabled",
  "brave.de_amp.enabled", "brave.debounce.enabled", "brave.reduce_language",
  "brave.gpc.enabled", "brave.shields.stats_badge_visible",
  "brave.webtorrent_enabled", "brave.ai_chat.enabled", "brave.brave_vpn.show_button",
  "brave.p3a.enabled", "brave.stats.reporting_enabled", "brave.web_discovery_enabled",
  "brave.new_tab_page.show_rewards", "brave.new_tab_page.show_brave_news",
  "brave.today.should_show_toolbar_button",
]

dirs = sorted(d for d in glob.glob(os.path.join(root, "*")) if os.path.isfile(os.path.join(d, "Preferences")))
for n, d in enumerate(dirs, 1):
    pref = load(os.path.join(d, "Preferences"))
    sec  = load(os.path.join(d, "Secure Preferences"))
    label = "Default" if os.path.basename(d) == "Default" else f"profile-{n}"
    print(f"\n-- {label}")

    print("   standard keys:")
    for k in KEYS:
        v = get(pref, k)
        if v == "(not set)": v = get(sec, k)
        print(f"      {k} = {json.dumps(v) if not isinstance(v, str) else v}")

    print("   content setting defaults (2 = block, 1 = allow, 3 = ask):")
    for k, v in sorted(get(pref, "profile.default_content_setting_values", {}).items()):
        if isinstance(v, (int, bool)): print(f"      {k} = {v}")

    # Brave Shields globals are stored as the "*,*" exception; every other
    # exception is a real site -> counted, never printed.
    print("   global Shields / content defaults (pattern *,*):")
    exc = get(pref, "profile.content_settings.exceptions", {})
    site_count = 0
    for typ, rules in sorted(exc.items()):
        if not isinstance(rules, dict): continue
        for pattern, rule in rules.items():
            if pattern in ("*,*", "*,", ","):
                val = rule.get("setting") if isinstance(rule, dict) else rule
                if isinstance(val, (int, bool, str)) and len(str(val)) < 20:
                    print(f"      {typ} = {val}")
            else:
                site_count += 1
    print(f"   per-site exceptions: {site_count} (not shown)")

    print("   extensions (id / name / enabled):")
    ext = get(sec, "extensions.settings", {}) or get(pref, "extensions.settings", {})
    rows = []
    for eid, e in (ext or {}).items():
        if not isinstance(e, dict): continue
        if e.get("location") in (5, 10):        # component / external component
            continue
        name = (e.get("manifest") or {}).get("name", "?")
        if name.startswith("__MSG_"): name = "(localized name)"
        state = "disabled" if e.get("disable_reasons") else "enabled"
        rows.append(f"      {eid}  {name[:40]}  {state}")
    print("\n".join(sorted(rows)) if rows else "      (none)")
PY
done

# ===========================================================================
hd "FIREFOX - install"
if command -v rpm >/dev/null 2>&1 && rpm -q firefox >/dev/null 2>&1; then echo "rpm: $(rpm -q firefox)"; fi
command -v flatpak >/dev/null 2>&1 && flatpak info org.mozilla.firefox >/dev/null 2>&1 && echo "flatpak: present"

hd "FIREFOX - system policies"
found=0
for f in /etc/firefox/policies/policies.json /usr/lib64/firefox/distribution/policies.json /usr/lib/firefox/distribution/policies.json; do
  [ -e "$f" ] && { found=1; show_policy_file "$f"; }
done
[ "$found" = 1 ] || echo "(no policies.json found)"

hd "FIREFOX - profiles"
for root in "${FF_ROOTS[@]}"; do
  [ -d "$root" ] || continue
  python3 - "$root" <<'PY'
import glob, json, os, re, sys

root = sys.argv[1]
print("location:", {True: "flatpak"}.get("/.var/app/" in root, "xdg" if "/.config/" in root else "~/.mozilla"))

# whitelisted pref prefixes - nothing else is printed
ALLOW = re.compile(r"""^(
    privacy\. | network\.cookie\. | network\.trr\.mode$ | network\.prefetch-next$
  | network\.dns\.disablePrefetch | network\.http\.speculative | network\.predictor\.
  | network\.http\.referer\. | network\.IDN_show_punycode$ | network\.connectivity-service\.enabled$
  | network\.captive-portal-service\.enabled$
  | media\.peerconnection\. | media\.navigator\.enabled$ | media\.eme\.enabled$ | media\.autoplay\.
  | permissions\.default\. | geo\.enabled$
  | browser\.safebrowsing\.(?!provider\.\w+\.(updateURL|gethashURL|lastupdatetime|nextupdatetime))
  | dom\.security\.https_only | dom\.event\.clipboardevents | beacon\.enabled$
  | datareporting\.(healthreport|policy)\.(uploadEnabled|dataSubmissionEnabled)$
  | toolkit\.telemetry\.(enabled|unified|archive\.enabled|server)$ | app\.shield\.optoutstudies\.enabled$
  | app\.normandy\.enabled$ | browser\.discovery\.enabled$
  | browser\.contentblocking\.category$ | browser\.urlbar\.suggest\. | browser\.urlbar\.quicksuggest\.
  | browser\.urlbar\.speculativeConnect | browser\.places\.speculativeConnect
  | browser\.search\.suggest\.enabled | browser\.newtabpage\.activity-stream\.(showSponsored|feeds\.(topsites|section\.topstories|snippets))
  | browser\.ml\. | browser\.ai\. | browser\.ipProtection\. | browser\.translations\.enable$
  | signon\. | extensions\.formautofill\. | extensions\.pocket\.enabled$ | identity\.fxaccounts\.enabled$
  | security\.(tls|ssl|OCSP|pki|mixed_content|cert_pinning)\.
  | webgl\.disabled$ | pdfjs\.enableScripting$ | javascript\.options\.(baselinejit|ion|wasm)$
)""", re.X)
# even inside allowed prefixes, drop anything that can hold an ID, a URL or a path
DENY = re.compile(r"(id|uuid|token|url|uri|path|dir|host|region|lastupdate|time|date|count|version)$|\.(lastupdate|nextupdate)", re.I)

def prefs(path):
    out = {}
    try:
        for m in re.finditer(r'^user_pref\("([^"]+)",\s*(.+?)\);\s*$', open(path, errors="replace").read(), re.M):
            out[m.group(1)] = m.group(2)
    except OSError:
        pass
    return out

dirs = sorted({os.path.dirname(p) for p in glob.glob(os.path.join(root, "*", "prefs.js"))},
              key=lambda d: os.path.getmtime(os.path.join(d, "prefs.js")), reverse=True)
for n, d in enumerate(dirs, 1):
    print(f"\n-- profile-{n}{'  (most recently used)' if n == 1 else ''}")
    for fname, label in (("prefs.js", "active prefs"), ("user.js", "user.js")):
        p = prefs(os.path.join(d, fname))
        if fname == "user.js" and not os.path.exists(os.path.join(d, fname)):
            print("   user.js: none"); continue
        rows = [(k, v) for k, v in sorted(p.items()) if ALLOW.match(k) and not DENY.search(k)]
        rows = [(k, v) for k, v in rows if not v.startswith('"') or len(v) <= 40 and "/" not in v and "@" not in v]
        print(f"   {label}: {len(rows)} shown of {len(p)}")
        for k, v in rows:
            print(f"      {k} = {v}")

    print("   extensions (name / id / enabled):")
    try:
        data = json.load(open(os.path.join(d, "extensions.json")))
        rows = []
        for a in data.get("addons", []):
            if a.get("location") in ("app-system-defaults", "app-builtin", "app-builtin-addons"): continue
            if a.get("type") not in ("extension",): continue
            name = (a.get("defaultLocale") or {}).get("name") or "?"
            rows.append(f"      {name[:34]:34} {a.get('id','?')[:50]:50} {'enabled' if a.get('active') else 'disabled'}")
        print("\n".join(sorted(rows)) if rows else "      (none)")
    except Exception:
        print("      (no extensions.json)")
PY
done

echo
echo "=== END ==="
} > "$OUT" 2>&1

# last safety net: mask home paths / username / hostname if anything slipped through
python3 - "$OUT" <<'PY'
import os, re, socket, sys, getpass
p = sys.argv[1]; s = open(p).read()
home = os.path.expanduser("~")
for v in filter(None, {home, os.path.realpath(home)}):
    s = s.replace(v, "~")
for v in filter(lambda x: x and len(x) >= 3, {socket.gethostname(), socket.gethostname().split(".")[0]}):
    s = re.sub(r"(?<![\w.-])" + re.escape(v) + r"(?![\w-])", "<host>", s, flags=re.I)
u = getpass.getuser()
s = re.sub(r"(/home/|/var/home/)" + re.escape(u) + r"\b", r"~", s)
s = re.sub(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", "<uuid>", s, flags=re.I)
open(p, "w").write(s)
PY

echo "Done -> ~/browser-settings-report.txt  ($(wc -l < "$OUT") lines)"
echo "Review it first:  less ~/browser-settings-report.txt"
