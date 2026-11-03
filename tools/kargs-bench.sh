#!/usr/bin/env bash
#
# kargs-bench.sh - the same numbers before and after a kernel-arg change, to compare
# (trial 2026-11: init_on_free=1 iommu.strict=1).
#
#   tools/kargs-bench.sh before              on the old boot
#   tools/kargs-bench.sh after               on the new boot
#   VM=<name> SSH_HOST=<host> tools/kargs-bench.sh before
#                                            + VM boot to ssh (sudo virsh asks once)
#
# As my user, not root (rootless podman). Same conditions both times: on power, a few
# minutes after login, the same apps open. Writes ~/kargs-bench/<label>-<date>.txt
# (stays on this machine, not in git). Steam FPS and how it feels: by hand, at the end.
#
# What each number shows:
#   mem free      5 x 512 MiB touched + freed: init_on_free zeroes every freed page
#   files         20000 small files created + removed (tmpfs): slab alloc / free
#   disk read     2 GiB O_DIRECT from the NVMe: iommu.strict unmaps DMA at once (IOTLB)
#   podman        3 x `podman run --rm --network=none <image> true`
#   vm            boot to ssh (optional)
#   kernel log    warnings this boot, IOMMU faults (must stay 0)
set -euo pipefail

die() { echo "kargs-bench: $*" >&2; exit 1; }

label=${1:-}
[[ $label =~ ^[a-z0-9-]{1,32}$ ]] || die "usage: $0 before|after|<label>"
[[ $EUID -ne 0 ]] || die "run as your user (rootless podman), not with sudo"
IMAGE=${IMAGE:-registry.fedoraproject.org/fedora-minimal:latest}
DIR=$HOME/kargs-bench
IOFILE=$DIR/io.bin
IO_MB=${IO_MB:-2048}
[[ $IO_MB =~ ^[0-9]{1,5}$ ]] || die "IO_MB: MiB"
out=$DIR/$label-$(date +%Y%m%d-%H%M).txt
mkdir -p "$DIR"

since() { awk -v a="$1" -v b="$EPOCHREALTIME" 'BEGIN { printf "%.2f s", b - a }'; }
row()   { printf '%-22s %s\n' "$1" "$2"; }

{
echo "# kargs-bench $label  $(date '+%F %T')"
echo
echo "## kernel"
row "kernel" "$(uname -r)"
row "args (trial)" "$(grep -oE '(init_on_free|init_on_alloc|iommu\.strict|iommu\.passthrough|intel_iommu)=[^ ]+' /proc/cmdline | paste -sd' ' - || true)"
row "iommu units" "$(find /sys/class/iommu -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
journalctl -k -b -o cat --no-pager \
    -g 'mem auto-init|iommu: Default domain type|TLB invalidation policy' 2>/dev/null |
    sed 's/^/  /' || echo "  (kernel log not readable as this user)"
row "on power" "$(cat /sys/class/power_supply/A*/online 2>/dev/null | head -1 || echo ?)  (1 = yes)"
row "load" "$(cut -d' ' -f1-3 /proc/loadavg)"
echo

echo "## boot"
systemd-analyze 2>/dev/null | head -1 || echo "  systemd-analyze failed"
echo

echo "## mem free (5 x 512 MiB)"
t=$EPOCHREALTIME
python3 -I -c '
for _ in range(5):
    x = b"\x01" * (512 << 20)
    del x
'
row "time" "$(since "$t")"
echo

echo "## files (20000 create + remove, tmpfs)"
tmp=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/kargs-bench.XXXXXX")
t=$EPOCHREALTIME
python3 -I - "$tmp" <<'PY'
import os, sys
d = sys.argv[1]
for i in range(20000):
    p = os.path.join(d, str(i))
    with open(p, "wb") as f:
        f.write(b"x")
    os.unlink(p)
PY
row "time" "$(since "$t")"
rmdir "$tmp"
echo

echo "## disk read ($IO_MB MiB, O_DIRECT)"
if [[ ! -s $IOFILE ]]; then
    echo "  first run: writing $IOFILE ($IO_MB MiB, kept for the next runs)"
    dd if=/dev/urandom of="$IOFILE" bs=1M count="$IO_MB" status=none conv=fsync
fi
t=$EPOCHREALTIME
dd if="$IOFILE" of=/dev/null bs=1M iflag=direct status=none
row "time" "$(since "$t")"
echo

echo "## podman (3 x run --rm true)"
if command -v podman >/dev/null; then
    podman image exists "$IMAGE" || podman pull -q "$IMAGE" >/dev/null
    for i in 1 2 3; do
        t=$EPOCHREALTIME
        podman run --rm --network=none "$IMAGE" true
        row "run $i" "$(since "$t")"
    done
else
    echo "  no podman"
fi
echo

echo "## vm boot to ssh"
if [[ -n ${VM:-} && -n ${SSH_HOST:-} ]]; then
    sudo virsh start "$VM" >/dev/null
    t=$EPOCHREALTIME
    ok=no
    for _ in $(seq 90); do
        if ssh -o BatchMode=yes -o ConnectTimeout=2 "$SSH_HOST" true 2>/dev/null; then
            ok=yes; break
        fi
        sleep 2
    done
    row "$VM" "$( [[ $ok == yes ]] && since "$t" || echo 'no ssh within 180 s' )"
    sudo virsh shutdown "$VM" >/dev/null || true
else
    echo "  skipped (VM=<name> SSH_HOST=<host>)"
fi
echo

echo "## kernel log this boot"
row "warnings+" "$(journalctl -k -b -p warning -o cat --no-pager 2>/dev/null | grep -c . || true)"
row "iommu faults" "$(journalctl -k -b -o cat --no-pager -g 'DMAR.*fault|IOMMU.*fault|PTE Read access' 2>/dev/null | grep -c . || true)  (must be 0)"
echo "  errors (max 20):"
journalctl -k -b -p err -o cat --no-pager 2>/dev/null | tail -n 20 | sed 's/^/    /' || true
echo

echo "## by hand"
echo "steam fps, same scene 2 min:"
echo "feel / latency:"
} 2>&1 | tee "$out"

echo
echo "saved: $out"
