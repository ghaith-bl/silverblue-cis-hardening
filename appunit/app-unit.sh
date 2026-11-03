#!/usr/bin/env bash
#
# app-unit - start a desktop app as its own systemd user service.
#
#   app-unit <desktop id> <command> [args...]
#
# Installed by harden-workstation.sh (appunit section) to /usr/local/bin, root owned;
# the desktop files it writes to /usr/local/share/applications call it.
#
# Why: GNOME starts an app, then moves its pid into app-gnome-<id>-<pid>.scope. A
# launcher that forks at once (Brave: brave-browser-stable -> brave -> zygote) is
# faster: its children stay in org.gnome.Shell@user.service and every tool that names
# programs by cgroup (sectop, systemd-cgls) shows them as GNOME Shell.
# Here systemd starts the app in a new service: every process is in it from the first
# instruction, and GNOME's late move only catches this short-lived wrapper.
# Unit: app-<id>@<pid>.service, id escaped (systemd-escape), the form systemd.io
# DESKTOP_ENVIRONMENTS describes. ExitType=cgroup: the service lives until the last
# process of the app ends, not when the launcher script exits.
set -euo pipefail

die() { printf 'app-unit: %s\n' "$*" >&2; exit 2; }

(( $# >= 2 )) || die "usage: app-unit <desktop id> <command> [args...]"
[[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "bad desktop id: $1"
id=$(systemd-escape -- "$1")
shift

args=(--user --quiet --collect --slice=app.slice -p ExitType=cgroup
      --unit="app-${id}@$$.service")
# focus / startup notice for the new window (GNOME sets one of them)
for v in XDG_ACTIVATION_TOKEN DESKTOP_STARTUP_ID; do
  if [[ -n ${!v:-} ]]; then args+=(-E "$v=${!v}"); fi
done
exec systemd-run "${args[@]}" -- "$@"
