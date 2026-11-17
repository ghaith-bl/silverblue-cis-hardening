# Rollback

Undo per section. Run from the admin (two accounts) or a root shell.

```bash
ls /var/backups/hardening/                       # restore files from here
sudo authselect disable-feature with-faillock    # PAM lockout off
faillock --user "$USER" --reset                  # from a root shell, if locked
sudo systemctl unmask <unit>                     # bring a service back
sudo rpm-ostree override reset open-vm-tools-desktop open-vm-tools spice-vdagent   # guesttools: back at the
                                                 # next boot; then audit-rules, reboot (setuid rule back)
sudo rm /etc/wireplumber/wireplumber.conf.d/90-disable-mic.conf
systemctl --user restart wireplumber
sudo rm /etc/NetworkManager/conf.d/90-privacy.conf /etc/systemd/resolved.conf.d/90-privacy.conf
sudo systemctl reload NetworkManager systemd-resolved   # then reconnect
sudo rm -r /etc/systemd/system/systemd-hostnamed.service.d && sudo systemctl daemon-reload
sudo rpm-ostree kargs --delete=SYSTEMD_DEFAULT_HOSTNAME=localhost   # then reboot
sudo hostnamectl set-hostname <name>             # per profile: nmcli con modify <uuid> ipv4.dhcp-send-hostname -1
sudo nmcli con modify <uuid> ipv4.ignore-auto-dns no   # router DNS back (or old profile: backup system-connections)
sudo usermod -aG wheel <daily>                   # accounts: from the admin; then the
sudo sed -i '1{/pam_succeed_if.so user != /d}' /etc/pam.d/gdm-password   # admin in GDM again
sudo rm /var/lib/AccountsService/users/<admin>   # admin in the GDM list (after a reboot)
sudo rm /etc/systemd/system/mullvad-daemon.service.d/50-socket-group.conf
sudo systemctl daemon-reload && sudo systemctl restart mullvad-daemon
sudo systemctl disable --now kvmlan              # VMs blocked by Mullvad again (table deleted)
sudo rm /etc/systemd/system/kvmlan.service /etc/kvmlan.nft && sudo systemctl daemon-reload
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
sudo cp /var/backups/hardening/<time>/etc/chrony.conf /etc/ && sudo systemctl restart chronyd
sudo systemctl disable --now rpm-ostreed-automatic.timer   # autoupdate: OS updates by hand again
sudo sed -i 's/^AutomaticUpdatePolicy=.*/AutomaticUpdatePolicy=none/' /etc/rpm-ostreed.conf && sudo rpm-ostree reload
sudo rpm-ostree cleanup -p                       # drop a staged (not yet booted) update
sudo systemctl disable --now flatpak-update-system.timer && sudo systemctl --global disable flatpak-update-user.timer
sudo systemctl disable --now browsevm-update.timer   # browsevm: no daily base rebuild
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
