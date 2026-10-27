# Browser hardening — Brave + Firefox

System-wide enterprise policies for both browsers, so the settings survive
profile resets and can't be flipped by a site or an extension.

**Design rule:** the system policy is the *floor* — only what must be true in
every profile (telemetry, AI, built-in VPN, device permissions, passwords, HTTPS,
prefetch). Things that differ per profile on purpose (cookie clearing, tracking
level, DoH, fingerprinting extras) are set as unlocked defaults or left to the
profile. Brave has 4 profiles and Firefox 3, each with its own role.

| Browser | Install type | Policy file |
|---|---|---|
| Brave | Flatpak `com.brave.Browser` (Flathub) | `/etc/brave/policies/managed/policies.json` |
| Firefox | RPM, part of the Silverblue base image | per profile: `firefox/user.js` (exported as-is). Optional floor: `/etc/firefox/policies/policies.json` |

`/etc` is writable on Silverblue, so no `rpm-ostree` layering is needed.

## Layout

```
browsers/
├── install-policies.sh          install / check both policy files
├── brave/
│   ├── policies.json            Brave + Chromium policies
│   └── brave-profile-harden.sh  per-profile leftovers that have no policy
└── firefox/
    ├── policies.json            Firefox policies (incl. locked prefs)
    ├── <name>.user.js           one per profile: original, personal, work
    ├── firefox-export-userjs.sh profile -> user.js (settings only, no IDs/paths) + overrides
    ├── firefox-apply-userjs.sh  user.js -> profile (with backup / --restore)
    ├── overrides/               all.js (every profile), personal.js
    └── firefox-audit.sh         sanitized dump of the current profile
browser-settings-report.sh       read-only report of what is in force (both browsers)
```

## Usage

```bash
./browsers/install-policies.sh --check        # read-only
sudo ./browsers/install-policies.sh           # Brave
sudo ./browsers/install-policies.sh firefox   # optional Firefox floor
sudo ./browsers/install-policies.sh all       # both
```

- Existing policy files are backed up to `/var/backups/hardening/<timestamp>/`.
- Restart the browser after installing.

Brave per-profile leftovers (Brave must be closed):

```bash
./browsers/brave/brave-profile-harden.sh --list
./browsers/brave/brave-profile-harden.sh --inspect Default
./browsers/brave/brave-profile-harden.sh --apply   Default
./browsers/brave/brave-profile-harden.sh --restore Default
```

## Profiles

| Browser | Profile | Role | Kept as-is by the policy |
|---|---|---|---|
| Brave | personal | my accounts, trusted sites only | cookies kept (no clear-on-exit), DeepL extension |
| Brave | private | everything else | forget site data when the tab closes, its own Shields settings, reopens last tabs on start (URLs only - site data is still forgotten) |
| Brave | others | unused | get the policy floor only |
| Firefox | original / personal / work | — | not changed: settings live in each profile; one `<name>.user.js` export per profile. personal/work come from the Firefox 136+ profile manager (`Profile Groups/*.sqlite`), not `profiles.ini` |

Firefox user.js — export, merge overrides, install:

```bash
./browsers/firefox/firefox-export-userjs.sh --list
./browsers/firefox/firefox-export-userjs.sh <profile-dir> browsers/firefox/<name>.user.js
./browsers/firefox/firefox-apply-userjs.sh  <profile-dir> browsers/firefox/<name>.user.js   # Firefox closed
```

- The export copies the profile as-is, then merges `overrides/all.js` and
  `overrides/<name>.js` on top (override values win).
- Firefox re-applies `user.js` at every start, so the profile always returns to the repo state.
- Removing a line later does not reset that pref — reset it in `about:config`.

Overrides:

| File | Applies to | What |
|---|---|---|
| `overrides/all.js` | every profile | no remote Safe Browsing lookup for downloads (file name, origin, size, hash → Google). Local list checks stay on |
| `overrides/personal.js` | personal | First Party Isolation → ETP Strict (Total Cookie Protection + network/state partitioning); no "minor issue" exceptions; no ETP web-compat grants |

Why FPI → TCP: FPI is only maintained for Tor Browser, and enabling it turns off
network partitioning and TCP. TCP gives every site its own cookie jar and
partitions cache/storage/network state — same cross-site isolation, maintained,
less breakage. If Firefox later shows the category as **Custom** instead of
**Strict**, TCP is still on (`network.cookie.cookieBehavior = 5`).

### Private profile: Cloudflare challenge loops

Forgetting site data also forgets Cloudflare's `cf_clearance` cookie, so a site
behind a challenge asks again on every visit. Fix per site, not globally:

- Shields panel on that site → **Forget me when I close this site** → off.
  Only that site keeps its cookies; every other site is still forgotten.
- Still looping → same panel, **Block fingerprinting** → off for that site only.
- Reopen tabs on start: `brave://settings/getStarted` → **Continue where you left off**
  (stores the open tab URLs on the encrypted disk; no cookies).

## How the Brave Flatpak reads host policies

- The Flathub manifest grants `--filesystem=host-etc`.
- The wrapper `brave.sh` symlinks `/run/host/etc/brave/policies/{managed,recommended}/*.json`
  into the sandbox's `/etc/brave/policies/` on every start.
- So: the file must be a **regular file** (not a symlink) and no `flatpak override`
  may remove `host-etc`. `install-policies.sh` checks both.

## Verify

| Check | Expected |
|---|---|
| `brave://policy` | every row **OK**, no "Unknown policy" / "Deprecated" |
| `brave://settings/content` | camera, mic, location → Blocked (managed icon) |
| `about:policies` (Firefox) | **Errors** tab empty |
| `about:preferences#privacy` | "Your browser is being managed by your organization" |
| https://browserleaks.com/webrtc | no local / real public IP, only the VPN exit |
| `./browsers/firefox/firefox-audit.sh` | `SYSTEM POLICIES` → valid JSON |

## Decisions

Same intent in both browsers.

| Area | Brave | Firefox | Why |
|---|---|---|---|
| Telemetry | P3A, stats ping, Web Discovery, metrics, surveys off | telemetry, studies, remote improvements off | nothing leaves the browser by itself |
| Built-in extras | Rewards, Wallet, VPN, Leo, local AI, News, Talk, Playlist, Speedreader, Wayback, Tor, email aliases off | all AI controls blocked (incl. translations), built-in VPN off, Suggest/sponsored off | smaller attack surface, fewer background connections |
| Built-in VPN | `BraveVPNDisabled: true` | `IPProtectionAvailable: false` | Brave VPN has no Linux client; Mullvad VPN covers the whole system |
| Camera / mic / location / notifications | blocked by policy | blocked + locked | mic is also disabled at the OS level (WirePlumber) |
| WebRTC | `disable_non_proxied_udp` | default address only, no host candidates | no real-IP leak around the VPN |
| Tracking | Shields forced on: ads/trackers block, fingerprinting standard, HTTPS strict, referrer cap, De-AMP, debounce, query-param strip, GPC, language FP | ETP on (trackers, cryptominers, fingerprinters, email, suspected FP) as **unlocked** default; GPC locked | Brave "Strict" fingerprinting no longer exists. Firefox: one profile runs a custom set (RFP, FPI, cookieBehavior 1) that a forced category would overwrite |
| Cookies | 3rd-party blocked (all profiles); clearing on exit stays per profile | left to the profile (strict / custom) | some profiles keep logins |
| HTTPS | HTTPS-Only forced | HTTPS-Only forced | |
| DNS | DoH **off** | DoH **off** as unlocked default | Mullvad VPN tunnels DNS (its resolver inside the tunnel). A profile that sets its own DoH mode keeps it |
| Passwords / autofill | off | off | external password manager |
| Search | engine left per profile, suggestions off | per profile | both Brave Search and DuckDuckGo are private; nothing is typed-ahead to a server |
| Prefetch / speculative connections | off | off | |
| Safe Browsing | **Standard** (1) + block malicious downloads | **on**, remote download lookups off | see deviations |
| Extensions | all blocked unless allow-listed (DeepL for personal; Proton VPN removed 2026-10-26) | install only from addons.mozilla.org | `install-policies.sh` refuses to install the Brave file while an installed extension is missing from the allowlist (`--force` to accept) |
| DevTools | `0` = allowed, except on policy-installed extensions | default | |

## Deviations from CIS (Chrome / Firefox benchmarks)

- **DoH off** — DNS goes through the VPN tunnel instead.
- **Brave: all extensions blocked** — stricter than CIS. To allow one, add its ID to
  `ExtensionInstallAllowlist` (uBlock Origin Lite: `ddkjiahejlhfcafbddmgiahcphecmpfh`).
- **ETP / DoH in Firefox not locked** — per-profile setups stay as they are (see design rule).
- **Safe Browsing stays on** (the first Brave draft had it off; it was never applied —
  no profile in either browser had it disabled):
  - CIS requires it.
  - Brave proxies every Safe Browsing request through its own server: Google never
    sees my IP, only a short hash prefix after a local match.
  - Firefox checks against a local list; only the *remote download lookup*
    (sends file metadata to Google) is turned off.
  - To go back to off: Brave `SafeBrowsingProtectionLevel: 0` and drop
    `DownloadRestrictions`; Firefox add
    `browser.safebrowsing.malware.enabled` / `browser.safebrowsing.phishing.enabled` = false.

## UI-only (no policy exists)

- `brave://settings/shields` → Trackers & ads blocking → **Aggressive**
  (policy can only force "block").
- `brave://settings/socialBlocking` → all four off.

## Notes

- Brave policy names were checked against `brave-core`
  (`components/policy/resources/templates/policy_definitions/BraveSoftware/`)
  and Chromium's policy definitions. Removed as deprecated / no effect on Linux:
  `ChromeCleanupReportingEnabled`, `SafeBrowsingExtendedReportingEnabled`,
  `PromotionalTabsEnabled` (→ `PromotionsEnabled`), `CloudReportingEnabled`, `ShoppingListEnabled`.
- `AutofillAddressEnabled` / `AutofillCreditCardEnabled` are deprecated from M156;
  `AutofillSettings` (M154+) is set alongside so both old and new builds are covered.
- Do Not Track was removed — deprecated and adds fingerprinting entropy; GPC replaces it.
- JSON has no comments on purpose: unknown keys show up as errors in `brave://policy`.
- Firefox 147+ creates **new** profiles under `~/.config/mozilla/firefox` (XDG);
  existing `~/.mozilla` profiles stay where they are. `firefox-audit.sh` checks both.

## References

- Brave Group Policy — https://support.brave.app/hc/en-us/articles/360039248271-Group-Policy
- Brave Safe Browsing — https://support.brave.app/hc/articles/15222663599629-Safe-Browsing-in-Brave
- Flathub Brave wrapper — https://github.com/flathub/com.brave.Browser (`brave.sh`)
- Chrome Enterprise policy list — https://chromeenterprise.google/policies/
- Firefox policy templates — https://github.com/mozilla/policy-templates
- CIS Google Chrome / Mozilla Firefox Benchmarks — https://www.cisecurity.org/cis-benchmarks
