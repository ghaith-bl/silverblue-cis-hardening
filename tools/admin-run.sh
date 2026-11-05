#!/usr/bin/env bash
# tools/admin-run.sh - review, then run, a script handed over by the daily user.
#
# daily user (GNOME):   install -d -m 0755 /tmp/to-admin
#                       install -m 0644 <name>.sh /tmp/to-admin/
# admin (text console): tools/admin-run.sh              list waiting scripts
#                       tools/admin-run.sh <name>.sh    review + run one
#
# - runs as the admin user itself, never as root: the script uses sudo only on
#   the lines that need it, so each root command shows in sudo.log and sectop
# - copies the script into the admin's private dir first, then reviews and runs
#   only that copy: the daily user can't change it after the review
# - confirm by typing the first 8 characters of the sha256 that came with the
#   script (compare it on a second device, not inside the GNOME session)
# - output: ~/admin-inbox/<stamp>-<name>/output.txt, plus a copy the daily user
#   can read in /tmp/from-admin/ (one way, admin -> daily; scripts print no secrets)
# - log: ~/admin-inbox/run.log (time, name, sha256, exit code)
#
# refs: NIST SP 800-53 AC-6(2) (admin account for admin work only), CM-3 (reviewed changes)
set -uo pipefail
umask 077

INBOX=/tmp/to-admin
OUTBOX=/tmp/from-admin
STORE=$HOME/admin-inbox
MAX_BYTES=262144

die() { printf 'admin-run: %s\n' "$*" >&2; exit 2; }

[[ $EUID -ne 0 ]] || die "run as the admin user, not root (no sudo in front)"
[[ -d $INBOX && ! -L $INBOX ]] || die "no $INBOX dir (daily user: install -d -m 0755 $INBOX)"

if [[ $# -eq 0 ]]; then
  printf 'waiting in %s:\n' "$INBOX"
  find "$INBOX" -maxdepth 1 -type f -name '*.sh' \
       -printf '  %TY-%Tm-%Td %TH:%TM  %u  %s B  %f\n' | sort
  exit 0
fi
[[ $# -eq 1 ]] || die "usage: $0 [<name>.sh]"
name=$1
[[ $name =~ ^[A-Za-z0-9._-]+\.sh$ && $name != .* ]] || die "bad name: $name"
src=$INBOX/$name
[[ -f $src && ! -L $src ]] || die "no regular file: $src"

# --- private copy: everything below uses only this copy
stamp=$(date +%Y%m%d-%H%M%S)
work=$STORE/$stamp-${name%.sh}
install -d -m 0700 "$STORE" "$work" || die "can't create $work"
copy=$work/$name
cp -P -- "$src" "$copy" || die "copy failed"
[[ -f $copy && ! -L $copy ]] || die "$name turned into a link while copying: refused"
chmod 0600 "$copy"
size=$(stat -c %s "$copy")
(( size <= MAX_BYTES )) || die "$name is $size bytes (max $MAX_BYTES): refused"

sha=$(sha256sum "$copy" | cut -d' ' -f1)
printf '\n%s\n  from:    %s (owner %s)\n  size:    %s bytes, %s lines\n  sha256:  %s\n\n' \
  "$name" "$src" "$(stat -c %U "$src" 2>/dev/null || echo '?')" "$size" \
  "$(wc -l < "$copy")" "$sha"
bash -n "$copy" || die "syntax error: not run (copy kept: $copy)"
printf 'lines with sudo:\n'
grep -n 'sudo' "$copy" | sed 's/^/  /' || printf '  (none)\n'

printf '\nenter = read the whole script (q leaves the viewer) '
read -r _
less -- "$copy"

printf '\nrun it? type the first 8 characters of the sha256 (anything else = no): '
read -r answer
if [[ $answer != "${sha:0:8}" ]]; then
  printf 'not run. copy kept: %s\n' "$copy"
  printf '%s  %s  %s  not run\n' "$(date -Is)" "$name" "$sha" >> "$STORE/run.log"
  exit 1
fi

# --- run: umask 022 so files made with sudo get normal modes (sudo keeps 077)
out=$work/output.txt
( umask 022; cd "$work" && bash "$copy" ) 2>&1 | tee "$out"
rc=${PIPESTATUS[0]}
printf '%s  %s  %s  exit %s\n' "$(date -Is)" "$name" "$sha" "$rc" >> "$STORE/run.log"

# --- copy of the output for the daily user
if [[ -L $OUTBOX ]] || { [[ -e $OUTBOX ]] && [[ $(stat -c %u "$OUTBOX") != "$EUID" ]]; }; then
  printf 'admin-run: %s is not mine: output only in %s\n' "$OUTBOX" "$out" >&2
else
  install -d -m 0755 "$OUTBOX"
  if pub=$(mktemp "$OUTBOX/${name%.sh}.XXXXXX"); then
    cat "$out" > "$pub" && chmod 0644 "$pub" && printf '\nfor the daily user: %s\n' "$pub"
  fi
fi
printf 'exit %s\n' "$rc"
exit "$rc"
