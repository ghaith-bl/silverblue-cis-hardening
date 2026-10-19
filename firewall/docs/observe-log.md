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
- reboot path: tested 2026-10-19, OK
- probe exception, then enforce test again
- `hostfw status | head` -> BrokenPipeError (handle SIGPIPE)

## 2026-10-19 probe exception
- proton_entry4 (908 EntryIPs) + proton_probe_tcp (443,7770,8443) filled by `hostfw sync`.
- Test: connect -> out_probe +3. Works.
- Connect fail once: server "session not found" (86203) right after server list refresh. Retry OK. Proton side.
- After disconnect: client hits Proton API, public DoH/DNS IPs, AWS on tcp 443 to refresh server list.
  In enforce this is blocked -> must test connect from cached list. No exception for these (too broad).
- Enforce test (rollback 5 min): connected -> OK. Disconnect -> no internet (fail closed).
  Connect from cached server list -> OK ("Timed out ... tasks" = blocked list refresh, harmless).
- Open: connect after long offline (expired cert / stale list) in enforce.
- 2026-10-19 reboot test passed: hostfw.service at boot, mode observe, wg_fwmark restored,
  proton_probe 908 IPs from client cache, router4 set.
- Gap: Proton CLI does not connect at boot, kill switch "standard" not active at boot.
  Boot -> manual connect = unprotected in observe. Closed by hostfw boot mode enforce.
