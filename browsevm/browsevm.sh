#!/usr/bin/env bash
#
# browsevm.sh - throwaway browsing VM (docs/browsevm.md)
#
#   sudo browsevm/browsevm.sh build [--force]   unattended install of the base image
#
# build: Fedora minimal + cage + Firefox from browsevm.ks, network "browse" (section
# browsevm), Firefox floor policy = browsers/firefox/policies.json + uBlock Origin
# (Fedora package, force-installed) + Mullvad Browser Extension (signed xpi from
# addons.mozilla.org, fetched at build, force-installed from the image) + no first-run
# pages. The base image is never
# booted for browsing: the VM (step 3) runs on a transient overlay.
# Output: the install's serial console in /var/log/browsevm/, its BROWSEVM: lines shown.
#
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$HERE")
FEDORA="${BROWSEVM_FEDORA:-45}"
BASE=/var/lib/libvirt/images/browsevm-base.qcow2
BUILD=browsevm-build
NET=browse
LOGDIR=/var/log/browsevm
MULLVAD_XPI_URL="https://addons.mozilla.org/firefox/downloads/latest/mullvad-vpn/latest.xpi"
MULLVAD_XPI_IN_VM=/usr/share/browsevm/mullvad-browser-extension.xpi
V=(virsh -q -c qemu:///system)
TMPD=""
trap '[[ -n $TMPD ]] && rm -rf "$TMPD"' EXIT

ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

cmd_build() {
  local force=0 url tmp log started_net=0 state c inject_xpi
  [[ ${1:-} == --force ]] && force=1
  [[ $EUID -eq 0 ]] || die "run with sudo"
  [[ $FEDORA =~ ^[0-9]{2}$ ]] || die "BROWSEVM_FEDORA must be a release number (e.g. 45)"
  for c in virt-install virsh python3 curl; do
    command -v "$c" >/dev/null || die "$c missing"
  done
  "${V[@]}" net-info "$NET" >/dev/null 2>&1 || die "network $NET missing: sudo ./harden-workstation.sh browsevm"
  if "${V[@]}" dominfo "$BUILD" >/dev/null 2>&1; then
    die "a $BUILD domain exists (old run?): sudo virsh destroy $BUILD; sudo virsh undefine $BUILD"
  fi
  if [[ -e $BASE ]]; then
    ((force)) || die "$BASE exists (--force moves it to $BASE.old)"
    mv -f "$BASE" "$BASE.old"
    warn "old base moved to $BASE.old"
  fi

  url="https://download.fedoraproject.org/pub/fedora/linux/releases/$FEDORA/Everything/x86_64/os/"
  curl -fsSL --max-time 30 -o /dev/null "$url.treeinfo" || die "Fedora $FEDORA install tree not reachable: $url"
  ok "install tree: Fedora $FEDORA"

  tmp=$(mktemp -d)
  TMPD=$tmp
  sed "s/@FEDORA@/$FEDORA/g" "$HERE/browsevm.ks" > "$tmp/browsevm.ks"

  # Mullvad Browser Extension: Mozilla-signed xpi from AMO (Firefox checks the signature
  # at install); its add-on ID comes from the xpi's own manifest
  if curl -fsSL --max-time 60 -o "$tmp/mullvad-browser-extension.xpi" "$MULLVAD_XPI_URL"; then
    ok "Mullvad Browser Extension downloaded ($(sha256sum "$tmp/mullvad-browser-extension.xpi" | cut -c1-16)...)"
  else
    warn "Mullvad Browser Extension not downloaded - the base image is built without it"
    rm -f "$tmp/mullvad-browser-extension.xpi"
  fi
  python3 -I - "$REPO/browsers/firefox/policies.json" "$tmp/browsevm-policies.json" \
      "$tmp/mullvad-browser-extension.xpi" "$MULLVAD_XPI_IN_VM" <<'PY'
import json, os, sys, zipfile
src, dst, xpi, xpi_vm = sys.argv[1:5]
d = json.load(open(src))
p = d["policies"]
ext = p.setdefault("ExtensionSettings", {})
ext["uBlock0@raymondhill.net"] = {"installation_mode": "force_installed",
                                  "install_url": "file://@UBLOCK_XPI@"}
if os.path.exists(xpi):
    try:
        m = json.loads(zipfile.ZipFile(xpi).read("manifest.json"))
        gecko = (m.get("browser_specific_settings") or m.get("applications") or {}).get("gecko", {})
        aid = gecko["id"]
        ext[aid] = {"installation_mode": "force_installed", "install_url": "file://" + xpi_vm}
        print(f"[+] Mullvad Browser Extension {m.get('version', '?')} id {aid}")
    except (KeyError, ValueError, zipfile.BadZipFile) as e:
        print(f"[!] Mullvad Browser Extension: no add-on ID in the xpi ({e}) - left out")
        os.remove(xpi)
p["OverrideFirstRunPage"] = ""
p["OverridePostUpdatePage"] = ""
p["DisableProfileImport"] = True
json.dump(d, open(dst, "w"), indent=2)
PY
  ok "Firefox policy written (repo floor + extensions above + no first-run pages)"

  if [[ $("${V[@]}" net-info "$NET" | sed -n 's/^Active: *//p') != yes ]]; then
    "${V[@]}" net-start "$NET" >/dev/null && started_net=1 && ok "network $NET started for the install"
  fi
  inject_xpi=()
  [[ -f $tmp/mullvad-browser-extension.xpi ]] &&
    inject_xpi=(--initrd-inject "$tmp/mullvad-browser-extension.xpi")
  install -d -m 0750 "$LOGDIR"
  log="$LOGDIR/build-$(date +%Y%m%d-%H%M%S).log"

  ok "installing (unattended, 15-40 min, packages through Mullvad) - serial log: $log"
  if ! virt-install --connect qemu:///system --name "$BUILD" \
      --osinfo detect=on,require=off \
      --memory 4096 --vcpus 2 \
      --disk "path=$BASE,size=12,format=qcow2,bus=virtio" \
      --network "network=$NET,model=virtio" \
      --location "$url" \
      --initrd-inject "$tmp/browsevm.ks" --initrd-inject "$tmp/browsevm-policies.json" \
      "${inject_xpi[@]}" \
      --extra-args "inst.ks=file:/browsevm.ks inst.text console=ttyS0" \
      --graphics none --serial "file,path=$log" \
      --noautoconsole --noreboot --wait 120 >/dev/null; then
    warn "virt-install failed or timed out - last lines of $log:"
    tail -n 25 "$log" 2>/dev/null || true
    "${V[@]}" destroy "$BUILD" >/dev/null 2>&1 || true
    "${V[@]}" undefine "$BUILD" >/dev/null 2>&1 || true
    ((started_net)) && "${V[@]}" net-destroy "$NET" >/dev/null 2>&1
    die "build failed (disk left at $BASE for a look; rerun with --force)"
  fi

  state=$("${V[@]}" domstate "$BUILD" 2>/dev/null || echo gone)
  [[ $state == "shut off" ]] || warn "domain state after install: $state"
  "${V[@]}" undefine "$BUILD" >/dev/null && ok "build domain removed (disk kept)"
  ((started_net)) && "${V[@]}" net-destroy "$NET" >/dev/null && ok "network $NET stopped again"
  chown root:root "$BASE"
  chmod 0600 "$BASE"

  echo
  echo "-- checks from the install (serial console)"
  grep -a 'BROWSEVM:' "$log" | tr -d '\r' || warn "no BROWSEVM: lines in $log"
  if grep -aq 'BROWSEVM: post done' "$log"; then
    ok "base image: $BASE ($(du -h "$BASE" | cut -f1))"
  else
    warn "post-install did not finish - read $log"
  fi
}

case "${1:-}" in
  build) shift; cmd_build "$@" ;;
  *)     sed -n '3,12p' "$0"; exit 2 ;;
esac
