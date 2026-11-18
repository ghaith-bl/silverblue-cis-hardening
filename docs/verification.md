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
| browsevm network | `sudo virsh net-info browse`; `firewall-cmd --get-zone-of-interface=virbr-browse` (started); `sudo nft list set inet hostfw if_vm_iso`; `sudo firewall-cmd --permanent --policy=browsevm-to-host --list-all` | bridge `virbr-browse`, autostart no; `browsevm`; `virbr-browse`; services `dhcp`, one rich rule: DNS to `192.168.123.1` |
| VM via Mullvad | in the VM: `curl https://am.i.mullvad.net/connected` | `You are connected to Mullvad` |
| VM kill switch | `mullvad disconnect`; in the VM: `curl -sI -m 10 https://archlinux.org`; `mullvad connect`; again | fails; `HTTP/2 200` after connect |
| VM large download (MTU) | `curl -o /dev/null 'https://speed.cloudflare.com/__down?bytes=20000000'` | 20000000 bytes |
| Podman / kind | `podman ps`, `kubectl get nodes` | `Ready` |
| Steam game | launch | OK |
| Speakers | `speaker-test -c 2 -t wav -l 1` | OK |

## Account split (2026-11-05)

`sudo tools/check-accounts.sh <admin> null` from the admin console, after a reboot:

| Check | Expected |
|-------|----------|
| wheel members | `<admin>` |
| mullvad members | `<admin>` |
| sectop: admin / daily | member / not a member |
| sectop-feed members / helper dir | `-` (none) / `null:sectop-feed 750` |
| live wheel / mullvad | no daily process holds it |
| sudo: daily / admin | not allowed / `(ALL) ALL` |
| root password | locked |
| gdm list / gdm login | admin hidden / admin refused (pam_succeed_if) |
| home admin / home null | `700 <admin>` / `700 null` |
| sysusers admin / daily | `m <admin> sectop` / no line |
| mullvad lockdown | on |
| path local/bin, local/sbin | root-owned, not group/world writable (a file the daily user owns there runs with the admin's rights) |
| unit sectop, sectop-net, sectop-user@null, sectop-whois | active |
| summary | `0 FAIL` |

| Check | Command | Expected |
|-------|---------|----------|
| daily user has no sudo | as null: `sudo -v` | `may not run sudo`, line in `/var/log/sudo.log` |
| admin not in GDM | GDM user list; typing the admin name at GDM | not listed; refused |
| admin on the console | Ctrl+Alt+F3, admin login, `sudo -v` | OK |
| helper channel | `ls -ld /run/sectop-user/null; ls -l /run/sectop-user/null` | `null sectop-feed` 0750, `socks.json` 0640 |
| daily user can't read sectop | as null: `cat /run/sectop/state.json` | Permission denied |
| discovery ports dropped inbound | `sudo nft list chain inet hostfw input \| grep -c in_disco`; later `sudo hostfw counters \| grep in_disco` | `2`; in_disco grows on a LAN with phones / TVs (mDNS, SSDP) |
| split tunneling blocked | as null: `mullvad-exclude curl -m 10 https://am.i.mullvad.net/connected`; `sudo hostfw counters \| grep out_split` | fails fast; out_split grows, `HFW-OUT-SPLIT` with UID=1000 |

## Hardening in effect

| Check | Command | Expected |
|-------|---------|----------|
| audit rules loaded | `sudo auditctl -l \| wc -l` | 73 (this host 2026-11-17: 47 + one per setuid program; changes with the setuid list) |
| setuid / setgid audited | `sudo auditctl -l \| grep -c 'key=privileged'` | `find /usr -xdev -type f \( -perm -4000 -o -perm -2000 \) \| wc -l` (the same number; 26 on 2026-11-17, after `guesttools`) |
| guesttools | `rpm-ostree status --booted --json \| grep -A5 requested-base-removals`; `rpm -q open-vm-tools open-vm-tools-desktop spice-vdagent`; `ls /etc/xdg/autostart \| grep -iE 'vmware\|vbox\|spice'` | the three names listed; `not installed` each; no autostart file |
| audit rules locked | `sudo auditctl -s \| grep enabled` | `enabled 2` |
| lock refuses changes | `sudo auditctl -w /tmp -p wa -k test`; `sudo auditctl -l \| wc -l` | error; count unchanged |
| audit at boot | `grep -o 'audit[^ ]*' /proc/cmdline` | `audit=1`, `audit_backlog_limit=8192` |
| syscall auditing on | `sudo auditctl -l \| grep -c 'never,task'` | `0` |
| audit log ring | `sudo grep -e ^max_log_file -e ^num_logs /etc/audit/auditd.conf` | `max_log_file = 32`, `num_logs = 40`, `max_log_file_action = ROTATE` |
| identity watch | `sudo touch /etc/passwd; sudo ausearch -k identity -ts recent -i` | event with `auid=<user>` |
| hostname syscall | `sudo hostname "$(hostname)"; sudo ausearch -k system-locale -ts recent -i` | `syscall=sethostname` |
| SELinux policy watch | `sudo touch /etc/selinux/config; sudo ausearch -k MAC-policy -ts recent -i` | event |
| sysctl | `sysctl kernel.yama.ptrace_scope kernel.kexec_load_disabled fs.suid_dumpable` | `PTRACE_SCOPE`, `1`, `0` |
| sysctl: attack surface | `sysctl kernel.io_uring_disabled dev.tty.ldisc_autoload fs.protected_fifos fs.protected_regular kernel.sysrq kernel.warn_limit kernel.oops_limit` | `2`, `0`, `2`, `2`, `0`, `100`, `100` |
| sysctl: mmap bits | `sudo sysctl vm.mmap_rnd_bits vm.mmap_rnd_compat_bits` (root only, 0600) | `32`, `16` |
| password quality | `echo 'Password123' \| pwscore` | rejected (< 14 chars) |
| faillock | `faillock --user "$USER"` | empty table |
| su blocked | `su -` | `Permission denied` |
| sudo works | `sudo -k && sudo true` | OK |
| sudo log | `sudo tail -3 /var/log/sudo.log` | recent commands |
| microphone off | `wpctl status` | `Sources:` empty |
| no exposed listeners | `sudo ss -tulpn` | only localhost / `virbr0` / WireGuard |
| loopback (firewalld) | `sudo firewall-cmd --zone=trusted --list-all` | `interfaces: lo`, 2 rich rules (127.0.0.1, ::1) |
| password age | `sudo chage -l <user>` | `Maximum ... : 365`, `warning ... : 14` (both accounts) |
| cron dir modes | `sudo stat -c '%a %n' /etc/cron.d /etc/cron.daily` | `700` (also after an rpm-ostree update + reboot) |
| hostfw modes | `sudo hostfw status`; `sudo hostfw noscope status` | `mode: enforce`, `noscope: enforce`, `boot mode: enforce`; `noscope mode: enforce  boot: enforce`, `watcher: active` |
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
| autoupdate: OS | `rpm-ostree status \| grep AutomaticUpdates`; `systemctl list-timers rpm-ostreed-automatic.timer` | `stage; rpm-ostreed-automatic.timer: last run ...`; a next run |
| autoupdate: staged | `rpm-ostree status` after a run with updates | a deployment marked `(staged)`; booted after the next reboot |
| autoupdate: Flatpak | `systemctl list-timers flatpak-update-system.timer`; `systemctl --user list-timers flatpak-update-user.timer` (daily user); `journalctl -u flatpak-update-system` | both timers listed; runs without errors |
| autoupdate: firmware metadata | `systemctl list-timers fwupd-refresh.timer`; `systemctl cat fwupd-refresh.timer`; `fwupdmgr get-remotes` | timer listed, next run within two days; drop-in `50-schedule.conf` with `OnCalendar=*-*-1/2`; `lvfs` enabled, recent metadata |
| autoupdate: no firmware reports | `fwupdmgr --no-unreported-check get-remotes \| grep -E 'Report URI\|Automatic'`; `grep -h ReportURI /etc/fwupd/remotes.d/*.conf` | no `Report URI` line; only commented `#ReportURI=` lines |
| revocation list (dbx) current | `fwupdmgr get-updates` | no `UEFI dbx` update left (see secure-boot.md) |
| browsevm kiosk | `sudo browsevm/browsevm.sh report` (VM off; also `report brave`) | `BROWSER mullvad`, `security_slider", 2`; `seuser web: user_u`, `kiosk id -Z: user_u:user_r:user_t:s0`, every process of web `user_t` (`(sd-pam)` `init_t`), tty1 `user_tty_device_t`; AVC only `/dev/udmabuf`; brave: `BRAVE-PROFILE present` |
| browsevm isolation | `BROWSEVM_REPORT_SECS=480 BROWSEVM_REPORT_PROBE="192.168.123.1:53 192.168.122.1:53 192.168.123.1:22 <lab VM>:22 <gateway>:80" sudo -E browsevm/browsevm.sh report` (network `default` up) | `PROBE lateral 192.168.123.1:53 OPEN`, every other target `closed` / `timeout`; 30 rounds `mullvad-check ok`; hostfw counter `fwd_vm_lan` grows |
| browsevm VM on the host | during a session: `ps -eZ \| grep qemu`; `sudo ls -Z /var/lib/libvirt/browsevm-run/ /var/lib/libvirt/images/browsevm-base.qcow2`; `sudo virsh dumpxml browsevm \| grep -E 'clipboard\|filetransfer\|channel\|redirdev'` | `svirt_t` + its own MCS pair; overlay `svirt_image_t` + that pair, base `virt_content_t`; `copypaste='no'`, `enable='no'`, no channel / redirdev |
| browsevm viewer relay (beta) | after a session: `journalctl -t browsevm -n 5` | `viewer end: exit 0, relay 1, sandbox 1, <s> s; viewer->desktop max <n> KiB, longest wait <t> s; ... end: viewer closed`; no `Error flushing display` while the relay is on |
| browsevm viewer sandbox (beta) | during a session: `p=$(pgrep -n -x remote-viewer)`; `readlink /proc/$$/ns/net /proc/$p/ns/net`; `grep NoNewPrivs /proc/$p/status`; `tr '\0' '\n' < /proc/$p/environ \| grep -E '^(DISPLAY\|WAYLAND_DISPLAY\|DBUS)'` | two different `net:[...]`; `NoNewPrivs: 1`; no line |
| browsevm update | `systemctl list-timers browsevm-update.timer`; `journalctl -u browsevm-update.service`; `cat /var/lib/browsevm/base.info` | daily run; `nothing to do` or a rebuild with versions before / now |
| AF_ALG off (kernel arg) | `grep -o 'initcall_blacklist=[^ ]*' /proc/cmdline` | `initcall_blacklist=af_alg_init` |
| AF_ALG socket fails | `python3 -I -c 'import socket; socket.socket(socket.AF_ALG, socket.SOCK_SEQPACKET)'` | `OSError: [Errno 97] Address family not supported by protocol` |
| hardening kargs | `grep -oE 'page_alloc.shuffle=[^ ]*\|rd.shell=[^ ]*\|rd.emergency=[^ ]*' /proc/cmdline` | `page_alloc.shuffle=1`, `rd.shell=0`, `rd.emergency=halt` |
| memory / DMA kargs | `grep -oE 'init_on_free=[^ ]*\|iommu.strict=[^ ]*' /proc/cmdline`; `journalctl -k -b -g 'mem auto-init\|TLB invalidation'` | `init_on_free=1`, `iommu.strict=1`; `heap free:on`, `strict mode` |
| KSPP kargs | `grep -oE 'hash_pointers=[^ ]*\|proc_mem.force_override=[^ ]*\|module.sig_enforce=[^ ]*\|intel_iommu=[^ ]*\|debugfs=[^ ]*\|bdev_allow_write_mounted=[^ ]*' /proc/cmdline` | the six args |
| IOMMU on | `ls /sys/class/iommu`; `journalctl -k -b -g 'DMAR: IOMMU enabled'` | `dmar0` (or more); the line |
| debugfs off | `grep -c debugfs /proc/mounts`; `test -d /sys/kernel/debug && echo present \|\| echo absent` | `0`; `absent` (sys-kernel-debug.mount skipped by its condition, not failed) |
| io_uring refused | `python3 -I -c 'import ctypes; l = ctypes.CDLL(None, use_errno=True); print(l.syscall(425, 1, ctypes.create_string_buffer(120)), ctypes.get_errno())'` | `-1 1` (EPERM) |
| io_uring tries since boot | `sudo ausearch -k io-uring -ts boot -i \| grep -o 'exe=[^ ]*' \| sort \| uniq -c` | only the test above (python3) |
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
