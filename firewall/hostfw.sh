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
# noscope: GNOME Shell's cgroup (rule out_noscope), own mode, own watcher
NOSCOPE_FILE=$ETC_DIR/noscope
NOSCOPE_BIN=/usr/local/sbin/hostfw-noscope
NOSCOPE_UNIT=hostfw-noscope.service
NOSCOPE_UNIT_DST=/etc/systemd/system/$NOSCOPE_UNIT
NOSCOPE_STATE=/run/hostfw-noscope/state
ROLLBACK=hostfw-rollback
RUN_DIR=/run/hostfw
DEADLINE_FILE=$RUN_DIR/rollback
STATE_DIR=/var/lib/hostfw
MARK_FILE=$STATE_DIR/wg_fwmark
# this machine's addresses (VPN resolver, VPN API): kept out of git
LOCAL_FILE=${HOSTFW_LOCAL:-$ETC_DIR/local.conf}
LOCAL_SETS="vpn_dns4 vpn_api4"
IP4_RE='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'

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
    if "$NFT" list chain $T enforce | grep -E '^[[:space:]]+reject' >/dev/null; then
        echo enforce
    else
        echo observe
    fi
}

noscope_live() {   # observe | enforce | missing (table without chain enforce_noscope) | off
    table_loaded || { echo off; return; }
    local rules
    rules=$("$NFT" list chain $T enforce_noscope 2>/dev/null) || { echo missing; return; }
    if grep -qE '^[[:space:]]+reject' <<< "$rules"; then echo enforce; else echo observe; fi
}

noscope_set_mode() {   # $1 = observe | enforce (live only)
    "$NFT" flush chain $T enforce_noscope
    if [[ $1 == enforce ]]; then
        "$NFT" add rule $T enforce_noscope reject with icmpx admin-prohibited
    fi
}

# table (re)loaded = set noscope_cg empty: the watcher fills it again on its first look
noscope_refill() {
    systemctl --no-block try-restart "$NOSCOPE_UNIT" >/dev/null 2>&1 || true
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

# `nft -j list chain inet mullvad output` -> the addresses of Mullvad's API rule, one per
# line: exactly `ip daddr <addr> tcp dport 443 meta skuid 0 accept` (any order). Mullvad
# has it only while not connected (docs/mullvad.md); the relay rule has a mark, not skuid.
read -r -d '' PY_API <<'PY' || true
import json, sys
want = [({"payload": {"protocol": "tcp", "field": "dport"}}, 443),
        ({"meta": {"key": "skuid"}}, 0)]
out = set()
for o in json.loads(sys.argv[1])["nftables"]:
    r = o.get("rule")
    if not isinstance(r, dict) or r.get("chain") != "output":
        continue
    m = [e["match"] for e in r.get("expr", []) if "match" in e]
    rest = [e for e in r.get("expr", []) if "match" not in e]
    if rest != [{"accept": None}] or len(m) != 3 or any(x.get("op") != "==" for x in m):
        continue
    got = [(x["left"], x["right"]) for x in m]
    ip = [v for k, v in got if k == {"payload": {"protocol": "ip", "field": "daddr"}}]
    if len(ip) == 1 and isinstance(ip[0], str) and all(w in got for w in want):
        out.add(ip[0])
print("\n".join(sorted(out)))
PY

# local.conf -> nft commands on stdout; returns 1 (and prints nothing) on any problem.
# Lines: "<set> <ipv4>[,<ipv4>...]", "#" starts a comment. Every set in LOCAL_SETS needed.
# Log lines never show the addresses.
local_cmds() {
    local file=$1 name rest ip s out="" ips
    [[ -r $file ]] || { log "local: $file missing" >&2; return 1; }
    for s in $LOCAL_SETS; do out+="flush set $T $s"$'\n'; done
    while read -r name rest || [[ -n ${name:-} ]]; do
        [[ -z ${name:-} || $name == \#* ]] && continue
        case " $LOCAL_SETS " in
            *" $name "*) ;;
            *) log "local: unknown set '$name' in $file" >&2; return 1 ;;
        esac
        rest=${rest%%#*}
        IFS=', ' read -ra ips <<< "$rest"
        (( ${#ips[@]} )) || { log "local: no address for $name in $file" >&2; return 1; }
        for ip in "${ips[@]}"; do
            [[ $ip =~ $IP4_RE ]] || { log "local: invalid address for $name in $file" >&2; return 1; }
            out+="add element $T $name { $ip }"$'\n'
        done
    done < "$file"
    for s in $LOCAL_SETS; do
        [[ $out == *"add element $T $s "* ]] || { log "local: $s missing in $file" >&2; return 1; }
    done
    printf '%s' "$out"
}

set_elems() {   # $1 = set name, $2 = "mark" for hex output
    python3 -I -c "$PY_SET" "$("$NFT" -j list set $T "$1")" "${2:-}"
}

# ---------- commands ----------

cmd_apply() {
    need_root
    ROLLBACK_MIN=0; parse_rollback "$@"
    local rs; rs=$(ruleset_path)
    local_cmds "$LOCAL_FILE" >/dev/null ||
        die "fix $LOCAL_FILE first (template: firewall/hostfw.local.example)"
    "$NFT" -c -f "$rs" || die "syntax check failed: $rs"
    "$NFT" -f "$rs"
    log "loaded $rs (runtime only, mode: observe, noscope: observe)"
    noscope_refill
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
    local noscope=observe
    [[ -r $NOSCOPE_FILE ]] && noscope=$(tr -d '[:space:]' < "$NOSCOPE_FILE")
    [[ $noscope == enforce ]] || noscope=observe
    noscope_set_mode "$noscope"
    log "boot: mode $mode, noscope $noscope"
    noscope_refill
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
    local ifc mark list saved dev gw cmds
    local marks=()

    # vpn_dns4 + vpn_api4 from local.conf (one transaction: flush + add)
    if cmds=$(local_cmds "$LOCAL_FILE"); then
        "$NFT" -f - <<< "$cmds"
        log "local: vpn_dns4, vpn_api4 loaded from $LOCAL_FILE"
    else
        log "WARNING: local.conf not loaded - vpn_dns4 / vpn_api4 unchanged (empty after apply / boot = VPN DNS and VPN API blocked)"
    fi

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

cmd_api_update() {   # vpn_api4 <- the address inet mullvad allows; asks first
    need_root; need_table
    local json out old ans tmp
    local new=()
    json=$("$NFT" -j list chain inet mullvad output 2>/dev/null) ||
        die "chain inet mullvad output not loaded (mullvad-daemon running?)"
    out=$(python3 -I -c "$PY_API" "$json") || die "could not read chain inet mullvad output"
    [[ -n $out ]] && mapfile -t new <<< "$out"
    case ${#new[@]} in
        0) die "no API rule in inet mullvad output: Mullvad shows it only while not connected
       (mullvad disconnect, run this again, mullvad connect)" ;;
        1) [[ ${new[0]} =~ $IP4_RE ]] || die "not an IPv4 address: ${new[0]}" ;;
        *) die "more than one API address (${new[*]}): edit $LOCAL_FILE by hand" ;;
    esac
    local_cmds "$LOCAL_FILE" >/dev/null || die "fix $LOCAL_FILE first"
    old=$(awk '$1 == "vpn_api4" { sub(/#.*/, ""); $1 = ""; gsub(/^[ ,]+|[ ,]+$/, ""); print }' \
          "$LOCAL_FILE" | paste -sd, -)
    if [[ $old == "${new[0]}" ]]; then
        log "vpn_api4 is already ${new[0]}: nothing to change"
        return 0
    fi
    echo "vpn_api4 in $LOCAL_FILE: ${old:-none}"
    echo "Mullvad allows now:  ${new[0]}"
    read -r -p "write the new address and sync? [y/N] " ans || ans=""
    [[ $ans == [yY] ]] || { log "nothing changed"; return 0; }
    # new file next to the old one (root 0600, same SELinux label), checked, then renamed
    tmp=$(mktemp "$LOCAL_FILE.XXXXXX")
    awk -v ip="${new[0]}" '$1 == "vpn_api4" { if (!done) print "vpn_api4 " ip; done = 1; next }
                           { print }' "$LOCAL_FILE" > "$tmp"
    local_cmds "$tmp" >/dev/null || { rm -f "$tmp"; die "new file invalid: $LOCAL_FILE unchanged"; }
    cp -p "$LOCAL_FILE" "$LOCAL_FILE.bak"
    mv "$tmp" "$LOCAL_FILE"
    command -v restorecon >/dev/null && restorecon "$LOCAL_FILE"
    log "vpn_api4: ${old:-none} -> ${new[0]} (old file: $LOCAL_FILE.bak)"
    cmd_sync
}

cmd_noscope() {   # observe | enforce | sync | status
    local sub=${1:-status}
    case $sub in
        observe|enforce)
            need_root; need_table
            [[ $(noscope_live) != missing ]] ||
                die "chain enforce_noscope missing: old ruleset loaded (install, then systemctl reload hostfw)"
            noscope_set_mode "$sub"
            if [[ -d $ETC_DIR ]]; then
                echo "$sub" > "$NOSCOPE_FILE"
                log "noscope: $sub (saved for boot: $NOSCOPE_FILE)"
            else
                log "noscope: $sub (runtime only, not installed)"
            fi ;;
        sync)
            need_root; need_table
            [[ -x $NOSCOPE_BIN ]] || die "$NOSCOPE_BIN missing (run: hostfw install)"
            /usr/bin/python3 -I -B "$NOSCOPE_BIN" --once ;;
        status)
            need_root
            local n
            echo "noscope mode:  $(noscope_live)  boot: $(cat "$NOSCOPE_FILE" 2>/dev/null || echo -)"
            echo "watcher:       $(systemctl is-active "$NOSCOPE_UNIT" 2>/dev/null || true)"
            if [[ -s $NOSCOPE_STATE ]]; then
                echo "cgroups:       (id path, from $NOSCOPE_STATE)"
                sed 's/^/  /' "$NOSCOPE_STATE"
            else
                echo "cgroups:       none (no GNOME Shell session, or watcher not running)"
            fi
            table_loaded &&
                echo "counter:       $("$NFT" list counter $T out_noscope 2>/dev/null |
                                       grep -oE 'packets [0-9]+ bytes [0-9]+' || echo missing)  (since table load)"
            n=$(journalctl _TRANSPORT=kernel -b --no-pager -o cat -g '^HFW-OUT-NOSCOPE:' 2>/dev/null |
                grep -c . || true)
            echo "log lines:     $n this boot (rate-limited; all boots: hostfw report)" ;;
        *)  die "noscope: observe | enforce | sync | status" ;;
    esac
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
    echo "noscope:       $(noscope_live)  (hostfw noscope status)"
    if rollback_pending; then
        echo "rollback:      ARMED, $(rollback_left)"
    else
        echo "rollback:      none"
    fi
    echo "installed:     $([[ -f $UNIT_DST ]] && echo yes || echo no)  boot mode: $(cat "$MODE_FILE" 2>/dev/null || echo -)"
    echo "local.conf:    $(local_cmds "$LOCAL_FILE" >/dev/null 2>&1 && echo ok || echo "MISSING / INVALID ($LOCAL_FILE)")"
    echo "vpn_dns4:      $(set_elems vpn_dns4)"
    echo "vpn_api4:      $(set_elems vpn_api4)"
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
    for f in hostfw.nft hostfw.service nm-dispatcher/90-hostfw-sync hostfw-noscope.py \
             hostfw-noscope.service; do
        [[ -f $SELF_DIR/$f ]] || die "missing $SELF_DIR/$f (run install from the repo folder)"
    done
    install -d -m 0755 "$ETC_DIR"
    install -m 0644 "$SELF_DIR/hostfw.nft" "$ETC_DIR/hostfw.nft"
    if [[ ! -f $MODE_FILE ]]; then
        local mode; mode=$(live_mode); [[ $mode == off ]] && mode=observe
        echo "$mode" > "$MODE_FILE"
    fi
    [[ -f $NOSCOPE_FILE ]] || echo observe > "$NOSCOPE_FILE"
    install -m 0755 "$SELF" "$SBIN"
    install -m 0755 "$SELF_DIR/hostfw-noscope.py" "$NOSCOPE_BIN"
    install -m 0644 "$SELF_DIR/hostfw.service" "$UNIT_DST"
    install -m 0644 "$SELF_DIR/hostfw-noscope.service" "$NOSCOPE_UNIT_DST"
    install -m 0755 "$SELF_DIR/nm-dispatcher/90-hostfw-sync" "$DISPATCHER_DST"
    command -v restorecon >/dev/null &&
        restorecon -RF "$ETC_DIR" "$SBIN" "$NOSCOPE_BIN" "$UNIT_DST" "$NOSCOPE_UNIT_DST" "$DISPATCHER_DST"
    systemctl daemon-reload
    systemctl enable hostfw.service
    systemctl enable "$NOSCOPE_UNIT"
    [[ -f $LOCAL_FILE ]] ||
        log "WARNING: $LOCAL_FILE missing - create it from firewall/hostfw.local.example before reboot"
    log "installed. boot mode: $(cat "$MODE_FILE"), noscope: $(cat "$NOSCOPE_FILE")"
    log "table already loaded? new ruleset: sudo systemctl reload hostfw.service (counters reset)"
    log "  then: sudo systemctl start $NOSCOPE_UNIT"
    log "not loaded: sudo systemctl start hostfw.service"
}

cmd_uninstall() {
    need_root
    systemctl disable --now "$NOSCOPE_UNIT" >/dev/null 2>&1 || true
    systemctl disable hostfw.service >/dev/null 2>&1 || true
    rm -f "$UNIT_DST" "$SBIN" "$DISPATCHER_DST" "$NOSCOPE_BIN" "$NOSCOPE_UNIT_DST"
    systemctl daemon-reload
    log "uninstalled (unit, script, dispatcher). kept: $ETC_DIR (mode, local.conf)"
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
  sync                       load vpn_dns4 + vpn_api4 from /etc/hostfw/local.conf,
                             refresh wg_fwmark + router4 (new network; NM dispatcher does it)
                             tunnel down: keeps last wg_fwmark (/var/lib/hostfw/wg_fwmark)
  api-update                 vpn_api4 in /etc/hostfw/local.conf <- the API address
                             inet mullvad allows (Mullvad not connected), asks y/N, sync
  router-open [MIN]          allow router web UI tcp 80,443 for MIN (default 10) minutes
  noscope observe|enforce    new flows from GNOME Shell's cgroup (out_noscope): log only /
                             reject; own switch, saved for boot (/etc/hostfw/noscope)
  noscope sync | status      fill set noscope_cg once / mode, watcher, cgroups, counter
  status                     mode, rollback, sets, counters
  counters [--json]          per-rule counters (exact)
  report [SINCE] [TOP]       summarize logs, default "7 days ago" 40
  remove                     delete the runtime table
  install / uninstall        boot unit + NM dispatcher (+ /usr/local/sbin/hostfw)

local.conf: this machine's addresses, not in git (firewall/hostfw.local.example)
env: HOSTFW_RULESET, HOSTFW_LOCAL, HOSTFW_WG_IFACES (wg0-mullvad)
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
        api-update)   cmd_api_update ;;
        router-open)  cmd_router_open "$@" ;;
        noscope)      cmd_noscope "$@" ;;
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
