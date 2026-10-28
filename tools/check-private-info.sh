#!/usr/bin/env bash
#
# check-private-info.sh - look for anything in this repo that identifies
#                         me or this machine, before it gets pushed.
#
#   ./tools/check-private-info.sh           working tree + full git history
#   ./tools/check-private-info.sh --tree    working tree only (fast, for a hook)
#
# Nothing personal is written in this file. Machine-specific values
# (user, hostname, real name, IPs, MACs, machine-id, disk UUIDs, Wi-Fi
# names, network interface names, hardware serials) are read live from
# the system at run time.
#
# Exit 0 = clean, 1 = findings, 2 = error. Matches are printed masked.
#
# As a pre-commit hook:
#   ln -s ../../tools/check-private-info.sh .git/hooks/pre-commit
#
# Run from another repo (the script stays here):
#   cd ~/other-repo && ~/path/to/check-private-info.sh --tree
#
# Allow list: .private-info-allow at the root of the scanned repo (optional).
# A finding someone reviewed and accepted, one per line:
#   <label> <path glob> <value regex>
#   ipv4     tests/*     192\.168\.8\.\d{1,3}
# label: as printed (username, local-ip, iface, ipv4, uuid ...), no wildcard.
# path glob: fnmatch, * also crosses /; matched against the file of the hit
#   ("" for commit metadata, so only * matches there).
# value regex: full match on the hit, case-insensitive; may contain spaces.
# The allow file itself is scanned too: there, a hit passes when a rule's
# regex for that label matches it (the file may name what it allows).
# Rules that matched nothing are listed at the end: delete them.
#
set -uo pipefail

MODE="${1:-all}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not inside a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 2; }

# ---------------------------------------------------------------------------
# machine values -> one "label<TAB>value" per line, kept in memory only
# ---------------------------------------------------------------------------
collect(){
  local u; u="$(id -un)"
  printf 'username\t%s\n'       "$u"
  # a generic hostname (netprivacy) identifies nothing and is in many docs: skipped
  { hostname; hostname -s; } 2>/dev/null | sort -u |
    grep -vxE 'localhost(\.localdomain)?|fedora' | sed 's/^/hostname\t/'
  printf 'real-name\t%s\n'      "$(getent passwd "$u" | cut -d: -f5 | cut -d, -f1)"
  git config user.email 2>/dev/null | grep -v noreply | sed 's/^/git-email\t/'
  printf 'home-path\t%s\n'      "$HOME"
  printf 'machine-id\t%s\n'     "$(cat /etc/machine-id 2>/dev/null)"
  ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print "local-ip\t" a[1]}'
  ip -6 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print "local-ip6\t" a[1]}'
  # current + permanent (hardware) MAC: with a random MAC only permaddr is the real one
  { cat /sys/class/net/*/address; ip -o link 2>/dev/null | grep -o 'permaddr [0-9a-f:]*' | cut -d' ' -f2; } 2>/dev/null |
    grep -v '^00:00:00:00:00:00$' | sort -u | sed 's/^/mac\t/'
  # names of real network cards (the ones with a device behind them, not lo / bridges / tunnels)
  for d in /sys/class/net/*/device; do
    [ -e "$d" ] && printf 'iface\t%s\n' "$(basename "$(dirname "$d")")"
  done
  lsblk -rno UUID 2>/dev/null | sort -u | sed 's/^/disk-uuid\t/'
  if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2 ~ /wireless/ {print "wifi-name\t" $1}'
  fi
  for f in /sys/class/dmi/id/{product,board,chassis}_serial; do
    [ -r "$f" ] && printf 'hw-serial\t%s\n' "$(cat "$f" 2>/dev/null)"
  done
}

SELF="tools/check-private-info.sh"
ALLOW=".private-info-allow"

{
  printf '\0#TREE\0'
  git ls-files -z --cached --others --exclude-standard
  if [ "$MODE" != "--tree" ] && git rev-parse HEAD >/dev/null 2>&1; then
    printf '\0#META\0'
    git log --all -z --format='%h%x09<%ae>%x09<%ce>%x09%s %b'
    printf '\0#HIST\0'
    git log --all -p --no-color --unified=0 --format='@@COMMIT %h' -- . ":(exclude)$SELF"
  fi
} | MACHINE="$(collect)" SELF="$SELF" ALLOW="$ALLOW" python3 -c '
import fnmatch, os, re, sys

machine = []
for row in os.environ.get("MACHINE", "").splitlines():
    if "\t" in row:
        k, v = row.split("\t", 1)
        v = v.strip()
        if len(v) >= 3 and v.lower() not in ("root", "user", "admin", "localhost", "fedora"):
            machine.append((k, v))
# real name equal to the username adds nothing but noise
users = {v.lower() for k, v in machine if k == "username"}
machine = [(k, v) for k, v in machine if not (k == "real-name" and v.lower() in users)]

def lit(label, v):
    e = re.escape(v)
    if label == "username":
        # a username can be a common word ("null", "user"...): only match it
        # where it reads as a login: paths, user@host, uid=..., chown, (user)
        return re.compile(
            r"(?:/home/|/var/home/|~)" + e + r"\b"
            r"|\b" + e + r"@"
            r"|\b(?:a|e|o|fs|s)?uid=\"?" + e + r"\b"
            r"|\b(?:acct|user|owner|User|USER)[=:]\s*\"?" + e + r"\b"
            r"|\bchown\s+(?:-\S+\s+)*" + e + r"[:\s]"
            r"|\(" + e + r"\)", re.I)
    return re.compile(r"(?<![\w.-])" + e + r"(?![\w-])", re.I)

checks = [(k, lit(k, v)) for k, v in machine]

generic = [
  ("private-key",    r"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----"),
  ("wireguard-key",  r"PrivateKey\s*=\s*[A-Za-z0-9+/]{42,43}="),
  ("ssh-pubkey",     r"ssh-(?:ed25519|rsa|ecdsa)\S* AAAA[A-Za-z0-9+/]{20,}"),
  ("aws-key",        r"\bAKIA[0-9A-Z]{16}\b"),
  ("github-token",   r"\bgh[pousr]_[A-Za-z0-9]{36,}"),
  ("generic-secret", r"(?i)(?:api[_-]?key|secret|token|passw(?:or)?d)[\"\x27]?\s*[:=]\s*[\"\x27][^\"\x27\s]{8,}"),
  ("email",          r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
  ("ipv4",           r"\b(?:\d{1,3}\.){3}\d{1,3}\b"),
  ("mac-addr",       r"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b"),
  ("uuid",           r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"),
]
generic = [(k, re.compile(r)) for k, r in generic]

# generic hits that are fine in a public hardening repo
ok_value = re.compile(r"""(?ix)
    noreply | @example\. | @localhost | @anthropic\.com
  | ^127\.0\.0\.1$ | ^0\.0\.0\.0$ | ^255\.255\.255\.255$
  | ^(?:192\.0\.2|198\.51\.100|203\.0\.113)\.        # RFC 5737 docs ranges
  | ^(?:00:){5}00$ | ^(?:ff:){5}ff$
  | ^00:00:5e:00:53:[0-9a-f]{2}$                       # RFC 7042 docs MACs
  | ^0{8}-0{4}-0{4}-0{4}-0{12}$                        # nil UUID
""")
# standard blocks, the same on every machine (written with their prefix only):
# RFC 1918 private, RFC 6598 CGNAT, link-local, multicast, libvirt default network.
# Any other address - public resolvers, VPN servers, the router - is a finding.
STANDARD_NETS = {"10.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16", "172.16.0.0/12",
                 "192.168.0.0/16", "224.0.0.0/4", "192.168.122.0/24"}
def ok_ip(m, line):
    parts = m.split(".")
    if any(int(p) > 255 for p in parts):          # not an address (e.g. a version)
        return True
    # version strings like 1.4.4.0 / 0.1.82 next to tool names
    return bool(re.search(r"(?i)version|openscap|ssg|scap-security|kernel|\bfc\d\d\b|release", line))

def mask(s):
    s = s.strip()
    return "****" if len(s) <= 4 else s[:2] + "***" + s[-2:]

# reviewed findings of this repo (format: header of this script)
allow_path = os.environ["ALLOW"]
labels = {k for k, _ in machine} | {k for k, _ in generic} | {
    "username", "hostname", "real-name", "git-email", "home-path", "machine-id", "local-ip",
    "local-ip6", "mac", "iface", "disk-uuid", "wifi-name", "hw-serial"}
rules = []                                          # [label, glob, regex, line no, hits]
if os.path.isfile(allow_path):
    for n, row in enumerate(open(allow_path, encoding="utf-8", errors="replace"), 1):
        row = row.strip()
        if not row or row.startswith("#"): continue
        f = row.split(None, 2)
        if len(f) < 3 or f[0] not in labels:
            print(f"{allow_path}:{n}: want <label> <path glob> <value regex>, label one of: "
                  + " ".join(sorted(labels)), file=sys.stderr)
            sys.exit(2)
        try:
            rules.append([f[0], f[1], re.compile(f[2], re.I), n, 0])
        except re.error as e:
            print(f"{allow_path}:{n}: bad regex: {e}", file=sys.stderr)
            sys.exit(2)

def allowed(label, path, value):
    for r in rules:
        if r[0] != label or not r[2].fullmatch(value.strip()): continue
        if path == allow_path or fnmatch.fnmatchcase(path, r[1]):
            r[4] += 1
            return True
    return False

found = passed = 0
seen = set()
def report(label, path, where, value):
    global found, passed
    key = (label, where, value)
    if key in seen: return
    seen.add(key)
    if allowed(label, path, value):
        passed += 1
        return
    found += 1
    print(f"  \033[31m!!\033[0m {label:15} {where}  ->  {mask(value)}")

def scan(path, where, line):
    for label, rx in checks:
        m = rx.search(line)
        if m: report(label, path, where, m.group(0))
    for label, rx in generic:
        for m in rx.finditer(line):
            v = m.group(0)
            if ok_value.search(v): continue
            if label == "ipv4":
                cidr = re.match(r"/\d{1,2}\b", line[m.end():])
                if cidr and v + cidr.group(0) in STANDARD_NETS: continue
                if ok_ip(v, line): continue
            report(label, path, where, v)

data = sys.stdin.buffer.read().decode("utf-8", "replace")
sections = re.split(r"\x00#(TREE|META|HIST)\x00", data)
blocks = dict(zip(sections[1::2], sections[2::2]))
self_path = os.environ["SELF"]

print("\n\033[1m== Working tree (tracked + untracked, not ignored) ==\033[0m")
for path in filter(None, blocks.get("TREE", "").split("\x00")):
    path = path.strip("\n")
    scan(path, f"path {path}", path)
    if path == self_path or not os.path.isfile(path): continue
    try:
        raw = open(path, "rb").read()
    except OSError:
        continue
    if b"\x00" in raw[:8000]: continue             # binary
    for n, line in enumerate(raw.decode("utf-8", "replace").splitlines(), 1):
        scan(path, f"{path}:{n}", line)

if "META" in blocks:
    print("\n\033[1m== Commit metadata (all branches) ==\033[0m")
    for rec in filter(None, blocks["META"].split("\x00")):
        h = rec.split("\t", 1)[0]
        for line in rec.splitlines():
            scan("", f"commit {h}", line)

if "HIST" in blocks:
    print("\n\033[1m== History (every line ever added) ==\033[0m")
    commit = fname = "?"
    for line in blocks["HIST"].splitlines():
        if line.startswith("@@COMMIT "):  commit = line.split()[1]; continue
        if line.startswith("+++ "):       fname = line[6:] if line.startswith("+++ b/") else line[4:]; continue
        if line.startswith("+"):          scan(fname, f"{commit}:{fname}", line[1:])

print()
if rules:
    print(f"{passed} hit(s) passed by {allow_path} ({len(rules)} rules)")
    for r in rules:
        if not r[4]:
            print(f"  unused rule {allow_path}:{r[3]}: {r[0]} {r[1]} {r[2].pattern}  (delete it?)")
    print()
if not found:
    print("\033[32mclean\033[0m - nothing matched" + (" outside the allow list" if passed else ""))
    sys.exit(0)
print(f"\033[31m{found} finding(s)\033[0m - review each one.")
print("Machine values (username, hostname, mac, ...) are real leaks.")
print("Generic ones (ipv4, uuid, email) can be harmless examples - check them.")
print()
print("Leak only in history: fix the file, then rewrite before the repo goes public")
print("  last commit only : git commit --amend   then   git push --force-with-lease")
print("  older commits    : git filter-repo --replace-text <file>")
sys.exit(1)
'
