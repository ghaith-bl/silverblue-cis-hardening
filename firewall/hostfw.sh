#!/usr/bin/env bash
# hostfw - manage the `inet hostfw` nftables table
# run `hostfw.sh help` for commands
# shellcheck disable=SC2086   # $T is "inet hostfw", split on purpose
set -euo pipefail

T="inet hostfw"

ETC_DIR=/etc/hostfw
MODE_FILE=$ETC_DIR/mode
SBIN=/usr/local/sbin/hostfw
UNIT_DST=/etc/systemd/system/hostfw.service
DISPATCHER_DST=/etc/NetworkManager/dispatcher.d/90-hostfw-sync
ROLLBACK=hostfw-rollback
RUN_DIR=/run/hostfw
DEADLINE_FILE=$RUN_DIR/rollback
STATE_DIR=/var/lib/hostfw
MARK_FILE=$STATE_DIR/wg_fwmark

WG_IFACES=${HOSTFW_WG_IFACES:-wg0-mullvad}

SELF=$(readlink -f "${BASH_SOURCE[0]}")
SELF_DIR=$(dirname "$SELF")
NFT=$(command -v nft || echo /usr/sbin/nft)

die()  { echo "hostfw: $*" >&2; exit 1; }
log()  { echo "hostfw: $*"; }
need_root()    { [[ $EUID -eq 0 ]] || die "run with sudo"; }
table_loaded() { "$NFT" list table $T >/dev/null 2>&1; }
need_table()   { table_loaded || die "table '$T' not loaded (run: hostfw apply)"; }

ruleset_path() {
    if   [[ -n ${HOSTFW_RULESET:-} ]];      then echo "$HOSTFW_RULESET"
    elif [[ -f $SELF_DIR/hostfw.nft ]];     then echo "$SELF_DIR/hostfw.nft"
    elif [[ -f $ETC_DIR/hostfw.nft ]];      then echo "$ETC_DIR/hostfw.nft"
    else die "hostfw.nft not found"; fi
}

live_mode() {
    table_loaded || { echo off; return; }
    if "$NFT" list chain $T enforce | grep -qE '^[[:space:]]+reject'; then
        echo enforce
    else
        echo observe
    fi
}

# parse "--rollback N" / "--no-rollback"; sets ROLLBACK_MIN
parse_rollback() {
    while (( $# )); do
        case $1 in
            --rollback)    [[ ${2:-} =~ ^[0-9]+$ ]] || die "--rollback needs minutes"
                           ROLLBACK_MIN=$2; shift 2 ;;
            --no-rollback) ROLLBACK_MIN=0; shift ;;
            *)             die "unknown option: $1" ;;
        esac
    done
}

# ---------- rollback timer ----------

rollback_clear() {
    systemctl stop "$ROLLBACK.timer" "$ROLLBACK.service" >/dev/null 2>&1 || true
    systemctl reset-failed "$ROLLBACK.timer" "$ROLLBACK.service" >/dev/null 2>&1 || true
    rm -f "$DEADLINE_FILE"
}

rollback_arm() {   # $1 = minutes, rest = command to run
    local min=$1; shift
    rollback_clear
    systemd-run --quiet --unit="$ROLLBACK" --on-active="${min}min" \
        --timer-property=AccuracySec=1s "$@"
    # 0755 / 0644: sectop's collector (user sectop, not root) shows the deadline.
    # Deadline + action only, nothing secret.
    install -d -m 0755 "$RUN_DIR"
    printf '%s\n%s\n' "$(( $(date +%s) + min * 60 ))" "$*" > "$DEADLINE_FILE"
    chmod 0644 "$DEADLINE_FILE"
    log "rollback in ${min} min -> $*"
    log "keep it with: sudo $0 confirm"
}

rollback_left() {   # "Xm Ys left -> action" from the deadline file
    local deadline action left
    [[ -r $DEADLINE_FILE ]] || { echo "?"; return; }
    { read -r deadline; read -r action; } < "$DEADLINE_FILE"
    left=$(( deadline - $(date +%s) ))
    (( left < 0 )) && left=0
    printf '%dm %02ds left -> %s' $(( left / 60 )) $(( left % 60 )) "$action"
}

rollback_pending() { systemctl is-active --quiet "$ROLLBACK.timer"; }

# ---------- helpers ----------

is_excluded_if() {
    local ifc
    for ifc in $WG_IFACES; do [[ $1 == "$ifc" ]] && return 0; done
    return 1
}

uplink_gateways() {   # prints "dev gw" for IPv4 default routes not on the tunnel
    ip -4 route show default | awk '
        { d = ""; g = ""
          for (i = 1; i < NF; i++) { if ($i == "dev") d = $(i+1); if ($i == "via") g = $(i+1) }
          if (d != "" && g != "") print d, g }' |
    while read -r dev gw; do
        is_excluded_if "$dev" || echo "$dev $gw"
    done
}

read -r -d '' PY_SET <<'PY' || true
import json, signal, sys
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
d = json.loads(sys.argv[1])
is_mark = sys.argv[2] == "mark"
def s(v):
    if isinstance(v, dict):
        if "concat" in v:
            return " . ".join(s(x) for x in v["concat"])
        if "elem" in v:
            e = v["elem"]
            r = s(e["val"])
            if "expires" in e:
                r += " (expires %ss)" % e["expires"]
            return r
        if "prefix" in v:
            return "%s/%s" % (v["prefix"]["addr"], v["prefix"]["len"])
        if "range" in v:
            return "-".join(s(x) for x in v["range"])
        return json.dumps(v)
    if is_mark and isinstance(v, int):
        return hex(v)
    return str(v)
for o in d["nftables"]:
    if "set" in o:
        el = o["set"].get("elem", [])
        print(", ".join(s(x) for x in el) if el else "(empty)")
PY

read -r -d '' PY_COUNTERS <<'PY' || true
import json, signal, sys
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
d = json.loads(sys.argv[1])
rows = [o["counter"] for o in d["nftables"] if "counter" in o]
print("%-18s %12s %14s  %s" % ("counter", "packets", "bytes", "comment"))
for c in rows:
    print("%-18s %12d %14d  %s" % (c["name"], c["packets"], c["bytes"], c.get("comment", "")))
PY

set_elems() {   # $1 = set name, $2 = "mark" for hex output
    python3 -I -c "$PY_SET" "$("$NFT" -j list set $T "$1")" "${2:-}"
}

# ---------- commands ----------

cmd_apply() {
    need_root
    ROLLBACK_MIN=0; parse_rollback "$@"
    local rs; rs=$(ruleset_path)
    "$NFT" -c -f "$rs" || die "syntax check failed: $rs"
    "$NFT" -f "$rs"
    log "loaded $rs (runtime only, mode: observe)"
    cmd_sync
    if (( ROLLBACK_MIN > 0 )); then
        rollback_arm "$ROLLBACK_MIN" "$NFT" delete table $T
    else
        rollback_clear
    fi
}

cmd_boot() {   # used by hostfw.service
    need_root
    "$NFT" -f "$ETC_DIR/hostfw.nft"
    local mode=observe
    [[ -r $MODE_FILE ]] && mode=$(tr -d '[:space:]' < "$MODE_FILE")
    if [[ $mode == enforce ]]; then
        "$NFT" add rule $T enforce reject with icmpx admin-prohibited
    fi
    log "boot: mode $mode"
    cmd_sync || true
}

cmd_observe() {
    need_root; need_table
    "$NFT" flush chain $T enforce
    rollback_clear
    log "mode: observe (log only)"
}

cmd_enforce() {
    need_root; need_table
    ROLLBACK_MIN=3; parse_rollback "$@"
    "$NFT" flush chain $T enforce
    "$NFT" add rule $T enforce reject with icmpx admin-prohibited
    log "mode: enforce"
    if (( ROLLBACK_MIN > 0 )); then
        rollback_arm "$ROLLBACK_MIN" "$NFT" flush chain $T enforce
    fi
}

cmd_confirm() {
    need_root
    rollback_clear
    log "rollback cancelled"
    local mode; mode=$(live_mode)
    if [[ -d $ETC_DIR && $mode != off ]]; then
        echo "$mode" > "$MODE_FILE"
        log "saved boot mode: $mode ($MODE_FILE)"
    else
        log "not installed - runtime only (mode: $mode)"
    fi
}

cmd_sync() {
    need_root; need_table
    local ifc mark list saved dev gw
    local marks=()

    # wg_fwmark: hostfw.nft ships Mullvad's mark (0x6d6f6c65, the same on every
    # connect). Tunnel up: replaced by the live mark; tunnel down: the last live
    # mark is added (saved), so a changed mark still works before the tunnel is up
    if command -v wg >/dev/null; then
        for ifc in $WG_IFACES; do
            mark=$(wg show "$ifc" fwmark 2>/dev/null || true)
            if [[ $mark =~ ^(0x[0-9a-fA-F]+|[1-9][0-9]*)$ ]]; then
                marks+=("$mark")
                log "wg_fwmark: $ifc $mark"
            fi
        done
    fi
    if (( ${#marks[@]} )); then
        list=$(IFS=,; echo "${marks[*]}")
        "$NFT" -f - <<< "flush set $T wg_fwmark
add element $T wg_fwmark { $list }"
        saved=$(cat "$MARK_FILE" 2>/dev/null || true)
        if [[ $saved != "$list" ]]; then
            { install -d -m 0755 "$STATE_DIR" && echo "$list" > "$MARK_FILE"; } 2>/dev/null ||
                log "wg_fwmark: could not save $MARK_FILE"
        fi
    elif [[ -r $MARK_FILE ]]; then
        list=$(tr -d '[:space:]' < "$MARK_FILE")
        if [[ $list =~ ^(0x[0-9a-fA-F]+|[1-9][0-9]*)(,(0x[0-9a-fA-F]+|[1-9][0-9]*))*$ ]]; then
            "$NFT" add element $T wg_fwmark "{ $list }"
            log "wg_fwmark: tunnel down - keeping last mark $list"
        else
            log "wg_fwmark: ignoring invalid $MARK_FILE"
        fi
    else
        log "wg_fwmark: tunnel never seen - keeping the ruleset mark (Mullvad 0x6d6f6c65)"
    fi

    "$NFT" flush set $T router4
    while read -r dev gw; do
        [[ -n $gw ]] || continue
        "$NFT" add element $T router4 "{ $gw }"
        log "router4: $gw ($dev)"
    done < <(uplink_gateways)
}

cmd_router_open() {
    need_root; need_table
    local min=${1:-10} gw n=0
    [[ $min =~ ^[0-9]+$ ]] && (( min >= 1 && min <= 120 )) || die "minutes: 1-120"
    while read -r _ gw; do
        "$NFT" -f - <<< "destroy element $T router_admin4 { $gw . 80, $gw . 443 }
        add element $T router_admin4 { $gw . 80 timeout ${min}m, $gw . 443 timeout ${min}m }"
        log "router web UI open: $gw tcp 80,443 for ${min} min"
        n=1
    done < <(uplink_gateways)
    (( n )) || die "no uplink gateway found"
}

cmd_status() {
    need_root
    local mode; mode=$(live_mode)
    echo "mode:          $mode"
    [[ $mode == off ]] && return 0
    if rollback_pending; then
        echo "rollback:      ARMED, $(rollback_left)"
    else
        echo "rollback:      none"
    fi
    echo "installed:     $([[ -f $UNIT_DST ]] && echo yes || echo no)  boot mode: $(cat "$MODE_FILE" 2>/dev/null || echo -)"
    echo "wg_fwmark:     $(set_elems wg_fwmark mark)"
    echo "router4:       $(set_elems router4)"
    echo "router_admin4: $(set_elems router_admin4)"
    echo "lan_allow4:    $(set_elems lan_allow4)"
    echo
    cmd_counters
}

cmd_counters() {
    need_root; need_table
    if [[ ${1:-} == --json ]]; then
        "$NFT" -j list counters table $T
    else
        python3 -I -c "$PY_COUNTERS" "$("$NFT" -j list counters table $T)"
    fi
}

cmd_report() {
    local since=${1:-7 days ago} top=${2:-40}
    [[ $top =~ ^[0-9]+$ ]] || die "top: number"
    echo "# hostfw report - since: $since (logged lines, rate-limited; exact totals: hostfw counters)"
    journalctl _TRANSPORT=kernel --no-pager -o cat --since "$since" -g '^HFW-' 2>/dev/null |
    awk -v top="$top" '
    {
        pfx = $1; sub(/:$/, "", pfx)
        delete kv
        for (i = 2; i <= NF; i++) { n = index($i, "="); if (n > 1) kv[substr($i, 1, n-1)] = substr($i, n+1) }
        if (pfx ~ /^HFW-IN-/)       { ifc = kv["IN"];               peer = kv["SRC"] }
        else if (pfx ~ /^HFW-FWD-/) { ifc = kv["IN"] ">" kv["OUT"]; peer = kv["SRC"] ">" kv["DST"] }
        else                        { ifc = kv["OUT"];              peer = kv["DST"] }
        proto = ("PROTO" in kv) ? kv["PROTO"] : "-"
        port  = ("DPT" in kv) ? kv["DPT"] : (("TYPE" in kv) ? "type" kv["TYPE"] : "-")
        uid   = ("UID" in kv) ? kv["UID"] : "-"
        total[pfx]++
        if (pfx ~ /-NEW$/) next     # allowed new flows: per-rule total only, not top flows
        cnt[pfx " " ifc " " peer " " proto " " port " " uid]++
    }
    END {
        print "\n== per rule =="; fflush()
        for (p in total) printf "%8d  %s\n", total[p], p | "sort -rn"
        close("sort -rn")
        print "\n== top flows (without *-NEW) =="
        printf "%8s  %-22s %-16s %-40s %-7s %-8s %s\n", "lines", "rule", "iface", "peer", "proto", "port", "uid"
        fflush()
        cmd = "sort -rn | head -n " top
        for (k in cnt) {
            split(k, a, " ")
            printf "%8d  %-22s %-16s %-40s %-7s %-8s %s\n", cnt[k], a[1], a[2], a[3], a[4], a[5], a[6] | cmd
        }
        close(cmd)
    }'
}

cmd_remove() {
    need_root
    rollback_clear
    if table_loaded; then "$NFT" delete table $T; log "table removed (runtime)"; else log "table not loaded"; fi
}

cmd_install() {
    need_root
    local f
    for f in hostfw.nft hostfw.service nm-dispatcher/90-hostfw-sync; do
        [[ -f $SELF_DIR/$f ]] || die "missing $SELF_DIR/$f (run install from the repo folder)"
    done
    install -d -m 0755 "$ETC_DIR"
    install -m 0644 "$SELF_DIR/hostfw.nft" "$ETC_DIR/hostfw.nft"
    if [[ ! -f $MODE_FILE ]]; then
        local mode; mode=$(live_mode); [[ $mode == off ]] && mode=observe
        echo "$mode" > "$MODE_FILE"
    fi
    install -m 0755 "$SELF" "$SBIN"
    install -m 0644 "$SELF_DIR/hostfw.service" "$UNIT_DST"
    install -m 0755 "$SELF_DIR/nm-dispatcher/90-hostfw-sync" "$DISPATCHER_DST"
    command -v restorecon >/dev/null && restorecon -RF "$ETC_DIR" "$SBIN" "$UNIT_DST" "$DISPATCHER_DST"
    systemctl daemon-reload
    systemctl enable hostfw.service
    log "installed. boot mode: $(cat "$MODE_FILE")"
    log "table already loaded? keep it. else: sudo systemctl start hostfw.service"
}

cmd_uninstall() {
    need_root
    systemctl disable hostfw.service >/dev/null 2>&1 || true
    rm -f "$UNIT_DST" "$SBIN" "$DISPATCHER_DST"
    systemctl daemon-reload
    log "uninstalled (unit, script, dispatcher). kept: $ETC_DIR"
    log "runtime table untouched - remove with: hostfw.sh remove"
}

cmd_help() {
    cat <<'EOF'
hostfw - host egress filter (nftables table inet hostfw)

  apply [--rollback MIN]     load ruleset runtime-only, mode observe, sync sets
                             --rollback: delete table after MIN unless confirmed
  observe                    log only
  enforce [--rollback MIN]   reject denied traffic (default rollback: 3 min,
                             reverts to observe; --no-rollback to skip)
  confirm                    cancel pending rollback, save mode for boot (if installed)
  sync                       refresh wg_fwmark + router4 (new network; NM dispatcher does it)
                             tunnel down: keeps last wg_fwmark (/var/lib/hostfw/wg_fwmark)
  router-open [MIN]          allow router web UI tcp 80,443 for MIN (default 10) minutes
  status                     mode, rollback, sets, counters
  counters [--json]          per-rule counters (exact)
  report [SINCE] [TOP]       summarize logs, default "7 days ago" 40
  remove                     delete the runtime table
  install / uninstall        boot unit + NM dispatcher (+ /usr/local/sbin/hostfw)

env: HOSTFW_RULESET, HOSTFW_WG_IFACES (wg0-mullvad)
EOF
}

main() {
    local cmd=${1:-help}; shift || true
    case $cmd in
        apply)        cmd_apply "$@" ;;
        boot)         cmd_boot ;;
        observe)      cmd_observe ;;
        enforce)      cmd_enforce "$@" ;;
        confirm)      cmd_confirm ;;
        sync)         cmd_sync ;;
        router-open)  cmd_router_open "$@" ;;
        status)       cmd_status ;;
        counters)     cmd_counters "$@" ;;
        report)       cmd_report "$@" ;;
        remove)       cmd_remove ;;
        install)      cmd_install ;;
        uninstall)    cmd_uninstall ;;
        help|-h|--help) cmd_help ;;
        *)            die "unknown command: $cmd (see: hostfw.sh help)" ;;
    esac
}

main "$@"
