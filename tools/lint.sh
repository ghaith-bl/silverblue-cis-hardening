#!/usr/bin/env bash
#
# lint.sh - the CI's lint checks on this machine, before a push: ASCII only, bash -n,
#           python syntax, shellcheck (warnings), private info (generic patterns).
#           This repo's CI runs this file; sectop's CI runs the same checks for its files.
#
#   tools/lint.sh                 check this repo
#   tools/lint.sh <sectop repo>   check sectop (its file list: install.sh, ASCII dirs)
#   tools/lint.sh --setup         create the toolbox "lint" with ShellCheck in it (once)
#
# The ShellCheck binary: the host's when installed, else the one in the toolbox "lint" (Silverblue:
# nothing layered, the host stays as it is; a toolbox shares the home, same paths).
# --setup, as the daily user: Fedora's toolbox image (when not there yet) and the
# ShellCheck package from Fedora's mirrors (through the tunnel, like updates).
# Exit 0 = every check passed, 1 = a check failed, 2 = usage, or only ShellCheck missing.
#
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BOX=lint
FAIL=0
NOSC=0

pass() { printf 'lint: %-12s ok\n' "$1"; }
bad()  { printf 'lint: %-12s FAIL\n' "$1"; FAIL=1; }
die()  { printf 'lint: %s\n' "$*" >&2; exit 2; }

has_box() { command -v podman >/dev/null && podman container exists "$BOX" 2>/dev/null; }

have_sc() { command -v shellcheck >/dev/null || { command -v toolbox >/dev/null && has_box; }; }

# ShellCheck from the host or the toolbox; none: SKIP (the CI still runs it)
sc() {
  if command -v shellcheck >/dev/null; then
    shellcheck "$@"
  elif command -v toolbox >/dev/null && has_box; then
    toolbox run -c "$BOX" shellcheck "$@"
  else
    printf 'lint: %-12s SKIP (none here: tools/lint.sh --setup)\n' shellcheck
    NOSC=1
    return 0
  fi
}

setup() {
  command -v toolbox >/dev/null || die "no toolbox command"
  [[ $EUID -ne 0 ]] || die "--setup as the daily user, not root"
  if ! has_box; then
    toolbox create -y "$BOX" || die "toolbox create $BOX failed"
  fi
  toolbox run -c "$BOX" sh -c 'command -v shellcheck >/dev/null || sudo dnf -y -q install ShellCheck' ||
    die "ShellCheck not installed in toolbox $BOX"
  toolbox run -c "$BOX" shellcheck --version | head -n 2
  printf 'lint: toolbox %s ready (update: toolbox run -c %s sudo dnf -y upgrade)\n' "$BOX" "$BOX"
}

ascii() {   # $@: paths
  if grep -rnIP '[^\x00-\x7F]' --exclude-dir=.git "$@"; then bad ascii; else pass ascii; fi
}

private() {
  if PRIVATE_INFO_GENERIC=1 "$HERE/tools/check-private-info.sh" --tree; then pass "private"; else bad "private"; fi
}

hardening() {
  local f rc=0
  local -a sh=(harden-workstation.sh tools/*.sh usbguard/*.sh appunit/*.sh firewall/*.sh browsers/*.sh
               browsers/brave/*.sh browsers/firefox/*.sh browsevm/*.sh)
  ascii .
  for f in "${sh[@]}"; do bash -n "$f" || rc=1; done
  for f in firewall/nm-dispatcher/90-hostfw-sync netprivacy/nm-dispatcher/50-netprivacy; do sh -n "$f" || rc=1; done
  # the kickstart's %post runs in the installer: a syntax error there spoils a 10 min build
  sed -n '/^%post/,/^%end/p' browsevm/browsevm.ks | sed '1d;$d' | bash -n || rc=1
  if ((rc)); then bad "bash -n"; else pass "bash -n"; fi
  if python3 -I -c 'import ast, sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' \
       firewall/hostfw-noscope.py browsevm/browsevm-wlrelay.py tests/*.py; then pass python; else bad python; fi
  if ! have_sc; then sc
  elif sc -S warning "${sh[@]}" firewall/nm-dispatcher/90-hostfw-sync netprivacy/nm-dispatcher/50-netprivacy; then pass shellcheck
  else bad shellcheck; fi
  private
}

sectop() {
  ascii core tests docs modules README.md bin deploy install.sh
  if bash -n install.sh; then pass "bash -n"; else bad "bash -n"; fi
  if ! have_sc; then sc
  elif sc -S warning install.sh; then pass shellcheck
  else bad shellcheck; fi
  private
}

case ${1:-} in
  --setup) setup; exit 0 ;;
  -h|--help) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") cd "$HERE" || die "no $HERE"; hardening ;;
  *)  [[ -d $1 ]] || die "no directory $1"
      cd "$1" || die "cannot enter $1"
      if [[ -f harden-workstation.sh ]]; then hardening
      elif [[ -f install.sh && -d core && -d modules ]]; then sectop
      else die "$1: neither this repo nor sectop"; fi ;;
esac
if ((FAIL)); then exit 1; fi
if ((NOSC)); then exit 2; fi
exit 0
