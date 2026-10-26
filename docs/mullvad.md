# Mullvad VPN (official app, RPM)

Replaced Proton VPN on 2026-10-26 (firewall/docs/observe-log.md, same date).
CLI only: the RPM also ships the GUI, not started, no autostart.

## Install (Silverblue)

Repo file and key checked before install (key: https://mullvad.net/help/verifying-signatures):

    curl -fsS https://repository.mullvad.net/rpm/stable/mullvad.repo      # gpgcheck=1, https gpgkey
    curl -fsS -o /tmp/mullvad-keyring.asc https://repository.mullvad.net/rpm/mullvad-keyring.asc
    gpg --show-keys --with-fingerprint /tmp/mullvad-keyring.asc
    # pub rsa4096 A119 8702 FC3E 0A09 A9AE  5B75 D5A1 D4F2 66DE 8DDF
    # uid Mullvad (code signing) <admin@mullvad.net>, signing subkey ...A26581F219C8314C
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
    mullvad connect
    mullvad status -v

Not used: split tunneling, custom DNS, DNS content blockers, Allow LAN.

## How it fits hostfw

| item | value | hostfw |
|---|---|---|
| tunnel | `wg0-mullvad` | `if_vpn`, `if_trusted` |
| DNS | 10.64.0.1 via the tunnel (systemd-resolved, `~.`) | `vpn_dns4` |
| mark | 0x6d6f6c65 (`wg show wg0-mullvad fwmark`) | `wg_fwmark` -> `out_wg` |
| routing | `not fwmark 0x6d6f6c65 lookup 1836018789` (table id = the mark) | - |
| kill switch | table `inet mullvad`, policy drop in / out / forward | not touched |
| split tunneling | ct mark 0xf41 + mark 0x6d6f6c65 | not accepted -> out_leak |

- Relay transport and the daemon's own API calls outside the tunnel carry the mark (only
  privileged processes can set it, Mullvad docs/security.md) -> no pre-connect exception,
  unlike Proton.
- `inet mullvad` and `inet hostfw` both filter: a packet leaves only if both accept.
- DNS content blockers change the resolver address: add the new one to `vpn_dns4` before
  turning them on (`resolvectl dns wg0-mullvad`).
- Router web UI: `sudo hostfw router-open 10` + `mullvad lan set allow`, then
  `mullvad lan set block`.

## Checks

    mullvad status -v                      # Connected, relay, tunnel wg0-mullvad
    mullvad lockdown-mode get              # on
    sudo nft list chain inet mullvad output | head -3     # policy drop
    resolvectl dns wg0-mullvad             # 10.64.0.1
    sudo hostfw status                     # wg_fwmark 0x6d6f6c65
