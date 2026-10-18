#!/usr/bin/env bash
# firewalld-cleanup - remove legacy rich rules from the drop zone
#   default:      runtime only (undo: sudo firewall-cmd --reload)
#   --permanent:  runtime + permanent
#
# why:
#   - 192.168.122.0/24 accept: virbr0 is not in drop -> never serves VMs,
#     but accepts spoofed VM-subnet sources on wlo1 / proton0
#   - 127.0.0.1 accept: firewalld already accepts lo -> redundant
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

PERM=0
case ${1:-} in
    "")          ;;
    --permanent) PERM=1 ;;
    *)           echo "usage: $0 [--permanent]" >&2; exit 1 ;;
esac

ZONE=drop
RULES=(
    'rule family="ipv4" source address="192.168.122.0/24" accept'
    'rule family="ipv4" source address="127.0.0.1" accept'
)

for r in "${RULES[@]}"; do
    if firewall-cmd --zone="$ZONE" --query-rich-rule="$r" >/dev/null 2>&1; then
        firewall-cmd --zone="$ZONE" --remove-rich-rule="$r" >/dev/null
        echo "runtime   removed: $r"
    else
        echo "runtime   absent:  $r"
    fi
    if (( PERM )); then
        if firewall-cmd --permanent --zone="$ZONE" --query-rich-rule="$r" >/dev/null 2>&1; then
            firewall-cmd --permanent --zone="$ZONE" --remove-rich-rule="$r" >/dev/null
            echo "permanent removed: $r"
        else
            echo "permanent absent:  $r"
        fi
    fi
done

echo
echo "-- drop zone rich rules now (runtime):"
firewall-cmd --zone="$ZONE" --list-rich-rules || true
echo
echo "-- virbr0 zone: $(firewall-cmd --get-zone-of-interface=virbr0 2>/dev/null || echo none)"
if firewall-cmd --permanent --get-zones | tr ' ' '\n' | grep -qx kvm-hardened; then
    echo "-- kvm-hardened (permanent, not bound to virbr0 - review):"
    firewall-cmd --permanent --info-zone=kvm-hardened
fi
(( PERM )) || echo -e "\nruntime only. undo: sudo firewall-cmd --reload | keep: rerun with --permanent"
