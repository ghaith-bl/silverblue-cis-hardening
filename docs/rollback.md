# Rollback

Undo per section. Run from the admin (two accounts) or a root shell.

```bash
ls /var/backups/hardening/                       # restore files from here
sudo authselect disable-feature with-faillock    # PAM lockout off
faillock --user "$USER" --reset                  # from a root shell, if locked
sudo sed -i 's/^minlen = .*/minlen = 14/' /etc/security/pwquality.conf   # pam: CIS length (new passwords)
sudo systemctl unmask <unit>                     # bring a service back
sudo rpm-ostree override reset open-vm-tools-desktop open-vm-tools spice-vdagent   # guesttools: back at the
                                                 # next boot; then audit-rules, reboot (setuid rule back)
sudo rm /etc/wireplumber/wireplumber.conf.d/90-disable-mic.conf
systemctl --user restart wireplumber
sudo rm /etc/NetworkManager/conf.d/90-privacy.conf /etc/systemd/resolved.conf.d/90-privacy.conf
sudo rm /etc/NetworkManager/dispatcher.d/50-netprivacy   # new networks keep what they get
sudo systemctl reload NetworkManager systemd-resolved   # then reconnect
sudo nmcli con modify <uuid> ipv6.method auto          # IPv6 back on a profile; with the hook kept:
                                                 # UPLINK_IPV6=keep + netprivacy first, else it goes off again
sudo rm -r /etc/systemd/system/systemd-hostnamed.service.d && sudo systemctl daemon-reload
sudo rpm-ostree kargs --delete=SYSTEMD_DEFAULT_HOSTNAME=localhost   # then reboot
sudo hostnamectl set-hostname <name>             # per profile: nmcli con modify <uuid> ipv4.dhcp-send-hostname -1
sudo nmcli con modify <uuid> ipv4.ignore-auto-dns no   # router DNS back (or old profile: backup system-connections)
sudo usermod -aG wheel <daily>                   # accounts: from the admin; then the
sudo sed -i '1{/pam_succeed_if.so user != /d}' /etc/pam.d/gdm-password   # admin in GDM again
sudo rm /var/lib/AccountsService/users/<admin>   # admin in the GDM list (after a reboot)
h=$(getent passwd <admin> | cut -d: -f6)         # accounts: admin home lock off (then edit freely;
sudo chattr -i "$h" "$h"/{.config,.local,.local/share,.config/systemd,.local/share/systemd,.local/share/flatpak}
sudo chattr -i "$h"/{.bash_profile,.bashrc,.bash_logout,.inputrc}   # a folder that is not there: one error line, harmless
                                                 # Fedora's files: sudo cp /etc/skel/.bash* "$h"/, chown;
                                                 # removed files: /var/backups/hardening/<ts>$h/)
sudo rm /etc/dconf/db/gdm.d/90-cis-hardening /etc/dconf/db/gdm.d/locks/90-cis-hardening && sudo dconf update
                                                 # gnome: GDM login methods + user list back to defaults
sudo rm /etc/systemd/system/mullvad-daemon.service.d/50-socket-group.conf
sudo systemctl daemon-reload && sudo systemctl restart mullvad-daemon
sudo systemctl disable --now kvmlan              # VMs blocked by Mullvad again (table deleted)
sudo rm /etc/systemd/system/kvmlan.service /etc/kvmlan.nft && sudo systemctl daemon-reload
sudo systemctl stop 'browsevm@*' && sudo systemctl disable --now browsevm-update.timer   # browsevm: VM gone
sudo virsh undefine browsevm
sudo rm /etc/systemd/system/browsevm@.service /etc/systemd/system/browsevm-update.{service,timer}
sudo rm /etc/polkit-1/rules.d/60-browsevm.rules /usr/local/sbin/browsevm-ctl /usr/local/bin/browsevm
sudo rm /usr/local/share/applications/browsevm{,-brave}.desktop && sudo systemctl daemon-reload
sudo rm -r /usr/local/lib/browsevm /var/lib/browsevm   # root copy for the timer, base.info
sudo rmdir /var/lib/libvirt/browsevm-run          # tmpfs mount point (unmounted at stop)
sudo rm /var/lib/libvirt/images/browsevm-base.qcow2 /var/lib/libvirt/images/Fedora-Everything-netinst-x86_64-45-*.iso
sudo virsh net-destroy browse; sudo virsh net-undefine browse && sudo rm -r /etc/browsevm   # browsevm network
sudo firewall-cmd --permanent --delete-policy=browsevm-nat-out
sudo firewall-cmd --permanent --delete-policy=browsevm-to-host
sudo firewall-cmd --permanent --delete-zone=browsevm && sudo firewall-cmd --reload
sudo systemctl disable --now usbguard               # USB protection off
sudo usbguard append-rule 'allow id <vid>:<pid> ...'   # one device for good (sudo usbguard list-devices)
sudo rm /usr/local/share/applications/brave-browser.desktop /usr/local/bin/app-unit   # appunit off
sudo hostfw noscope observe                      # out_noscope: log only again
sudo firewall-cmd --permanent --zone=trusted --remove-interface=lo && sudo firewall-cmd --reload   # loopback
sudo rm /etc/tmpfiles.d/90-cis-cron.conf          # cron modes no longer set at boot
sudo rm /etc/dconf/db/{gdm,distro}.d/90-cis-hardening /etc/dconf/db/{gdm,distro}.d/locks/90-cis-hardening
sudo dconf update                                # login user list back (next GDM start)
sudo rm /etc/systemd/journald.conf.d/90-cis.conf  # journald drop-in
sudo rm /etc/systemd/journald.conf                # main file: only if the section created it (else backup)
sudo systemctl restart systemd-journald
sudo rm /etc/tmpfiles.d/90-cis-grub.conf          # GRUB file modes no longer set at boot
sudo chage -M 99999 <user>                        # pwage: no expiry (login.defs: backup)
sudo chage -m 0 <user>                            # pwage: no min age (or PASS_MIN_DAYS=0, section again)
sudo cp /var/backups/hardening/<time>/etc/chrony.conf /etc/ && sudo systemctl restart chronyd
sudo systemctl disable --now rpm-ostreed-automatic.timer   # autoupdate: OS updates by hand again
sudo sed -i 's/^AutomaticUpdatePolicy=.*/AutomaticUpdatePolicy=none/' /etc/rpm-ostreed.conf && sudo rpm-ostree reload
sudo rpm-ostree cleanup -p                       # drop a staged (not yet booted) update
sudo systemctl disable --now flatpak-update-system.timer && sudo systemctl --global disable flatpak-update-user.timer
sudo systemctl disable --now browsevm-update.timer   # browsevm: no daily base rebuild
BROWSEVM_RELAY=0 BROWSEVM_SANDBOX=0 browsevm brave   # browsevm viewer, beta layers off for one start
git revert <viewer commit> && sudo DAILY_USER=<daily> browsevm/browsevm.sh install   # ... for good (VM off)
sudo setsebool -P virt_use_usb on virt_use_nfs on   # svirt: Fedora's defaults
sudo sed -i 's/^security_require_confined = 1/#security_require_confined = 1/' /etc/libvirt/qemu.conf && sudo systemctl restart virtqemud
sudo systemctl disable --now fwupd-refresh.timer     # no firmware metadata at all
sudo rm /etc/systemd/system/fwupd-refresh.timer.d/50-schedule.conf && sudo systemctl daemon-reload   # Fedora's hourly timer again
sudo cp -a /var/backups/hardening/<time>/etc/fwupd/remotes.d/. /etc/fwupd/remotes.d/ && sudo systemctl try-restart fwupd   # report settings before FIRMWARE_REPORTS=no
sudo rpm-ostree kargs --delete=initcall_blacklist=af_alg_init   # then reboot
sudo rpm-ostree kargs --delete=page_alloc.shuffle=1 --delete=rd.shell=0 --delete=rd.emergency=halt
sudo rpm-ostree kargs --delete=init_on_free=1 --delete=iommu.strict=1
sudo rpm-ostree kargs --delete=hash_pointers=always --delete=proc_mem.force_override=never \
  --delete=module.sig_enforce=1 --delete=intel_iommu=on --delete=debugfs=off \
  --delete=bdev_allow_write_mounted=0                                  # then reboot
sudo rm /etc/audit/rules.d/70-io-uring.rules && sudo augenrules   # loads at the next boot
sudo rm /boot/grub2/user.cfg                     # GRUB password off
sudo rm /etc/audit/rules.d/99-finalize.rules     # audit lock off, then reboot
sudo rpm-ostree rollback                         # after booting the previous GRUB entry
sudo ostree admin config-diff                    # every /etc change vs. image defaults
```

- Removing a sysctl file does not revert values until reboot.
- `kernel.kexec_load_disabled` and `kernel.unprivileged_bpf_disabled = 1` are one-way until reboot.
- `kernel.yama.ptrace_scope = 3` is one-way until reboot: set `PTRACE_SCOPE=2`, run the
  sysctl section, reboot.
- Other sysctls (io_uring, sysrq, limits, mmap bits): edit `90-hardening.conf`,
  `sudo sysctl --system` (no reboot).

## Clock far off (time sync stuck)

NTS checks the time servers' certificates against the local clock (start and end dates).
A clock far off (RTC battery, wrong firmware time) = every NTS server refused = no sync,
and the clock stays wrong. The tunnel can fail on the same clock: TLS to the Mullvad API,
and WireGuard handshakes carry a timestamp. `nocerttimecheck` (chrony: skip the date check
for the first updates) is not used on purpose: chrony's docs warn about its security
implications, and it would trust the first answer after every boot. Set the time by hand
instead, from the admin console:

```bash
date -u                                          # compare with a trusted device (phone)
sudo date -u -s 'YYYY-MM-DD HH:MM'               # UTC, from that device (audit key time-change)
mullvad reconnect                                # tunnel with the right time (group mullvad)
sudo systemctl restart chronyd                   # makestep 1.0 3: may step in the first 3 updates
sudo chronyc -N authdata                         # a minute later: Mode NTS, KE > 0
chronyc tracking                                 # Leap status : Normal, small offset
```

- Tunnel still down after the fix: a server that saw a later handshake time from this key
  refuses earlier ones; another server: `mullvad relay set location <country>`.
- `rtcsync`: the kernel copies the synced time to the RTC (every 11 minutes).
