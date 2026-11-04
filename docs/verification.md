# Verification

Tests run after hardening + reboot. All passed.

## Daily tools

| Check | Command | Result |
|-------|---------|--------|
| VPN + kill switch | `mullvad disconnect`, `ping -c 3 archlinux.org` (then `mullvad connect`) | no connectivity (lockdown, expected) |
| VPN connected | `ping -c 3 archlinux.org` | 0% loss |
| VPN API outside the tunnel | `mullvad api-access list`; `mullvad disconnect && sleep 3 && mullvad api-access test 1`; `sudo hostfw counters \| grep out_vpn_api` (then `mullvad connect`) | only Direct enabled; `Success!`; `out_vpn_api` grows, no OUT-LEAK to the API address |
| VM SSH | `ssh toolkit-lab` | OK |
| VM internet | `curl -sI https://archlinux.org` | `HTTP/2 200` |
| VM lease, Allow LAN off | `mullvad lan get`; in the VM: `nmcli device status` | `block`; `enp1s0 ... connected` |
| kvmlan table | `systemctl is-active kvmlan`; `sudo nft list table inet kvmlan` | `active`; chains `kvm_in`, `kvm_out` |
| VM via Mullvad | in the VM: `curl https://am.i.mullvad.net/connected` | `You are connected to Mullvad` |
| VM kill switch | `mullvad disconnect`; in the VM: `curl -sI -m 10 https://archlinux.org`; `mullvad connect`; again | fails; `HTTP/2 200` after connect |
| VM large download (MTU) | `curl -o /dev/null 'https://speed.cloudflare.com/__down?bytes=20000000'` | 20000000 bytes |
| Podman / kind | `podman ps`, `kubectl get nodes` | `Ready` |
| Steam game | launch | OK |
| Speakers | `speaker-test -c 2 -t wav -l 1` | OK |

## Hardening in effect

| Check | Command | Expected |
|-------|---------|----------|
| audit rules loaded | `sudo auditctl -l \| wc -l` | ~73 |
| setuid / setgid audited | `sudo auditctl -l \| grep -c 'key=privileged'` | `find /usr -xdev -type f \( -perm -4000 -o -perm -2000 \) \| wc -l` (28 on 2026-11-01) |
| audit rules locked | `sudo auditctl -s \| grep enabled` | `enabled 2` |
| lock refuses changes | `sudo auditctl -w /tmp -p wa -k test`; `sudo auditctl -l \| wc -l` | error; count unchanged |
| audit at boot | `grep -o 'audit[^ ]*' /proc/cmdline` | `audit=1`, `audit_backlog_limit=8192` |
| syscall auditing on | `sudo auditctl -l \| grep -c 'never,task'` | `0` |
| audit log ring | `sudo grep -e ^max_log_file -e ^num_logs /etc/audit/auditd.conf` | `max_log_file = 32`, `num_logs = 40`, `max_log_file_action = ROTATE` |
| identity watch | `sudo touch /etc/passwd; sudo ausearch -k identity -ts recent -i` | event with `auid=<user>` |
| hostname syscall | `sudo hostname "$(hostname)"; sudo ausearch -k system-locale -ts recent -i` | `syscall=sethostname` |
| SELinux policy watch | `sudo touch /etc/selinux/config; sudo ausearch -k MAC-policy -ts recent -i` | event |
| sysctl | `sysctl kernel.yama.ptrace_scope kernel.kexec_load_disabled fs.suid_dumpable` | `2`, `1`, `0` |
| password quality | `echo 'Password123' \| pwscore` | rejected (< 14 chars) |
| faillock | `faillock --user "$USER"` | empty table |
| su blocked | `su -` | `Permission denied` |
| sudo works | `sudo -k && sudo true` | OK |
| sudo log | `sudo tail -3 /var/log/sudo.log` | recent commands |
| microphone off | `wpctl status` | `Sources:` empty |
| no exposed listeners | `sudo ss -tulpn` | only localhost / `virbr0` / WireGuard |
| Secure Boot | `mokutil --sb-state` | `SecureBoot enabled` |
| kernel lockdown | `cat /sys/kernel/security/lockdown` | `[integrity]` |
| kernel not tainted | `cat /proc/sys/kernel/tainted` | `0` |
| MOK keys | `mokutil --list-enrolled \| grep -i subject:` | Fedora Secure Boot CA only |
| modules signed | loop in [secure-boot.md](secure-boot.md) step 5 | no output |
| MAC not the real one | `ip -j link \| python3 -c 'import json,sys; [print(l["ifname"], "changed" if l.get("permaddr") else "same") for l in json.load(sys.stdin) if l.get("link_type")=="ether"]'` | connected interfaces `changed` |
| new MAC per connect | `cat /sys/class/net/*/address \| sha256sum \| cut -c1-12`, `nmcli radio wifi off; sleep 2; nmcli radio wifi on`, wait for connect, again | two different hashes |
| privacy defaults | `NetworkManager --print-config \| grep -E 'cloned-mac\|send-hostname\|client-id\|duid\|ip6-privacy'` | values of `90-privacy.conf` |
| no hostname in DHCP | `sudo -v`, then `sudo timeout 25 tcpdump -lni any -vv udp port 67 or udp port 68 2>/dev/null \| grep -E 'DHCP-Message\|Hostname \(12\), length\|FQDN' & sleep 3; nmcli radio wifi off; sleep 2; nmcli radio wifi on; wait` | `DHCP-Message` lines only |
| new network (profile default -1) | same test after `sudo nmcli con modify <active uuid> ipv4.dhcp-send-hostname -1 ipv6.dhcp-send-hostname -1`, then set `no` again | `DHCP-Message` lines only (NetworkManager does not send `localhost`) |
| hostname | `hostnamectl`; `cat /proc/sys/kernel/hostname` | `Static hostname: localhost`, no transient or pretty line; `localhost` |
| hostname from boot | `journalctl -b -o short-monotonic \| grep 'Hostname set to'`; `grep -o 'SYSTEMD_DEFAULT_HOSTNAME=[^ ]*' /proc/cmdline` | `<localhost>` only (first line < 1 s, initramfs); the arg |
| LLMNR / mDNS off | `resolvectl status \| grep -E 'LLMNR\|mDNS'` | only `-LLMNR -mDNS` |
| DNS only in the tunnel | `resolvectl dns`; `resolvectl status \| grep -ci fallback` | a server on `wg0-mullvad` only; `0` |
| no DNS in profiles | `for u in $(nmcli -g UUID,TYPE con show \| awk -F: '$2~/wireless\|ethernet/{print $1}'); do nmcli -g ipv4.dns,ipv4.ignore-auto-dns,ipv6.dns,ipv6.ignore-auto-dns con show "$u" \| paste -sd' '; done` | ` yes  yes` per profile |
| time: NTS only | `chronyc -N authdata` (sudo if denied); `chronyc -n sources` | 5 servers, Mode `NTS`, KE / Cook > 0; `^*` on one of them |
| time: synced | `chronyc tracking` | `Leap status : Normal`, small `System time` offset |
| time: no DHCP servers | `grep -E '^(pool\|sourcedir)' /etc/chrony.conf` | nothing |
| AF_ALG off (kernel arg) | `grep -o 'initcall_blacklist=[^ ]*' /proc/cmdline` | `initcall_blacklist=af_alg_init` |
| AF_ALG socket fails | `python3 -I -c 'import socket; socket.socket(socket.AF_ALG, socket.SOCK_SEQPACKET)'` | `OSError: [Errno 97] Address family not supported by protocol` |
| hardening kargs | `grep -oE 'page_alloc.shuffle=[^ ]*\|rd.shell=[^ ]*\|rd.emergency=[^ ]*' /proc/cmdline` | `page_alloc.shuffle=1`, `rd.shell=0`, `rd.emergency=halt` |
| page allocator shuffle | `sudo cat /sys/module/page_alloc/parameters/shuffle` (root only, 0400) | `Y` |
| GRUB password | `sudo test -f /boot/grub2/user.cfg && echo set`; menu: `e` on an entry | `set`; asks user `root` + password; plain boot asks nothing |
| AF_ALG tries since boot | `sudo ausearch -k af-alg -sc socket -ts boot -i \| grep -o 'exe=[^ ]*' \| sort \| uniq -c` | only the test above (python3) |
| unowned / world-writable | `sudo find / -xdev \( -nouser -o -nogroup \)` etc. | none |
| USBGuard on | `systemctl is-enabled usbguard; systemctl is-active usbguard` | `enabled`, `active` |
| usbguard-dbus gone | `rpm -q usbguard-dbus` | `package usbguard-dbus is not installed` |
| usbguard CLI root only | `usbguard list-devices` (no sudo) | refused |
| USB keyboard / mouse before login | reboot, type at the login screen | internal + external keyboard and mouse work (rules in rules.conf) |
| new device blocked | plug a flash drive; `sudo usbguard list-devices --blocked` | listed as `block`, not in Files |
| flash drive allowed | `sudo usb-allow-storage`, answer `y` | `storage only`, allowed, shows in Files |
| allow until unplugged | unplug, plug again; `sudo usb-allow-storage`, answer `n` | new id, still blocked |
| Brave in its own unit | open Brave from the menu; `for p in $(pgrep -x brave); do cat /proc/$p/cgroup; done \| sort \| uniq -c` | `app-brave\x2dbrowser@<pid>.service` (main process: `app-org.chromium.Chromium-<pid>.scope`, Chromium moves itself); none in `org.gnome.Shell@user.service` |
| GNOME usb-protection off | `gsettings get org.gnome.desktop.privacy usb-protection; gsettings writable org.gnome.desktop.privacy usb-protection` | `false`, `false` |
