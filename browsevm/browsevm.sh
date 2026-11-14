#!/usr/bin/env bash
#
# browsevm.sh - throwaway browsing VM (docs/browsevm.md)
#
#   sudo browsevm/browsevm.sh build [--force] [--iso <netinst.iso>]
#                                        unattended install of the base image
#
# build: Fedora minimal + cage + Firefox from browsevm.ks, network "browse" (section
# browsevm), Firefox floor policy = browsers/firefox/policies.json + uBlock Origin
# (Fedora package, force-installed) + Mullvad Browser Extension (signed xpi from
# cdn.mullvad.net, fetched at build, force-installed from the image) + no first-run
# pages. The base image is never booted for browsing: the VM (step 3) runs on a
# transient overlay.
# --iso: installer (kernel, initrd, stage2) from a local Fedora Everything netinst ISO
# (needs xorriso), packages still from the mirrors. Without it: all from the network tree.
# Output: the install's serial console logged by virtlogd to
# /var/log/libvirt/qemu/browsevm-build-*.serial.log, a progress line every 20 s (minutes,
# disk size, last installer line), the BROWSEVM: lines at the end.
# A download speed probe runs first: under BROWSEVM_MIN_KBPS (default 200 KB/s) the build
# stops (it would take many hours); BROWSEVM_MIN_KBPS=0 builds anyway.
#
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$HERE")
FEDORA="${BROWSEVM_FEDORA:-45}"
BASE=/var/lib/libvirt/images/browsevm-base.qcow2
BUILD=browsevm-build
NET=browse
LOGDIR=/var/log/libvirt/qemu     # virtlogd writes here (virt_log_t); QEMU never opens it
MIN_KBPS="${BROWSEVM_MIN_KBPS:-200}"
# Mullvad ships the Firefox extension itself (not on addons.mozilla.org); the xpi is
# Mozilla-signed and Firefox checks the signature at install. New version: change it here.
MULLVAD_EXT="${BROWSEVM_MULLVAD_EXT:-0.9.11}"
MULLVAD_XPI_URL="https://cdn.mullvad.net/browser-extension/$MULLVAD_EXT/mullvad-browser-extension-$MULLVAD_EXT.xpi"
MULLVAD_XPI_IN_VM=/usr/share/browsevm/mullvad-browser-extension.xpi
V=(virsh -q -c qemu:///system)
TMPD=""
trap '[[ -n $TMPD ]] && rm -rf "$TMPD"' EXIT

ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

cmd_build() {
  local force=0 iso="" url tmp log started_net=0 state c inject_xpi probe kbps host
  local location label vi rc t0 size last extra
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1 ;;
      --iso)   iso=${2:-}; shift ;;
      *)       die "unknown option: $1" ;;
    esac
    shift
  done
  [[ $EUID -eq 0 ]] || die "run with sudo"
  [[ $FEDORA =~ ^[0-9]{2}$ ]] || die "BROWSEVM_FEDORA must be a release number (e.g. 45)"
  [[ $MIN_KBPS =~ ^[0-9]+$ ]] || die "BROWSEVM_MIN_KBPS must be a number (KB/s)"
  [[ $MULLVAD_EXT =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || die "BROWSEVM_MULLVAD_EXT must be a version (e.g. 0.9.11)"
  for c in virt-install virsh python3 curl; do
    command -v "$c" >/dev/null || die "$c missing"
  done
  "${V[@]}" net-info "$NET" >/dev/null 2>&1 || die "network $NET missing: sudo ./harden-workstation.sh browsevm"
  if [[ -n $iso ]]; then
    [[ -f $iso && $iso == *.iso ]] || die "--iso: no such .iso file: $iso"
    command -v xorriso >/dev/null || die "--iso needs xorriso (virt-install reads the kernel from the ISO with it)"
    label=$(blkid -o value -s LABEL "$iso" 2>/dev/null || true)
    [[ $label =~ ^[A-Za-z0-9._-]{1,32}$ ]] || die "--iso: no usable volume label in $iso ('$label')"
  fi
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

  # speed probe: the install pulls ~2.5 GB (initrd, installer image, packages) through
  # Mullvad; a slow mirror / relay turns that into many hours with a silent screen
  probe=$(curl -fsSL --max-time 40 -o /dev/null -w '%{speed_download} %{url_effective}' \
          "${url}images/pxeboot/vmlinuz" 2>/dev/null || true)
  kbps=${probe%% *}
  kbps=${kbps%%.*}
  [[ $kbps =~ ^[0-9]+$ ]] || kbps=0
  kbps=$(( kbps / 1024 ))
  host=$(sed -E 's|^[^ ]* https?://([^/]+)/.*|\1|' <<<"$probe")
  ok "speed probe: ${kbps} KB/s from ${host:-?} (about $(( kbps > 0 ? 2500 * 1024 / kbps / 60 : 0 )) min for 2.5 GB)"
  if (( kbps < MIN_KBPS )); then
    die "too slow (< $MIN_KBPS KB/s): try another VPN relay, then rerun; BROWSEVM_MIN_KBPS=0 builds anyway"
  fi

  tmp=$(mktemp -d)
  TMPD=$tmp
  sed "s/@FEDORA@/$FEDORA/g" "$HERE/browsevm.ks" > "$tmp/browsevm.ks"

  # Mullvad Browser Extension: Mozilla-signed xpi from Mullvad's CDN (Firefox checks the
  # signature at install); its add-on ID comes from the xpi's own manifest
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
  log="$LOGDIR/$BUILD-$(date +%Y%m%d-%H%M%S).serial.log"
  location=$url
  extra="inst.ks=file:/browsevm.ks inst.text console=ttyS0"
  if [[ -n $iso ]]; then
    location=$iso
    extra="$extra inst.stage2=hd:LABEL=$label"
    ok "installer from $iso (label $label), packages from the mirrors"
  fi

  ok "installing (unattended) - serial log: $log"
  ok "progress every 20 s: minutes, disk MB, last installer line (Ctrl+C stops the build)"
  virt-install --connect qemu:///system --name "$BUILD" \
      --osinfo detect=on,require=off \
      --memory 4096 --vcpus 2 \
      --disk "path=$BASE,size=12,format=qcow2,bus=virtio" \
      --network "network=$NET,model=virtio" \
      --location "$location" \
      --initrd-inject "$tmp/browsevm.ks" --initrd-inject "$tmp/browsevm-policies.json" \
      "${inject_xpi[@]}" \
      --extra-args "$extra" \
      --graphics none --serial "pty,log.file=$log,log.append=off" \
      --noautoconsole --noreboot --wait 300 >"$tmp/virt-install.out" 2>&1 &
  vi=$!
  trap 'kill "$vi" 2>/dev/null; "${V[@]}" destroy "$BUILD" >/dev/null 2>&1; exit 130' INT TERM
  t0=$SECONDS
  while kill -0 "$vi" 2>/dev/null; do
    sleep "${BROWSEVM_PROGRESS_SECS:-20}"
    size=$(du -m "$BASE" 2>/dev/null | cut -f1 || true)
    last=$(tail -c 6000 "$log" 2>/dev/null | tr '\r' '\n' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' |
           LC_ALL=C grep -a '[[:alnum:]]' | tail -n 1 | cut -c1-100 || true)
    [[ -n $last ]] || last="(virt-install) $(tr '\r' '\n' < "$tmp/virt-install.out" |
                            LC_ALL=C grep -a '[[:alnum:]]' | tail -n 1 | cut -c1-90 || true)"
    printf '  %3d min  disk %5s MB  %s\n' $(( (SECONDS - t0) / 60 )) "${size:-0}" "$last"
  done
  if wait "$vi"; then rc=0; else rc=$?; fi
  trap - INT TERM
  if ((rc != 0)); then
    warn "virt-install failed or timed out (rc $rc):"
    tail -n 8 "$tmp/virt-install.out" 2>/dev/null || true
    warn "last lines of $log:"
    tail -n 25 "$log" 2>/dev/null | tr -d '\r' || true
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
