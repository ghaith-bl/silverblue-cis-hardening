# hostfw rules

Table `inet hostfw`, base chains at `priority filter - 10` (before firewalld).
Source of truth: `hostfw.nft`. This file = quick reference + sectop contract.

## Naming contract (sectop)

```
log prefix   HFW-<DIR>-<NAME>:      DIR = OUT | IN | FWD
counter      <dir>_<name>           exact totals, nft -j list counters table inet hostfw
comment      same as counter name, on every rule
log flags    skuid on OUT rules     -> UID= in the log line (program name: not available)
log level    info, kernel log       -> journalctl -k -g '^HFW-'
rate limit   10/min burst 20 per rule (noise: 6/min burst 10) -> counters are exact, logs are samples
             *-NEW rules: 5/s burst 50 (one page load = tens of flows)
```

## Interface classes

| set | members | meaning |
|---|---|---|
| `if_vpn` | wg0-mullvad | VPN tunnel (Mullvad WireGuard) |
| `if_trusted` | lo, wg0-mullvad, virbr0 | egress allowed, minus never-leave rules |
| `if_vm` | virbr0 | libvirt bridges |
| (none) | wifi, ethernet, anything new | uplink - router + tunnel transport only |

## Dynamic sets

| set | filled by | content |
|---|---|---|
| `wg_fwmark` | ruleset (0x6d6f6c65), `hostfw sync` / NM dispatcher | `wg show wg0-mullvad fwmark` |
| `vpn_dns4` | `/etc/hostfw/local.conf`, `hostfw sync` | Mullvad resolver inside the tunnel |
| `vpn_api4` | `/etc/hostfw/local.conf`, `hostfw sync` | Mullvad API, the address inet mullvad allows outside the tunnel |
| `router4` | `hostfw sync` / NM dispatcher | IPv4 default gateways, not the tunnel |
| `router_admin4` | `hostfw router-open [MIN]` | gw . 80, gw . 443 with timeout |
| `lan_allow4` | edit `hostfw.nft` | static `ip . proto . port` exceptions |
| `noscope_cg` | hostfw-noscope.service (every 5 s, on a change) | GNOME Shell's cgroup ids (`socket cgroupv2 level 5`) |

## output

| # | comment | match | action | prefix |
|---|---|---|---|---|
| 1 | out_est | ct established,related | accept | - |
| 2 | out_lo | oif lo | accept | - |
| 3 | out_split | ct mark 0xf41, or mark in wg_fwmark from a non-root socket; oif not in if_vm | count + log + reject, every mode | HFW-OUT-SPLIT |
| 4 | out_noscope | GNOME Shell cgroup (set noscope_cg), not established | count + log, own switch `enforce_noscope` | HFW-OUT-NOSCOPE |
| 5 | out_dns_vpn | tcp/udp 53,853 -> vpn_dns4 via wg0-mullvad | accept, counted | - |
| 6 | out_dns_vm | tcp/udp 53,853 via virbr0 | accept | - |
| 7 | out_dns | any other tcp/udp 53,853 | deny | HFW-OUT-DNS |
| 8 | out_disco | udp 137,138,1900,3702,5351,5353,5355,27036 / tcp 5355,5357,5358,27036,27037 | deny | HFW-OUT-DISCO |
| 9 | out_share | tcp 21,111,139,445,548,2049 / udp 69,111,2049, not via virbr0 | deny | HFW-OUT-SHARE |
| 10 | out_new | oif in if_vpn, ct new | accept + log | HFW-OUT-NEW |
| 11 | out_trusted | oif in if_trusted | accept | - |
| 12 | out_wg | meta mark in wg_fwmark, ct mark not 0xf41 | accept, counted | - |
| 13 | out_vpn_api | uid 0 tcp 443 -> vpn_api4 | accept, counted | - |
| 14 | out_dhcp4 | udp 68 -> 67 | accept | - |
| 15 | out_router_icmp | icmp echo-request -> router4 | accept | - |
| 16 | out_router_admin | ip . tcp port in router_admin4 | accept + log | HFW-OUT-ROUTER-ADMIN |
| 17 | out_lan_allow | ip . proto . port in lan_allow4 | accept + log | HFW-OUT-LAN-ALLOW |
| 18 | out_ndp6 | icmpv6 RS, NS, NA, MLDv2 report | accept | - |
| 19 | out_lan | daddr private / link-local / CGNAT / multicast / broadcast | deny | HFW-OUT-LAN |
| 20 | out_leak | anything else on uplink | deny | HFW-OUT-LEAK |

`out_wg`: the Mullvad daemon sets mark 0x6d6f6c65 on the relay transport (setting a
mark needs CAP_NET_ADMIN). Its API calls outside the tunnel have no mark: `out_vpn_api`
allows them the way `inet mullvad` does (uid 0, tcp 443, one address), nothing else.

`out_split` (2026-11-05): split tunneling (`mullvad-exclude`, or `mullvad split-tunnel
add <pid>`) sets ct mark 0xf41 + mark 0x6d6f6c65, Mullvad then routes the program
outside the tunnel. `/usr/bin/mullvad-exclude` is setuid root: any local user, malware
in the daily account too, can start a program there (checked as the daily user
2026-11-05: the process lands in net_cls `/mullvad-exclusions`). Why its own rule, tests:
observe-log.md (2026-11-01, 2026-11-05).
- own deny chain, `reject` in it, no `jump enforce`: blocked in observe too, no switch
  (split tunneling is not used on this host)
- any interface but `if_vm`: kvmlan puts the same marks on host <-> VM packets
  (virbr0), those stay allowed. Replies to VM flows are `established` (rule 1)
- two matches, one chain: ct mark 0xf41 (Mullvad's documented split mark) and the
  relay mark on a socket that is not uid 0 (test 2026-11-01: `UID=1000 MARK=0x6d6f6c65`,
  OUT=wg0-mullvad). A mark needs CAP_NET_ADMIN: the daemon (uid 0) sets it on the relay
  transport; kernel WireGuard sends without a socket, `skuid` never matches there
- every interface, the tunnel too: the 2026-11-01 flow left via wg0-mullvad
- placed before the DNS rules: an excluded program's own DNS is caught here too
- not used: `meta cgroup <classid>` (Mullvad's net_cls id is an internal value; the ct
  mark is the documented one)

## forward

| # | comment | match | action | prefix |
|---|---|---|---|---|
| 1 | fwd_est | ct established,related | accept | - |
| 2 | fwd_vm_new | virbr0 -> wg0-mullvad, ct new | accept + log | HFW-FWD-VM-NEW |
| 3 | fwd_vm_vpn | virbr0 -> wg0-mullvad | accept | - |
| 4 | fwd_vm_cross | virbr0 -> virbr0 | accept | - |
| 5 | fwd_vm_lan | virbr0 -> anything else (LAN, uplink) | deny | HFW-FWD-VM-LAN |
| 6 | fwd_in | any other new forwarded flow | deny | HFW-FWD-IN |

## input (log only - firewalld zones decide)

| # | comment | match | action | prefix |
|---|---|---|---|---|
| 1 | in_est | ct established,related | pass | - |
| 2 | in_lo | iif lo | pass | - |
| 3 | in_vm | iif virbr0 | pass (libvirt zone decides) | - |
| 4 | in_ndp6 | icmpv6 RA, NS, NA, MLD query | pass | - |
| 5 | in_dhcp4 | udp 67 -> 68 | pass | - |
| 6 | in_noise | not wg0-mullvad, broadcast / multicast | pass + sampled log | HFW-IN-NOISE |
| 7 | in_vpn | iif wg0-mullvad, ct new | pass + log | HFW-IN-VPN |
| 8 | in_lan | anything else, ct new | pass + log | HFW-IN-LAN |

`*-NEW` = audit of allowed flows via the tunnel (sectop):
- `ct new` = packets of a flow before its first reply: 1 line per TCP connect,
  1+ per UDP flow (more if the peer never answers, rate limit applies)
- same verdict as the next rule (`out_trusted` / `fwd_vm_vpn`), logging only
- DNS to vpn_dns4 is counted (`out_dns_vpn`), not logged
- `hostfw report`: per-rule totals only, not in top flows

`deny` = count + log + `jump enforce`:
- observe: `enforce` empty -> accepted, logged only
- enforce: `reject with icmpx admin-prohibited` -> app fails fast, no hang

`out_noscope` (2026-11-03): GNOME Shell's own unit (`org.gnome.Shell@<x>.service`) is no
app. An app GNOME starts lands there when its launcher forks before GNOME moves it into
its scope (Brave rpm; fix: appunit section). Its flows have no program name anywhere.
- `jump deny_out_noscope` (not goto): count + log + `jump enforce_noscope`; observe
  returns and the rest of output decides as for any flow
- own switch: `hostfw noscope observe | enforce`, boot mode `/etc/hostfw/noscope`
  (fresh install: observe; this host: enforce). The global `enforce` does not touch it
- set `noscope_cg`: nft resolves a path to the cgroup id when the element is added, a
  new login = new id. hostfw-noscope.service (root, CAP_NET_ADMIN only) looks every 5 s
  (paths + inode, files only) and rewrites the set in one transaction on a change.
  Gap: up to 5 s after a login. A stale id matches nothing (fails open, never wrong)
- not a guard against malware running as my user: a process can move itself to another
  cgroup of mine. It closes the "app hides in GNOME Shell's cgroup" hole
- netfilter: "The cgroupv2 support for nftables was designed to be used with maps"
  (Pablo Neira Ayuso, netfilter-devel 2022-03, "Support for loading firewall rules with
  cgroup(v2) expressions early")

## Never-leave ports

| group | ports |
|---|---|
| DNS / DoT | tcp/udp 53, 853 (only vpn_dns4 via tunnel, or own VMs) |
| NetBIOS NS / DGM | udp 137, 138 |
| SSDP / UPnP | udp 1900 |
| WS-Discovery | udp 3702, tcp 5357, 5358 |
| NAT-PMP / PCP (router port mapping) | udp 5351 |
| mDNS | udp 5353 |
| LLMNR | tcp/udp 5355 |
| Steam LAN discovery / streaming | udp 27036, tcp 27036, 27037 |
| FTP / TFTP | tcp 21 / udp 69 |
| rpcbind / NFS | tcp/udp 111, 2049 |
| SMB | tcp 139, 445 |
| AFP | tcp 548 |
