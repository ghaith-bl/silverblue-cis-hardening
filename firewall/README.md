# firewall/ - hostfw

Host egress filter + inbound logging for Silverblue 44.
Own nftables table `inet hostfw`, next to firewalld. Zero trust LAN: router only.

## Why

- firewalld zones = ingress only. no HOST -> zone policies -> egress unfiltered
- ProtonVPN kill switch = routing, not a packet filter:
  - `pvpnksintrf0` / `pvpnksintrf1` dummy (index varies by client), default route metric 98 (blackhole)
  - `<endpoint> via <router> dev wlo1` host route for the VPN server
  - `ip rule 31505: not fwmark 0xea13b2c lookup <wg table>` -> everything else via proton0
- `ip rule 31504: lookup main suppress_prefixlength 0` -> non-default routes in main win
  -> LAN (192.168.8.0/24) reachable from host and VMs, outside the tunnel
- IPv6: no global addr on wlo1, none in tunnel, v6 default -> dummy. no v6 internet leak,
  but ULA / link-local LAN open both ways
- rootless Podman / kind: traffic = host output from `pasta` (no host bridge, no container IPs)

## Layers

| table | owner | role |
|---|---|---|
| `inet firewalld` | firewalld | ingress (zones: drop, libvirt) |
| `inet hostfw` | this repo | egress, forward, inbound logging |
| `ip/ip6 libvirt_network` | libvirt | VM NAT / forward |
| `ip nm-wg-proton0` | NetworkManager | WireGuard anti-spoof + fwmark |

- separate base chains on the same hook all run. drop/reject = final. accept = next table decides
- -> hostfw can only tighten, never open a hole
- hostfw chains at `priority filter - 10` (firewalld: `filter + 10`)

## Files

```
hostfw.nft                    ruleset (sets, counters, chains)
hostfw.sh                     apply | observe | enforce | confirm | sync | router-open
                              status | counters | report | remove | install | uninstall
hostfw.service                boot unit (own unit - not nftables.service)
nm-dispatcher/90-hostfw-sync  re-sync wg_fwmark + router4 on VPN / network up
firewalld-cleanup.sh          drop-zone legacy rich rules (runtime, then --permanent)
docs/rules.md                 every rule, prefix, counter (sectop contract)
```

Installed paths:

```
/usr/local/sbin/hostfw
/etc/hostfw/hostfw.nft
/etc/hostfw/mode                                   observe | enforce
/etc/systemd/system/hostfw.service
/etc/NetworkManager/dispatcher.d/90-hostfw-sync
```

## Modes

- observe: denied traffic counted + logged, still passes
- enforce: denied traffic rejected (`icmpx admin-prohibited`, apps fail fast)
- kill switch hits (`HFW-OUT-KS`, `HFW-FWD-VM-KS`): always dropped
- new flows via tunnel (`HFW-OUT-NEW`, `HFW-FWD-VM-NEW`): allowed, logged (audit, sectop)
- switch = flush/add one rule in chain `enforce`. live, atomic, no reload

## Workflow

### 0. pre-check

```bash
sudo nft list tables                # no stale "inet hostfw"
sudo wg show proton0 fwmark         # VPN connected
```

### 1. firewalld cleanup (runtime)

```bash
sudo ./firewalld-cleanup.sh         # undo: sudo firewall-cmd --reload
```

### 2. load runtime-only, observe

```bash
sudo ./hostfw.sh apply --rollback 5
sudo ./hostfw.sh status
sudo ./hostfw.sh confirm            # keep it (else table deleted after 5 min)
```

- lost on reboot (runtime only)
- after VPN reconnect / server change / new network: `sudo ./hostfw.sh sync`
  (dispatcher does this automatically once installed)

### 3. coexistence checks

```bash
sudo firewall-cmd --reload && sudo nft list table inet hostfw >/dev/null && echo survives-firewalld-reload
sudo virsh net-destroy default && sudo virsh net-start default && sudo nft list table inet hostfw >/dev/null && echo survives-libvirt
# VPN: disconnect / connect other server, then:
sudo ./hostfw.sh sync && sudo ./hostfw.sh status
```

- firewalld reload reverts step 1 runtime changes -> rerun cleanup if needed

### 4. observe ~1 week

```bash
sudo ./hostfw.sh report             # default: 7 days ago, top 40
sudo ./hostfw.sh report "1 day ago" 80
sudo ./hostfw.sh counters
journalctl -k -f -g '^HFW-'         # live
```

Watch for:

- `HFW-OUT-LEAK` udp from uid 0 -> WireGuard mark mismatch -> `sync`, check fwmark changes
- `HFW-OUT-LEAK` from uid 1000 before VPN connects -> protonvpn-app API outside tunnel?
- `HFW-OUT-DNS` -> app with hardcoded resolver (inside tunnel = not a leak, still bypasses resolved)
- `HFW-OUT-LAN` udp 547 -> ff02::1:2 -> NM DHCPv6 solicit (expected, router uses SLAAC)
- `HFW-OUT-LAN` IGMP -> multicast membership reports (expected, MLDv2 allowed for NDP)
- `HFW-OUT-DISCO` brave / steam -> expected, keep blocked
- `HFW-IN-LAN` -> who on the LAN tries to reach me
- `HFW-OUT-KS` -> app traffic while tunnel down
- `HFW-OUT-NEW` -> every new flow via tunnel (allowed): who talks to what. Not in report top flows

Decide exceptions from data, not guesses.

### 5. enforce (with rollback)

```bash
sudo ./hostfw.sh enforce            # auto-revert to observe in 3 min
# run tests below
sudo ./hostfw.sh confirm
```

### 6. make permanent

```bash
sudo ./firewalld-cleanup.sh --permanent
sudo ./hostfw.sh install            # copies files, enables unit (mode from live state)
sudo systemctl reboot
sudo hostfw status                  # after reboot
```

## Tests (enforce)

Positive - must work:

```bash
curl -sI https://fedoraproject.org | head -1
sudo hostfw counters | grep -E 'out_new|fwd_vm_new'     # out_new grows with new flows
journalctl -k -n 3 --no-pager -g '^HFW-OUT-NEW'          # UID=1000, OUT=proton0
ping -c1 "$(ip -4 route show default dev wlo1 | awk '{print $3; exit}')"
sudo virsh start <vm>; ssh <vm>           # VM: curl -sI https://fedoraproject.org
podman run --rm registry.fedoraproject.org/fedora-minimal curl -sI https://fedoraproject.org
kubectl get nodes                          # kind
# Steam offline game, Brave, Firefox
# VPN disconnect -> connect other server -> sync (or dispatcher) -> browse
```

Negative - must fail fast + log (`dig` from toolbox, shares host netns):

```bash
toolbox run sudo dnf -y install bind-utils          # once, if dig missing
toolbox run dig +time=2 @1.1.1.1 example.com       # HFW-OUT-DNS
toolbox run dig +time=2 @192.168.8.1 example.com   # HFW-OUT-DNS
curl -m5 --interface wlo1 https://example.com      # HFW-OUT-LEAK
curl -m5 http://192.168.8.1                        # HFW-OUT-LAN (until router-open)
ping -c1 -W2 192.168.8.<other-device>              # HFW-OUT-LAN
# inside VM: ping -c1 192.168.8.1                  # HFW-FWD-VM-LAN
```

Router web UI:

```bash
sudo hostfw router-open 10          # tcp 80,443 to gateway, expires by itself
```

## Undo

```bash
sudo ./hostfw.sh observe            # stop rejecting, keep logging
sudo ./hostfw.sh remove             # delete runtime table
sudo ./hostfw.sh uninstall          # unit + dispatcher + /usr/local/sbin/hostfw
sudo firewall-cmd --reload          # revert runtime firewalld cleanup
```

## Known limits

- netfilter has no program names: UID only (Flatpak apps, pasta = 1000; WireGuard, NM, chronyd = 0)
- logs rate-limited -> counters exact, logs = samples (*-NEW: 5/s burst 50)
- *-NEW = allowed flows, logged only: no per-program control (netfilter has no program names)
- table reload (`apply`, `systemctl reload`) resets counters + router-open entries
- boot in enforce: WireGuard handshake rejected until dispatcher syncs `wg_fwmark` on proton0 up
  (wg retries every 5 s) -> verify after install
- dispatcher runs nft from the NM dispatcher SELinux domain -> after first reconnect:
  `sudo ausearch -m avc -ts recent | grep -i hostfw`
- L2 (ARP) not covered by `inet` table
- new libvirt network / rootful containers -> add the bridge to `if_vm` + `if_trusted`
- `lan_allow4` needs static IPs (router DHCP reservation)
- `router4` = current gateway only; other networks: `sync` / dispatcher

## Verify against docs

- nftables wiki - hooks, priorities, multiple base chains: https://wiki.nftables.org/wiki-nftables/index.php/Netfilter_hooks
- nftables wiki - sets, counters, logging, reject: https://wiki.nftables.org/
- nft(8): https://www.netfilter.org/projects/nftables/manpage.html
- firewalld zones / policies / reload: https://firewalld.org/documentation/
- NetworkManager-dispatcher(8): https://networkmanager.dev/docs/api/latest/NetworkManager-dispatcher.html
- systemd-run(1), systemd.unit(5)
