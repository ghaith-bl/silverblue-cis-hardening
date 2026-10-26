# Verification

Tests run after hardening + reboot. All passed.

## Daily tools

| Check | Command | Result |
|-------|---------|--------|
| VPN + kill switch | disconnect VPN, `ping -c 3 archlinux.org` | no connectivity (expected) |
| VPN connected | `ping -c 3 archlinux.org` | 0% loss |
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
| unowned / world-writable | `sudo find / -xdev \( -nouser -o -nogroup \)` etc. | none |
