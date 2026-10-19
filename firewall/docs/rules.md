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
| `if_trusted` | lo, proton0, virbr0 | egress allowed, minus never-leave rules |
| `if_vm` | virbr0 | libvirt bridges |
| `if_killsw` | pvpnksintrf0, pvpnksintrf1 | ProtonVPN kill switch dummy |
| (none) | wlo1, enp44s0, anything new | uplink - router + tunnel transport only |

## Dynamic sets

| set | filled by | content |
|---|---|---|
| `wg_fwmark` | `hostfw sync` / NM dispatcher | `wg show proton0 fwmark` |
| `router4` | `hostfw sync` / NM dispatcher | IPv4 default gateways, not tunnel / kill switch |
| `router_admin4` | `hostfw router-open [MIN]` | gw . 80, gw . 443 with timeout |
| `lan_allow4` | edit `hostfw.nft` | static `ip . proto . port` exceptions |

## output

| # | comment | match | action | prefix |
|---|---|---|---|---|
| 1 | out_est | ct established,related | accept | - |
| 2 | out_lo | oif lo | accept | - |
| 3 | out_dns_vpn | tcp/udp 53,853 -> 10.2.0.1 via proton0 | accept, counted | - |
| 4 | out_dns_vm | tcp/udp 53,853 via virbr0 | accept | - |
| 5 | out_dns | any other tcp/udp 53,853 | deny | HFW-OUT-DNS |
| 6 | out_disco | udp 137,138,1900,3702,5351,5353,5355,27036 / tcp 5355,5357,5358,27036,27037 | deny | HFW-OUT-DISCO |
| 7 | out_share | tcp 21,111,139,445,548,2049 / udp 69,111,2049, not via virbr0 | deny | HFW-OUT-SHARE |
| 8 | out_new | oif proton0, ct new | accept + log | HFW-OUT-NEW |
| 9 | out_trusted | oif in if_trusted | accept | - |
| 10 | out_ks | oif in if_killsw | drop (always) | HFW-OUT-KS |
| 11 | out_wg | meta mark in wg_fwmark | accept, counted | - |
| 12 | out_probe | uid 1000 tcp proton_probe_tcp -> proton_entry4 | accept, counted | - |
| 13 | out_dhcp4 | udp 68 -> 67 | accept | - |
| 14 | out_router_icmp | icmp echo-request -> router4 | accept | - |
| 15 | out_router_admin | ip . tcp port in router_admin4 | accept + log | HFW-OUT-ROUTER-ADMIN |
| 16 | out_lan_allow | ip . proto . port in lan_allow4 | accept + log | HFW-OUT-LAN-ALLOW |
| 17 | out_ndp6 | icmpv6 RS, NS, NA, MLDv2 report | accept | - |
| 18 | out_lan | daddr private / link-local / CGNAT / multicast / broadcast | deny | HFW-OUT-LAN |
| 19 | out_leak | anything else on uplink | deny | HFW-OUT-LEAK |

## forward

| # | comment | match | action | prefix |
|---|---|---|---|---|
| 1 | fwd_est | ct established,related | accept | - |
| 2 | fwd_vm_new | virbr0 -> proton0, ct new | accept + log | HFW-FWD-VM-NEW |
| 3 | fwd_vm_vpn | virbr0 -> proton0 | accept | - |
| 4 | fwd_vm_cross | virbr0 -> virbr0 | accept | - |
| 5 | fwd_vm_ks | virbr0 -> kill switch | drop (always) | HFW-FWD-VM-KS |
| 6 | fwd_vm_lan | virbr0 -> anything else (LAN, uplink) | deny | HFW-FWD-VM-LAN |
| 7 | fwd_in | any other new forwarded flow | deny | HFW-FWD-IN |

## input (log only - firewalld zones decide)

| # | comment | match | action | prefix |
|---|---|---|---|---|
| 1 | in_est | ct established,related | pass | - |
| 2 | in_lo | iif lo | pass | - |
| 3 | in_vm | iif virbr0 | pass (libvirt zone decides) | - |
| 4 | in_ndp6 | icmpv6 RA, NS, NA, MLD query | pass | - |
| 5 | in_dhcp4 | udp 67 -> 68 | pass | - |
| 6 | in_noise | not proton0, broadcast / multicast | pass + sampled log | HFW-IN-NOISE |
| 7 | in_vpn | iif proton0, ct new | pass + log | HFW-IN-VPN |
| 8 | in_lan | anything else, ct new | pass + log | HFW-IN-LAN |

`*-NEW` = audit of allowed flows via the tunnel (sectop):
- `ct new` = packets of a flow before its first reply: 1 line per TCP connect,
  1+ per UDP flow (more if the peer never answers, rate limit applies)
- same verdict as the next rule (`out_trusted` / `fwd_vm_vpn`), logging only
- DNS to 10.2.0.1 is counted (`out_dns_vpn`), not logged
- `hostfw report`: per-rule totals only, not in top flows

`deny` = count + log + `jump enforce`:
- observe: `enforce` empty -> accepted, logged only
- enforce: `reject with icmpx admin-prohibited` -> app fails fast, no hang

## Never-leave ports

| group | ports |
|---|---|
| DNS / DoT | tcp/udp 53, 853 (only 10.2.0.1 via tunnel, or own VMs) |
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
