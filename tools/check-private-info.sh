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
# names, hardware serials) are read live from the system at run time.
#
# Exit 0 = clean, 1 = findings, 2 = error. Matches are printed masked.
#
# As a pre-commit hook:
#   ln -s ../../tools/check-private-info.sh .git/hooks/pre-commit
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
  lsblk -rno UUID 2>/dev/null | sort -u | sed 's/^/disk-uuid\t/'
  if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2 ~ /wireless/ {print "wifi-name\t" $1}'
  fi
  for f in /sys/class/dmi/id/{product,board,chassis}_serial; do
    [ -r "$f" ] && printf 'hw-serial\t%s\n' "$(cat "$f" 2>/dev/null)"
  done
}

SELF="tools/check-private-info.sh"

{
  printf '\0#TREE\0'
  git ls-files -z --cached --others --exclude-standard
  if [ "$MODE" != "--tree" ] && git rev-parse HEAD >/dev/null 2>&1; then
    printf '\0#META\0'
    git log --all -z --format='%h%x09<%ae>%x09<%ce>%x09%s %b'
    printf '\0#HIST\0'
    git log --all -p --no-color --unified=0 --format='@@COMMIT %h' -- . ":(exclude)$SELF"
  fi
} | MACHINE="$(collect)" SELF="$SELF" python3 -c '
import os, re, sys

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

found = 0
seen = set()
def report(label, where, value):
    global found
    key = (label, where, value)
    if key in seen: return
    seen.add(key); found += 1
    print(f"  \033[31m!!\033[0m {label:15} {where}  ->  {mask(value)}")

def scan(where, line):
    for label, rx in checks:
        m = rx.search(line)
        if m: report(label, where, m.group(0))
    for label, rx in generic:
        for m in rx.finditer(line):
            v = m.group(0)
            if ok_value.search(v): continue
            if label == "ipv4":
                cidr = re.match(r"/\d{1,2}\b", line[m.end():])
                if cidr and v + cidr.group(0) in STANDARD_NETS: continue
                if ok_ip(v, line): continue
            report(label, where, v)

data = sys.stdin.buffer.read().decode("utf-8", "replace")
sections = re.split(r"\x00#(TREE|META|HIST)\x00", data)
blocks = dict(zip(sections[1::2], sections[2::2]))
self_path = os.environ["SELF"]

print("\n\033[1m== Working tree (tracked + untracked, not ignored) ==\033[0m")
for path in filter(None, blocks.get("TREE", "").split("\x00")):
    path = path.strip("\n")
    scan(f"path {path}", path)
    if path == self_path or not os.path.isfile(path): continue
    try:
        raw = open(path, "rb").read()
    except OSError:
        continue
    if b"\x00" in raw[:8000]: continue             # binary
    for n, line in enumerate(raw.decode("utf-8", "replace").splitlines(), 1):
        scan(f"{path}:{n}", line)

if "META" in blocks:
    print("\n\033[1m== Commit metadata (all branches) ==\033[0m")
    for rec in filter(None, blocks["META"].split("\x00")):
        h = rec.split("\t", 1)[0]
        for line in rec.splitlines():
            scan(f"commit {h}", line)

if "HIST" in blocks:
    print("\n\033[1m== History (every line ever added) ==\033[0m")
    commit = fname = "?"
    for line in blocks["HIST"].splitlines():
        if line.startswith("@@COMMIT "):  commit = line.split()[1]; continue
        if line.startswith("+++ "):       fname = line[6:] if line.startswith("+++ b/") else line[4:]; continue
        if line.startswith("+"):          scan(f"{commit}:{fname}", line[1:])

print()
if not found:
    print("\033[32mclean\033[0m - nothing matched")
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
