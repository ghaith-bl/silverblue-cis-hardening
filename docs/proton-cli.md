# Proton VPN CLI (official RPM)

Flathub com.protonvpn.www is unofficial -> replaced.

    rpm-ostree install ./protonvpn-stable-release-1.0.1-1.noarch.rpm
    rpm-ostree install proton-vpn-cli
    systemctl reboot

Repo: gpgcheck=1, repo_gpgcheck=1, https gpgkey (no local pin).
Key fingerprint (Fedora 44): 6929 133B DE1C E1CF A9ED B286 D841 76F6 8448 30D4

    sudo systemctl mask me.proton.vpn.split_tunneling.service
    protonvpn signin
    protonvpn config set anonymous-crash-reports off
    protonvpn config set ipv6 off
    protonvpn config set kill-switch standard
    protonvpn connect
    flatpak uninstall --delete-data com.protonvpn.www
    flatpak uninstall --unused

Fedora rebase: check Proton repo exists for new release, verify new key fingerprint once.

Connect fails in enforce with "Server list is outdated": escape hatch in
firewall/README.md (Proton connect at login).
