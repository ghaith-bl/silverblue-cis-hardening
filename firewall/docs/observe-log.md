# hostfw observe log

Observe week 2026-10-18 - 2026-10-19 (ended early). Boot mode: enforce since 2026-10-19.
Counters reset every boot -> use `hostfw report` (reads kernel journal).

## Expected (not leaks)
- OUT-KS: host traffic to kill switch dummy while tunnel down.
  v6 default route goes to dummy (metric 95). Proton client hits DNS/CDN on 443 before tunnel up.
- OUT-LAN udp 547 / IN-LAN udp 546: NM DHCPv6. Fixed: IPv6 disabled on wifi connection (2026-10-19).
- IN-NOISE: LAN device (TV) UDP 25860 broadcast. Pending: move to guest wifi.
- OUT-LEAK on connect: Proton pre-connect probes, tcp 443/7770/8443, uid 1000, to target server.
  Same as OpenVPN TCP DefaultPorts in clientconfig.json. Exception added 2026-10-19 (out_probe).
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
- connect after long offline (expired cert / stale list) in enforce

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
- 2026-10-19 observe week ended early: boot mode enforce (rollback 5, confirmed, curl OK).
- 2026-10-19 user unit protonvpn-connect.service (oneshot, Restart=on-failure 15s,
  WantedBy=default.target). Reboot test: connected at login ~15 s, mode enforce.
  Pre-connect window (all rejected): OUT-LEAK 4, OUT-DNS 22, OUT-KS 1, IN-NOISE 12.
  OUT-LEAK = uid 1000 tcp/443 to 8.8.8.8, 8.8.4.4, 9.9.9.11, 149.112.112.11
  (likely Proton DoH fallback while API blocked). Nothing left outside tunnel.
  Server list outdated at connect -> refresh blocked, connected from cache;
  serverlist.json refreshed via tunnel at 12:19.
- 2026-10-19 firewalld-cleanup.sh --permanent: drop zone rich rules 192.168.122.0/24 accept
  + 127.0.0.1 accept removed (runtime + permanent). Backup: ~/drop.xml.bak-2026-10-19.
  After --reload: drop zone rich rules empty, hostfw mode enforce, curl OK.
- 2026-10-19 VM check after drop zone cleanup: host -> VM ssh OK, VM internet OK (tunnel).
- 2026-10-19 BrokenPipeError fixed: PY_SET / PY_COUNTERS restore SIGPIPE default
  (Python docs, "Note on SIGPIPE"). `hostfw status | head` clean. Reinstalled.

## 2026-10-19 audit logging (sectop)
- out_new / fwd_vm_new: new flows via tunnel (ct new), accept + log, 5/s burst 50.
  Same verdict as before, logging only. For the sectop audit view (who goes out).
- HFW-FWD-KS renamed HFW-FWD-VM-KS: log kind now = counter name fwd_vm_ks (naming contract).
- report: top flows skip *-NEW (per-rule totals still count them).
- Journal before: 1.5G (journald default cap: 10% of /var, max 4G). Check growth after 1 day.
- Live test (enforce, rollback 5): curl via tunnel OK, out_new +1, log UID=1000 OUT=proton0,
  curl --interface wlo1 rejected. Confirmed, installed.

## 2026-10-19 other wifi (<wifi profile>)
- New profile = ipv6.method auto -> DHCPv6 solicit from wlo1 every few s (OUT-LAN, udp 546 -> ff02::1:2 547).
  Fixed: `nmcli connection modify <wifi profile> ipv6.method disabled`, then reconnect. Solicits stopped.
- NetworkManager.conf(5) [connection] defaults do not include ipv6.method -> disable per profile,
  every new wifi. Planned: sectop posture check (all wifi profiles ipv6 disabled).
- OUT-KS v6 drops: chronyd NTP, uid 1000 tcp/443. Source fdeb:446c:912d:8da:: = ULA on
  pvpnksintrf0 (Proton KS dummy, also 100.85.0.1). Apps try v6, v6 default -> dummy. Expected.
- Wifi reconnect: WireGuard transport 100.85.0.1:39567 -> endpoint:443 (no uid) dropped at
  pvpnksintrf0, handshake stale 6 min (sectop crit "handshake stale"). Fail closed, no leak.
  Open: does the Proton CLI recover alone after a network change, or reconnect needed.
