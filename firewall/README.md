# firewall/ - hostfw

Host egress filter + inbound logging for Silverblue 44.
Own nftables table `inet hostfw`, next to firewalld. Zero trust LAN: router only.

## Why

- firewalld zones = ingress only. no HOST -> zone policies -> egress unfiltered
- Mullvad kill switch = own nftables table `inet mullvad` (policy drop on input, output,
  forward), kept while disconnected by lockdown mode. A second, independent layer:
  hostfw does not rely on it and never edits it
- Mullvad routing: `ip rule 32765: not fwmark 0x6d6f6c65 lookup 1836018789` (= 0x6d6f6c65)
  -> everything else via wg0-mullvad; marked traffic (relay transport) via the uplink
- `ip rule 32764: lookup main suppress_prefixlength 0` -> non-default routes in main win
  -> the LAN subnet routed outside the tunnel (Mullvad blocks it while Allow LAN
  is off, hostfw blocks it too: out_lan)
- IPv6: no global addr on the uplink -> no v6 internet leak, but ULA / link-local LAN open both ways
- rootless Podman / kind: traffic = host output from `pasta` (no host bridge, no container IPs)

## Layers

| table | owner | role |
|---|---|---|
| `inet firewalld` | firewalld | ingress (zones: drop, libvirt) |
| `inet hostfw` | this repo | egress, forward, inbound logging |
| `inet mullvad` | mullvad-daemon | kill switch (lockdown), DNS, relay transport, split tunnel marks |
| `inet kvmlan` | harden-workstation.sh kvmlan | marks host <-> VM packets on `virbr0` so Mullvad's LAN block lets them pass (no accept / drop) |
| `ip/ip6 libvirt_network` | libvirt | VM NAT / forward |

- separate base chains on the same hook all run. drop/reject = final. accept = next table decides
- -> hostfw can only tighten, never open a hole
- hostfw chains at `priority filter - 10` (firewalld: `filter + 10`)

## Files

```
hostfw.nft                    ruleset (sets, counters, chains)
hostfw.sh                     apply | observe | enforce | confirm | sync | api-update
                              router-open | status | counters | report | remove | install
                              uninstall
hostfw.service                boot unit (own unit - not nftables.service)
hostfw-noscope.py             watcher: GNOME Shell's cgroup id -> set noscope_cg (out_noscope)
hostfw-noscope.service        its unit (root, CAP_NET_ADMIN only, every 5 s)
nm-dispatcher/90-hostfw-sync  re-sync router4 (+ wg_fwmark while the tunnel is up) on network up
hostfw.local.example         template for /etc/hostfw/local.conf (this machine's addresses)
firewalld-cleanup.sh          drop-zone legacy rich rules (runtime, then --permanent)
docs/rules.md                 every rule, prefix, counter (sectop contract)
```

Installed paths:

```
/usr/local/sbin/hostfw
/etc/hostfw/hostfw.nft
/etc/hostfw/mode                                   observe | enforce
/etc/hostfw/noscope                                observe | enforce (out_noscope only)
/usr/local/sbin/hostfw-noscope
/etc/systemd/system/hostfw-noscope.service         WantedBy=hostfw.service
/etc/hostfw/local.conf                             vpn_dns4, vpn_api4 (root 0600, never in git)
/etc/systemd/system/hostfw.service
/etc/NetworkManager/dispatcher.d/90-hostfw-sync
```

## Modes

- observe: denied traffic counted + logged, still passes
- enforce: denied traffic rejected (`icmpx admin-prohibited`, apps fail fast)
- new flows via tunnel (`HFW-OUT-NEW`, `HFW-FWD-VM-NEW`): allowed, logged (audit, sectop)
- switch = flush/add one rule in chain `enforce`. live, atomic, no reload
- out_noscope (flows from GNOME Shell's cgroup): own switch, chain `enforce_noscope`,
  `hostfw noscope observe | enforce | status` (docs/rules.md)

## Workflow

### 0. pre-check

```bash
sudo nft list tables                # no stale "inet hostfw"
sudo wg show wg0-mullvad fwmark     # VPN connected: 0x6d6f6c65
sudo test -s /etc/hostfw/local.conf && echo ok   # else: hostfw.local.example
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
- new network: `sudo ./hostfw.sh sync` (dispatcher does this automatically once installed)

### 3. coexistence checks

```bash
sudo firewall-cmd --reload && sudo nft list table inet hostfw >/dev/null && echo survives-firewalld-reload
sudo virsh net-destroy default && sudo virsh net-start default && sudo nft list table inet hostfw >/dev/null && echo survives-libvirt
# VPN: mullvad reconnect, then:
sudo ./hostfw.sh status
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

- `HFW-OUT-LEAK` with `MARK=` and no uid -> WireGuard mark mismatch -> `sync`, check `wg show wg0-mullvad fwmark`
- `HFW-OUT-LEAK` from uid 0 tcp/443 while not connected -> Mullvad API on a new address, or its DoH
  fallback: `mullvad disconnect`, `sudo hostfw api-update` (shows old / new, asks),
  `mullvad connect`. sectop warns when the two differ (seen while not connected).
  DoH or other ports from uid 0 -> API access not Direct: `mullvad api-access get`
- `HFW-OUT-LEAK` from uid 1000 -> program around the tunnel (or split tunneling)
- `HFW-OUT-DNS` -> app with hardcoded resolver (inside tunnel = not a leak, still bypasses resolved)
- `HFW-OUT-LAN` udp 547 -> ff02::1:2 -> NM DHCPv6 solicit (expected, router uses SLAAC)
- `HFW-OUT-LAN` IGMP -> multicast membership reports (expected, MLDv2 allowed for NDP)
- `HFW-OUT-DISCO` brave / steam -> expected, keep blocked
- `HFW-IN-LAN` -> who on the LAN tries to reach me
- `HFW-OUT-NEW` -> every new flow via tunnel (allowed): who talks to what. Not in report top flows
- `HFW-OUT-NOSCOPE` -> a process in GNOME Shell's cgroup opened a flow (an app without its
  own scope, or GNOME Shell itself: weather, extensions). sectop names it
  (org.gnome.Shell/<comm>). Before `hostfw noscope enforce`: none for the observe days,
  or each one explained

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
journalctl -k -n 3 --no-pager -g '^HFW-OUT-NEW'          # UID=1000, OUT=wg0-mullvad
UP=$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); exit }}')
GW=$(ip -4 route show default dev "$UP" | awk '{print $3; exit}')     # router
ping -c1 "$GW"
sudo virsh start <vm>; ssh <vm>           # VM: curl -sI https://fedoraproject.org
podman run --rm registry.fedoraproject.org/fedora-minimal curl -sI https://fedoraproject.org
kubectl get nodes                          # kind
# Steam offline game, Brave, Firefox
# mullvad reconnect -> browse; mullvad relay update while disconnected -> out_wg grows, no OUT-LEAK
```

Negative - must fail fast + log (`dig` from toolbox, shares host netns):

```bash
toolbox run sudo dnf -y install bind-utils          # once, if dig missing
# UP / GW from the positive tests (uplink, router)
toolbox run dig +time=2 @192.0.2.1 example.com     # HFW-OUT-DNS (any resolver outside the tunnel)
toolbox run dig +time=2 @"$GW" example.com         # HFW-OUT-DNS
curl -m5 --interface "$UP" https://example.com     # HFW-OUT-LEAK
curl -m5 "http://$GW"                              # HFW-OUT-LAN (until router-open)
ping -c1 -W2 <other LAN device>                    # HFW-OUT-LAN
# inside VM: ping -c1 <router>                     # HFW-FWD-VM-LAN
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

## VPN: Mullvad

Setup, settings and how it fits hostfw: [../docs/mullvad.md](../docs/mullvad.md).

- connect: mullvad-daemon (system unit, auto-connect, lockdown). Relay transport has the
  mark (`out_wg`); its API calls outside the tunnel do not: `out_vpn_api` allows uid 0
  tcp/443 to the address `inet mullvad` allows (`vpn_api4`), nothing else. API access
  in the app = Direct only (docs/deviations.md)
- DNS content blockers on -> other resolver address -> add it to `vpn_dns4` in
  /etc/hostfw/local.conf first, then `sudo hostfw sync` (`resolvectl dns wg0-mullvad`)
- router web UI: `hostfw router-open` + `mullvad lan set allow` for the time, then `block`

## Known limits

- netfilter has no program names: UID only (Flatpak apps, pasta = 1000; chronyd 994,
  systemd-resolved 990; mullvad-daemon, NM = 0; kernel WireGuard transport: no uid)
- logs rate-limited -> counters exact, logs = samples (*-NEW: 5/s burst 50)
- *-NEW = allowed flows, logged only: no per-program control (netfilter has no program names)
- table reload (`apply`, `systemctl reload`) resets counters + router-open entries
- `wg_fwmark` ships Mullvad's mark: boot in enforce connects without a sync. A changed
  mark (new Mullvad release) = OUT-LEAK with `MARK=` until `sync` with the tunnel up
- dispatcher runs nft from the NM dispatcher SELinux domain -> after first reconnect:
  `sudo ausearch -m avc -ts recent | grep -i hostfw`
- split tunneling (`mullvad-exclude`, setuid root) is rejected by hostfw in every mode
  (out_split, 2026-11-05); VM bridges keep the kvmlan marks
- out_noscope: up to 5 s after a login the new GNOME Shell cgroup is not in the set yet;
  table reload empties the set until the watcher's next look (it is restarted)
- L2 (ARP) not covered by `inet` table
- new libvirt network / rootful containers -> add the bridge to `if_vm` + `if_trusted`
  and to `MULLVAD_VM_BRIDGES` (kvmlan section), else Mullvad blocks it
- `lan_allow4` needs static IPs (router DHCP reservation)
- `router4` = current gateway only; other networks: `sync` / dispatcher

## Verify against docs

- nftables wiki - hooks, priorities, multiple base chains: https://wiki.nftables.org/wiki-nftables/index.php/Netfilter_hooks
- nftables wiki - sets, counters, logging, reject: https://wiki.nftables.org/
- nft(8): https://www.netfilter.org/projects/nftables/manpage.html
- cgroupv2 match, ids resolved at load, refresh on updates, use with maps (netfilter-devel,
  2022-03): https://lore.kernel.org/all/YkDXwaPwYf8NgKT+@salvia/T/
- firewalld zones / policies / reload: https://firewalld.org/documentation/
- NetworkManager-dispatcher(8): https://networkmanager.dev/docs/api/latest/NetworkManager-dispatcher.html
- systemd-run(1), systemd.unit(5)
- Mullvad app security (tunnel states, firewall marks, API access): https://github.com/mullvad/mullvadvpn-app/blob/master/docs/security.md
- Mullvad split tunneling marks (ct mark 0xf41, mark 0x6d6f6c65): https://mullvad.net/help/split-tunneling-with-linux-advanced
