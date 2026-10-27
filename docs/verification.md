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
| VM large download (MTU) | `curl -o /dev/null 'https://speed.cloudflare.com/__down?bytes=20000000'` | 20000000 bytes |
| Podman / kind | `podman ps`, `kubectl get nodes` | `Ready` |
| Steam game | launch | OK |
| Speakers | `speaker-test -c 2 -t wav -l 1` | OK |

## Hardening in effect

| Check | Command | Expected |
|-------|---------|----------|
| audit rules loaded | `sudo auditctl -l \| wc -l` | ~70 |
| audit at boot | `grep -o 'audit[^ ]*' /proc/cmdline` | `audit=1`, `audit_backlog_limit=8192` |
| syscall auditing on | `sudo auditctl -l \| grep -c 'never,task'` | `0` |
| audit log ring | `sudo grep -e ^max_log_file -e ^num_logs /etc/audit/auditd.conf` | `max_log_file = 32`, `num_logs = 40`, `max_log_file_action = ROTATE` |
| identity watch | `sudo touch /etc/passwd; sudo ausearch -k identity -ts recent -i` | event with `auid=<user>` |
| hostname syscall | `sudo hostname "$(hostname)"; sudo ausearch -k system-locale -ts recent -i` | `syscall=sethostname` |
| SELinux policy watch | `sudo touch /etc/selinux/config; sudo ausearch -k MAC-policy -ts recent -i` | event |
| sysctl | `sysctl kernel.yama.ptrace_scope kernel.kexec_load_disabled fs.suid_dumpable` | `1`, `1`, `0` |
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
| unowned / world-writable | `sudo find / -xdev \( -nouser -o -nogroup \)` etc. | none |
