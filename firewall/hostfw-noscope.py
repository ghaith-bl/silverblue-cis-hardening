#!/usr/bin/python3 -I
"""hostfw-noscope - keep set noscope_cg of table inet hostfw on GNOME Shell's cgroup.

GNOME Shell's own unit, org.gnome.Shell@<x>.service, is not an app: an app GNOME starts
lands there when its launcher forks before GNOME moves it into its scope (2026-11-03:
Brave rpm). hostfw counts, logs and (in its own enforce mode) rejects new flows from
there (rule out_noscope). nft resolves a cgroup path to its id when the element is
added; a new login is a new cgroup with a new id. So this watcher looks every INTERVAL s
(paths + inode = cgroup id, files only) and rewrites the set in one nft transaction
(flush + add) only when they changed. netfilter: "The cgroupv2 support for nftables was
designed to be used with maps", entries refreshed by a manager as cgroups come and go.

    hostfw-noscope           watch (hostfw-noscope.service)
    hostfw-noscope --once    one sync (hostfw noscope sync)

Needs CAP_NET_ADMIN (nft). Logs one line per change. State for `hostfw noscope status`:
/run/hostfw-noscope/state ("<id> <path>" per line).
"""

import glob
import os
import re
import subprocess
import sys
import time

CG_ROOT = "/sys/fs/cgroup"
PATTERN = "user.slice/user-*.slice/user@*.service/*/org.gnome.Shell@*.service"
LEVEL = 5                          # must match `socket cgroupv2 level 5` in hostfw.nft
SET = "inet hostfw noscope_cg"
STATE = "/run/hostfw-noscope/state"
INTERVAL = 5.0
TIMEOUT = 5.0
MAX_CGROUPS = 16
PART_RE = re.compile(r"[A-Za-z0-9_.:@-]{1,128}")   # no quotes / backslash in nft strings


def log(msg: str) -> None:
    print(f"hostfw-noscope: {msg}", flush=True)


def nft_path() -> str:
    for p in ("/usr/sbin/nft", "/usr/bin/nft"):
        if os.path.isfile(p):
            return p
    return "/usr/sbin/nft"


def current(root: str = CG_ROOT) -> tuple:
    """-> (sorted [(path, id)], skipped paths). Path relative to root."""
    out, skipped = [], []
    for full in sorted(glob.glob(os.path.join(root, PATTERN)))[:MAX_CGROUPS]:
        rel = os.path.relpath(full, root)
        parts = rel.split("/")
        if len(parts) != LEVEL or not all(PART_RE.fullmatch(p) for p in parts):
            skipped.append(rel)
            continue
        try:
            st = os.lstat(full)
        except OSError:
            continue                       # gone meanwhile
        out.append((rel, st.st_ino))
    return out, skipped


def commands(cgs: list) -> str:
    """One transaction: the set holds exactly cgs afterwards (or stays as it was)."""
    text = f"flush set {SET}\n"
    if cgs:
        text += f"add element {SET} {{ " + ", ".join(f'"{p}"' for p, _ in cgs) + " }\n"
    return text


def apply(cgs: list, nft: str, run=subprocess.run) -> str:
    """-> '' or the error."""
    try:
        r = run([nft, "-f", "-"], input=commands(cgs), capture_output=True, text=True,
                timeout=TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"{type(e).__name__}: {e}"
    if r.returncode != 0:
        return (r.stderr.strip().splitlines() or [f"rc {r.returncode}"])[0]
    return ""


def save(cgs: list, path: str = STATE) -> None:
    try:
        os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="ascii") as f:
            f.writelines(f"{i} {p}\n" for p, i in cgs)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except OSError as e:
        log(f"state not saved: {e}")


def describe(cgs: list) -> str:
    if not cgs:
        return "empty (no GNOME Shell session)"
    return f"{len(cgs)} cgroup(s): " + ", ".join(f"{p} (id {i})" for p, i in cgs)


def sync(last, nft: str, root: str = CG_ROOT, run=subprocess.run, state: str = STATE,
         problem: list | None = None):
    """One look. -> the cgroups now in the set (last when unchanged or failed)."""
    cgs, skipped = current(root)
    for rel in skipped:
        if problem is not None and rel not in problem:
            problem.append(rel)
            log(f"skipped {rel}: not level {LEVEL} or odd characters")
    if cgs == last:
        return last
    err = apply(cgs, nft, run)
    if err:
        log(f"set not changed ({err}); again in {INTERVAL:g} s")
        return last
    log(f"set noscope_cg = {describe(cgs)}")
    save(cgs, state)
    return cgs


def main(argv: list) -> int:
    if argv not in ([], ["--once"]):
        print("usage: hostfw-noscope [--once]", file=sys.stderr)
        return 2
    nft = nft_path()
    if argv == ["--once"]:
        return 0 if sync(None, nft, problem=[]) is not None else 1
    log(f"watching {CG_ROOT}/{PATTERN} every {INTERVAL:g} s")
    last, problem = None, []
    try:
        while True:
            last = sync(last, nft, problem=problem)
            time.sleep(INTERVAL)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
