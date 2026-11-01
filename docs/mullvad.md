# Mullvad VPN (official app, RPM)

Replaced Proton VPN on 2026-10-26 (firewall/docs/observe-log.md, same date).
CLI only: the RPM also ships the GUI, not started, no autostart.

## Install (Silverblue)

Repo file and key checked before install (key: https://mullvad.net/help/verifying-signatures):

    curl -fsS https://repository.mullvad.net/rpm/stable/mullvad.repo      # gpgcheck=1, https gpgkey
    curl -fsS -o /tmp/mullvad-keyring.asc https://repository.mullvad.net/rpm/mullvad-keyring.asc
    gpg --show-keys --with-fingerprint /tmp/mullvad-keyring.asc
    # pub rsa4096 A119 8702 FC3E 0A09 A9AE  5B75 D5A1 D4F2 66DE 8DDF
    # uid Mullvad (code signing), signing subkey ...A26581F219C8314C
    sudo curl -fsS -o /etc/yum.repos.d/mullvad.repo https://repository.mullvad.net/rpm/stable/mullvad.repo
    sudo restorecon -v /etc/yum.repos.d/mullvad.repo
    rpm-ostree refresh-md
    rpm-ostree install mullvad-vpn          # 2026.5 (+ libXScrnSaver)
    systemctl reboot

Mullvad lists Fedora Atomic as unsupported, with these steps:
https://mullvad.net/help/install-mullvad-app-linux

## Settings

    systemctl is-enabled mullvad-daemon    # enabled
    rpm -qi mullvad-vpn | grep -iE '^(version|signature)'
    mullvad lockdown-mode set on           # first: kill switch also while disconnected
    mullvad auto-connect set on            # connects at boot, before login
    mullvad account login                  # number typed at the prompt, never in a file
    mullvad api-access use 1               # Direct
    mullvad api-access disable 3           # Encrypted DNS proxy
    mullvad api-access disable 2           # Mullvad Bridges
    mullvad connect
    mullvad status -v

API access only Direct: the one method hostfw allows outside the tunnel
(docs/deviations.md).

Not used: split tunneling, custom DNS, DNS content blockers, Allow LAN.

## How it fits hostfw

| item | value | hostfw |
|---|---|---|
| tunnel | `wg0-mullvad` | `if_vpn`, `if_trusted` |
| DNS | Mullvad resolver via the tunnel (systemd-resolved, `~.`) | `vpn_dns4` (local.conf) |
| mark | 0x6d6f6c65 (`wg show wg0-mullvad fwmark`) | `wg_fwmark` -> `out_wg` |
| API outside the tunnel | uid 0 tcp/443 to the API address, no mark | `vpn_api4` (local.conf) -> `out_vpn_api` |
| routing | `not fwmark 0x6d6f6c65 lookup 1836018789` (table id = the mark) | - |
| kill switch | table `inet mullvad`, policy drop in / out / forward | not touched |
| split tunneling | `mullvad-exclude` (setuid root), ct mark 0xf41 + mark 0x6d6f6c65 | not accepted -> out_leak |

- Relay transport carries the mark (only privileged processes can set it, Mullvad
  docs/security.md) -> out_wg.
- The daemon's API calls outside the tunnel do NOT carry the mark (host 2026-10-26: uid 0
  tcp/443 to two API addresses, then public DoH fallbacks) -> out_leak, rejected in enforce. Connect still works (cached
  relay list); inside the tunnel the API is allowed (out_new).
- Mullvad's own rule while disconnected (`mullvad disconnect; sudo nft list chain inet
  mullvad output`, 2026-10-26): `ip daddr <API address> tcp dport 443 meta skuid 0
  accept`. hostfw does the same: set `vpn_api4`, rule `out_vpn_api`. Another API address
  (Mullvad changes it) = OUT-LEAK uid 0 tcp/443 again: compare with that chain, update
  `vpn_api4` in /etc/hostfw/local.conf, then `sudo hostfw sync`. The DoH fallbacks stay blocked.
- Other API access methods (Bridges, Encrypted DNS proxy) use other addresses and ports
  (seen 2026-10-27: public DoH resolvers tcp/443, proxy on another port) -> out_leak.
  Disabled in the app; if `mullvad api-access get` shows anything but Direct, the daemon
  switched after Direct failed.
- `mullvad-exclude` ships setuid root with the package (any local user can start a program
  outside the tunnel). Audited (`privileged` list, watch rule `split-tunnel` in sectop).
  Test 2026-11-01 (firewall/docs/observe-log.md): the excluded flow stayed in the tunnel,
  nothing on the uplink.
- ICMP echo TTL=1 to the relay on the uplink, uid 0, no mark (before / at connect): rejected,
  connect not affected.
- `inet mullvad` and `inet hostfw` both filter: a packet leaves only if both accept.
- DNS content blockers change the resolver address: add the new one to `vpn_dns4` in
  /etc/hostfw/local.conf (`sudo hostfw sync`) before turning them on (`resolvectl dns wg0-mullvad`).
- Router web UI: `sudo hostfw router-open 10` + `mullvad lan set allow`, then
  `mullvad lan set block`.

## Checks

    mullvad status -v                      # Connected, relay, tunnel wg0-mullvad
    mullvad lockdown-mode get              # on
    sudo nft list chain inet mullvad output | head -3     # policy drop
    resolvectl dns wg0-mullvad             # same as vpn_dns4 in /etc/hostfw/local.conf
    sudo hostfw status                     # wg_fwmark 0x6d6f6c65
    mullvad api-access list                # only "1. Direct *" has the star
    mullvad api-access get                 # Direct

## Proton VPN removed (2026-10-26)

Why: drops on wifi roaming (routing kill switch lost its host route on every DHCP
restart), pre-connect API calls outside the tunnel deadlocked with hostfw enforce.

    systemctl --user disable --now protonvpn-connect.service
    protonvpn signout                       # ends the session, removes stored login
    rm ~/.config/systemd/user/protonvpn-connect.service ~/.local/bin/protonvpn-wait-uplink
    systemctl --user daemon-reload
    sudo systemctl unmask me.proton.vpn.split_tunneling.service
    rpm-ostree uninstall proton-vpn-cli protonvpn-stable-release   # + its python3-proton-*, proton-vpn-daemon
    systemctl reboot
    rpm-ostree cleanup -m                   # cached repo metadata
    rm -rf ~/.cache/Proton ~/.config/Proton
    sudo rm /var/lib/hostfw/proton_probe    # hostfw state of the removed probe sets

Repo: firewall/proton/ (connect unit + uplink wait), docs/proton-cli.md, hostfw Proton
sets / counters removed.

Checks (all empty):

    rpm -qa | grep -i proton
    ls /etc/yum.repos.d/ | grep -i proton
    nmcli -g NAME connection show | grep -iE 'proton|pvpn'
    ip -br link | grep -iE 'proton|pvpn'
    sudo ostree admin config-diff | grep -i proton
