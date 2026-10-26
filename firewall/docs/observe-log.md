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
- connect with a too old server list in enforce: happened 2026-10-26 (section below).
  Escape hatch in firewall/README.md. Planned: exception for the connect unit only.

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

## 2026-10-25 offline: connect loop
- Offline at login (or wifi late): `protonvpn connect` failed every 15 s
  (Restart=on-failure, RestartSec=15, no limit), each try left journal lines, and a
  manual disconnect did not stop it: the unit kept trying. Seen 2026-10-20 cold boot
  (3 fails before wifi was up).
- Fix: ExecStartPre=protonvpn-wait-uplink: waits until a wifi / ethernet device is
  connected (nmcli device state), event-driven via nm-online(1). Not nm-online alone:
  "an active connection" can be the KS dummy (default route). Connect fails with an
  uplink: retry 15 s doubling to 4 min (RestartSteps=4, RestartMaxDelaySec=4min,
  systemd.service(5), v254+; host systemd 259).
- Test 2026-10-25 (installed unit): VPN disconnected, wifi off, unit restarted ->
  activating (start-pre), one journal line, no connect attempt. Wifi on -> uplink seen
  ~10 s later, "Server list is outdated" refresh + connect 40 s, Finished. No failed
  attempt, 2 lines from the wait. nmcli after: `dummy:connected` (KS dummy counts as a
  connected device, so the wifi / ethernet check is needed, not nm-online alone).

## 2026-10-20 cold boot (off ~13 h) + journal check
- Wifi up late. Proton CLI failed 3x (10:38-10:39, "Connection failed"), connected on try 4
  at 10:40:27 (Restart=on-failure, RestartSec=15): ~2 min 40 s after login. No action.
- Pre-connect: OUT-LEAK 4 (DoH fallback 149.112.112.11, 9.9.9.11, 8.8.8.8, 8.8.4.4, tcp/443,
  uid 1000), all rejected (boot mode enforce). Same as 2026-10-19.
- "Server list is outdated": update blocked pre-connect (by design). serverlist.json
  refreshed ~1.5 min after connect (via tunnel). No drift.
- 2026-10-19 17:50:05 OUT-LEAK 2 (uid 1000, wlo1, tcp/443, 2 addresses) = my live test
  `curl --interface wlo1`, 1 s after enforce -> rejected. Not a leak.
- Journal 1.5G -> 1.7G. out_new = 0.8% of entries (boot 2026-10-19 17:09: 3440 of 433116).
  93% = audit records (402826) from sectop polling as root (rule root_cmds). Fix in sectop
  (fewer commands, then privilege split). journald cap unchanged. Closed.

## 2026-10-26 enforce: connect fails, server list too old
- protonvpn-connect.service: 7 tries 12:08-12:35, each "Server list is outdated,
  updating..." then "Connection failed" / "Network connectivity issues detected".
  11:50: proton0 up, handshake never, transport to pvpnksintrf0 dropped. Later Proton
  fully disconnected (no proton0, default via wlo1) -> enforce = no internet. No leak.
- Pre-connect the CLI refreshes the server list from the Proton API outside the tunnel:
  system DNS blocked (out_dns), then its fallbacks tcp/443 uid 1000 to public DoH
  (8.8.x, 9.9.x, 149.112.x) and to fronts (3.75.x.x) -> OUT-LEAK, rejected. Before
  2026-10-26 it connected from the cached list and refreshed via the tunnel; this time
  the cache was too old to connect with -> deadlock.
- Not the cause: wg_fwmark 0xea13b2c the whole day (dispatcher log), sectop posture
  (read-only).
- Fix now: `sudo hostfw observe` (12:39) -> next try connected in 33 s (PL-FREE#2) ->
  `sudo hostfw enforce` + `confirm` after connect: fine.
- Planned: allow tcp/443 on the uplink only for the connect unit's cgroup, only while it
  runs (design first: user cgroups are writable by the user).
