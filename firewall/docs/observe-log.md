# hostfw observe log

Observe week started 2026-10-18. Mode: observe.
Counters reset every boot -> use `hostfw report` (reads kernel journal).

## Expected (not leaks)
- OUT-KS: host traffic to kill switch dummy while tunnel down.
  v6 default route goes to dummy (metric 95). Proton client hits DNS/CDN on 443 before tunnel up.
- OUT-LAN udp 547 / IN-LAN udp 546: NM DHCPv6. Fixed: IPv6 disabled on wifi connection (2026-10-19).
- IN-NOISE: LAN device (TV) UDP 25860 broadcast. Pending: move to guest wifi.
- OUT-LEAK on connect: Proton pre-connect probes, tcp 443/7770/8443, uid 1000, to target server.
  Same as OpenVPN TCP DefaultPorts in clientconfig.json. Needs exception before enforce.
- out_wg +1 per connect (handshake by fwmark). fwmark 0xea13b2c constant across servers, days, clients.

## Data gaps
- 2026-10-19 11:17-11:28: no VPN (client migration). out_leak here = expected (browser QUIC, NTP).

## Changes during observe
- 2026-10-19: Proton flatpak -> proton-vpn-cli 1.0.5. KS dummy pvpnksintrf1 -> pvpnksintrf0.
  if_killsw + KS_IFACES now accept both.
- 2026-10-19: router4 no longer picks KS dummy gateway (100.85.0.1).

## Tests passed
- reconnect: endpoint changes, out_wg +1, out_leak = probes only
- survives `firewall-cmd --reload` and `virsh net-destroy/net-start default`
- CLI disconnect: tunnel + dummy removed, default route via router only
- CLI connect: proton0 + pvpnksintrf0 back

## Open
- reboot path not tested
- probe exception, then enforce test again
- `hostfw status | head` -> BrokenPipeError (handle SIGPIPE)
