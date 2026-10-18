#!/usr/bin/env bash
#
# firefox-export-userjs.sh - turn the settings of an existing, already hardened
#                            Firefox profile into a clean user.js for the repo
#
#   ./browsers/firefox/firefox-export-userjs.sh --list
#   ./browsers/firefox/firefox-export-userjs.sh <profile-dir>  [out-file]
#       default out-file: browsers/firefox/user.js
#
# Copies the profile AS IS - nothing is tightened or loosened. Read-only on
# the profile; Firefox may stay open.
#
# What goes into user.js:
#   * prefs under privacy / security / network / telemetry / AI prefixes
#   * only boolean values, small integers, and short lowercase keywords
#     ("blocked", "strict", "custom") - never URLs, paths, domains, IDs
#   * minus Firefox's own bookkeeping (migration flags, timestamps, counters)
# Names of skipped string prefs are printed (names only) so they can be
# checked by hand.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTS=(
  "$HOME/.mozilla/firefox"
  "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox"
  "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
)

list(){
  local found=0 r
  for r in "${ROOTS[@]}"; do
    [ -f "$r/profiles.ini" ] || continue
    found=1
    echo "== ${r/#$HOME/\~}"
    python3 - "$r" <<'PY'
import configparser, os, sys, time
root = sys.argv[1]
ini = configparser.RawConfigParser(); ini.optionxform = str
ini.read(os.path.join(root, "profiles.ini"))
registered = set()
for s in ini.sections():
    if not s.startswith("Profile"): continue
    path = ini.get(s, "Path", fallback="")
    d = path if ini.get(s, "IsRelative", fallback="1") == "0" else os.path.join(root, path)
    p = os.path.join(d, "prefs.js")
    if not os.path.isfile(p): continue
    n = sum(1 for l in open(p, errors="replace") if l.startswith("user_pref("))
    print(f"   {os.path.basename(d):32}  name: {ini.get(s, 'Name', fallback='?'):16}  prefs: {n:4}  "
          f"last used: {time.strftime('%Y-%m-%d', time.localtime(os.path.getmtime(p)))}")
    registered.add(os.path.realpath(d))
import glob, sqlite3
# Firefox 136+ profile manager keeps its profiles in "Profile Groups/*.sqlite",
# not in profiles.ini. Read their names read-only (immutable: no lock, no write).
names = {}
for db in glob.glob(os.path.join(root, "Profile Groups", "*.sqlite")):
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True)
        for path, name in con.execute("SELECT path, name FROM Profiles"):
            names[os.path.basename(str(path).rstrip("/"))] = name
        con.close()
    except Exception:
        pass
others = [d for d in sorted(glob.glob(os.path.join(root, "*", "prefs.js")))
          if os.path.realpath(os.path.dirname(d)) not in registered]
if others:
    print("   -- profiles from the new profile manager (or unregistered folders):")
    for p in others:
        d = os.path.dirname(p)
        n = sum(1 for l in open(p, errors="replace") if l.startswith("user_pref("))
        label = names.get(os.path.basename(d), "(not in any profile list)")
        print(f"   {os.path.basename(d):32}  name: {label[:16]:16}  prefs: {n:4}  "
              f"last used: {time.strftime('%Y-%m-%d', time.localtime(os.path.getmtime(p)))}")
PY
  done
  [ "$found" = 1 ] || echo "no Firefox profiles found"
  echo
  echo "   (profile names are shown on this screen only - they are never written to user.js)"
}

export_js(){
  local name="$1" out="${2:-$HERE/user.js}" dir="" r
  case "$name" in */*|..*) echo "give the profile directory name from --list" >&2; exit 1 ;; esac
  for r in "${ROOTS[@]}"; do
    [ -f "$r/$name/prefs.js" ] && { dir="$r/$name"; break; }
  done
  [ -n "$dir" ] || { echo "profile '$name' not found - see --list" >&2; exit 1; }

  FF_DIR="$HERE" python3 - "$dir" "$out" <<'PY'
import os, re, sys, time
src, out = sys.argv[1], sys.argv[2]

KEEP = re.compile(r"""^(?:
    privacy\. | network\. | media\. | permissions\.default\. | geo\. | dom\. | webgl\.
  | security\.(?:ssl|tls|OCSP|cert_pinning|pki|mixed_content|insecure|csp|family_safety)
  | signon\. | extensions\.(?:formautofill|pocket|getAddons|htmlaboutaddons|postDownloadThirdPartyPrompt|quarantinedDomains\.enabled)
  | browser\.(?:safebrowsing|contentblocking|urlbar\.(?:suggest|speculativeConnect|quicksuggest\.enabled|trimHttps|trending)
             | places\.speculativeConnect | search\.suggest | newtabpage\.activity-stream\.(?:showSponsored|feeds\.|telemetry|default)
             | ml\. | ai\.control | translations\.(?:enable|automaticallyPopup) | discovery | uitour | send_pings | cache\.
             | sessionstore\.privacy_level | formfill | helperApps | download\.(?:always_ask|manager\.addToRecentDocs|start_downloads_in_tmp_dir|useDownloadDir|open_pdf)
             | privatebrowsing | ipProtection\.enabled | shopping\. | topsites\.contile | crashReports | tabs\.crashReporting)
  | datareporting\. | toolkit\.telemetry\. | app\.(?:shield|normandy\.enabled) | breakpad\.
  | beacon\. | javascript\.options\. | pdfjs\.enableScripting | keyword\.enabled | captivedetect\.
  | layout\.css\.visited_links | mathml\. | svg\.disabled | middlemouse\.contentLoadURL
  | accessibility\.force_disabled | gfx\.font_rendering\.opentype_svg | identity\.fxaccounts\.enabled
)""", re.X)

# Firefox bookkeeping - true for this install only, not a setting
STATE = re.compile(r"""(?ix)
    hasMigrated | migrat | lastEpoch | restoreDone | was_ever | ever_enabled | hasSeen
  | hasUserInteracted | \.pending | purge_trackers | date_in | last[A-Z_]?\w*(?:update|check|sync|purge|ping|run|time)
  | CHIPS | cookie\.validation | rustMirror | storage\.rust | impression | count(?:er)?$ | \.version$
  | timestamp | uuid | clientID | \bid$ | _id$ | \.seen | trr\.(?:uri|custom_uri|resolvers|default_provider)
  | cachedClientID | previous | toolkit\.telemetry\.(?:server|reportingpolicy)
  | AcceptedVersion | \.observed$ | has-used | first-seen | databaseSchema
""")

pat = re.compile(r'^user_pref\("([^"]+)",\s*(.+?)\);\s*$', re.M)
prefs = {}
for f in ("prefs.js", "user.js"):
    p = os.path.join(src, f)
    if os.path.isfile(p):
        prefs.update(dict(pat.findall(open(p, errors="replace").read())))

keep, skipped_strings = {}, []
overrides = {}
for k, v in prefs.items():
    if not KEEP.match(k) or STATE.search(k):
        continue
    if v in ("true", "false"):
        keep[k] = v
    elif re.fullmatch(r"-?\d+", v) and abs(int(v)) < 100000:
        keep[k] = v
    elif re.fullmatch(r'"[a-z_-]{0,24}"', v):
        keep[k] = v
    else:
        skipped_strings.append(k)

# overrides/all.js, then overrides/<name>.js (name = out-file stem, e.g. personal)
here = os.path.dirname(os.path.abspath(out))
stem = os.path.basename(out).split(".")[0]
odir = os.path.join(os.environ.get("FF_DIR", here), "overrides")
applied = []
for f in ("all.js", f"{stem}.js"):
    p = os.path.join(odir, f)
    if os.path.isfile(p):
        o = dict(pat.findall(open(p).read()))
        overrides.update(o)
        applied.append(f"overrides/{f} ({len(o)})")
keep.update(overrides)

groups = [
  ("telemetry / studies", r"^(datareporting|toolkit\.telemetry|app\.|breakpad|browser\.(crashReports|tabs\.crashReporting|discovery|ping))"),
  ("AI",                  r"^browser\.(ml|ai)\.|^browser\.translations"),
  ("tracking / fingerprinting", r"^privacy\.|^browser\.contentblocking|^webgl|^beacon|^dom\.event"),
  ("cookies",             r"^network\.cookie"),
  ("WebRTC / media / permissions", r"^media\.|^permissions\.|^geo\."),
  ("HTTPS / TLS",         r"^security\.|^dom\.security"),
  ("network / prefetch / DNS", r"^network\.|^browser\.(urlbar\.speculative|places\.speculative)|^captivedetect"),
  ("search / URL bar / new tab", r"^browser\.(urlbar|search|newtabpage|topsites|shopping)|^keyword"),
  ("passwords / forms",   r"^signon\.|^extensions\.formautofill|^browser\.formfill"),
  ("other",               r"."),
]
done = set()
lines = [
  "// user.js - exported as-is from my hardened Firefox profile",
  f"// generated {time.strftime('%Y-%m-%d')} by browsers/firefox/firefox-export-userjs.sh",
  "// install: copy into a profile folder (about:profiles -> Root Directory), restart Firefox",
  "// only settings - no paths, URLs, domains or IDs",
  "// overrides merged: " + (", ".join(applied) if applied else "none"),
  "",
]
for title, rx in groups:
    ks = sorted(k for k in keep if k not in done and re.search(rx, k))
    if not ks: continue
    lines.append(f"// --- {title}")
    lines += [f'user_pref("{k}", {keep[k]});' for k in ks]
    lines.append("")
    done.update(ks)

with open(out, "w") as fh:
    fh.write("\n".join(lines))
print(f"wrote {len(keep)} prefs -> {out}")
for a in applied: print(f"   merged {a}")
if skipped_strings:
    print(f"\nskipped {len(skipped_strings)} string prefs (value not copied, check by hand if one matters):")
    for k in sorted(skipped_strings):
        print(f"   {k}")
PY
}

case "${1:-}" in
  --list|"") list ;;
  -*) echo "usage: $0 --list | <profile-dir> [out-file]"; exit 1 ;;
  *) export_js "$1" "${2:-}" ;;
esac
