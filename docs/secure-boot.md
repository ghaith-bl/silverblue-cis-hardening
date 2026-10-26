# Secure Boot on, NVIDIA driver removed (2026-10-26)

Goal: Secure Boot on, kernel lockdown, only Fedora-signed kernel modules, no local
signing key. The dGPU is not used: supergfxctl mode `Integrated` takes it off the PCI
bus (`lspci -nnk -d 10de:` is empty).

## Why

- akmod-nvidia (RPM Fusion) built the NVIDIA modules on the host and signed them with
  a local akmods key enrolled in MOK. Secure Boot was off, lockdown `none`, kernel
  taint `O E` (nvidia-modprobe tried the module at login: "No NVIDIA GPU found").
- A local MOK key = its private key on the same disk (`/etc/pki/akmods/private`). Any
  root process can sign a module with it and the kernel loads it, Secure Boot or not.
  RPM Fusion (Howto/Secure Boot) says to protect or move that key. My decision: no
  local key at all.

## Checks before (read-only)

| Check | Command | Host |
|-------|---------|------|
| dGPU unused | `supergfxctl -g`, `lsmod \| grep -iE 'nvidia\|nouveau'` | `Integrated`, none |
| what RPM Fusion supplies | `rpm -qa --qf '%{NAME}  %{VENDOR}\n' \| grep -i fusion` | NVIDIA packages + its 2 release packages only |
| UEFI db | `mokutil --db --short` | `Microsoft UEFI CA 2023` present |
| shim | `sudo bootupctl status` | shim-16.1-7, at latest version |
| LUKS unlock | - | password only, no TPM -> PCR changes do not matter |

Microsoft UEFI CA 2011 expired June 2026. New shims are signed with the 2023 key only,
so the 2023 CA in db is what keeps a future shim booting (Red Hat blog "Expiration of
Secure Boot signing certificates 2026", LWN 1079808). Present: no db update needed.

## Steps (one reboot each)

1. Unused repos off. Their files belong to `fedora-workstation-repositories` (`rpm -qf`),
   so `enabled=0`, not deleted: `rpmfusion-nonfree-nvidia-driver`,
   `rpmfusion-nonfree-steam` (Steam is a Flatpak), copr `phracek/PyCharm`.

       sudo sed -i -E 's/^enabled[[:space:]]*=[[:space:]]*1[[:space:]]*$/enabled=0/' <repo file>

2. Packages (the rest of NVIDIA went as dependencies):

       rpm-ostree uninstall akmod-nvidia akmods xorg-x11-drv-nvidia-cuda rpmfusion-free-release rpmfusion-nonfree-release

   Left behind: `/etc/systemd/system/graphical.target.wants/nvidia-fallback.service`
   (dangling) -> `rm` + `systemctl daemon-reload`.
   Stays: `nvidia-gpu-firmware` (Fedora firmware files, base image).
3. Kernel args: the NVIDIA ones were added twice. Kept one blacklist (+
   `/etc/modprobe.d/blacklist-nouveau.conf`): no driver on the dGPU, also not nouveau.

       rpm-ostree kargs --delete=rd.driver.blacklist=nouveau --delete=rd.driver.blacklist=nouveau --delete=modprobe.blacklist=nouveau --delete=modprobe.blacklist=nouveau --delete=nvidia-drm.modeset=1 --delete=nvidia-drm.modeset=1

   Kept: `rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core`.
4. MOK key out, then the key files. Delete request first (it needs the cert file):

       sudo mokutil --delete <akmods cert>.der     # asks a one-time password
       # next boot: MokManager -> Delete MOK -> Continue -> Yes -> password -> Reboot
       sudo rm -rf /etc/pki/akmods /etc/akmods

   Plain `rm` is enough: once the key is not enrolled it signs nothing the kernel
   accepts, the disk is LUKS, and overwrite tools are not reliable on btrfs (copy on
   write).
5. Every loaded module signed by Fedora (no output = ok):

       for m in $(lsmod | awk 'NR>1{print $1}'); do s=$(modinfo -F signer "$m" 2>/dev/null); [ "$s" = "Fedora kernel signing key" ] || echo "$m: ${s:-unsigned}"; done

   Then firmware setup: Secure Boot Control `Enabled`, key management untouched.
   The firmware setup has an admin password.

## Result

| Check | Command | Host 2026-10-26 |
|-------|---------|-----------------|
| Secure Boot | `mokutil --sb-state` | `SecureBoot enabled` |
| lockdown | `cat /sys/kernel/security/lockdown` | `none [integrity] confidentiality` |
| taint | `cat /proc/sys/kernel/tainted` | `0` |
| MOK | `mokutil --list-enrolled \| grep -i subject:` | Fedora Secure Boot CA only |
| kernel log | `journalctl -k -b -g 'secure boot\|lockdown'` | "Kernel is locked down from EFI Secure Boot mode" |
| units | `systemctl --failed` | none |
| sectop posture | security screen | pass 43, accepted 0 |

## Side effects

- Hibernation is blocked by lockdown ("hibernation is restricted"). Suspend works.
- debugfs is restricted (one intel_lpmd log line at boot, harmless).
- Out-of-tree modules (NVIDIA, VirtualBox, ...) do not load. Needing one again is its
  own decision, and not with a signing key on this disk.

## Rollback

Firmware setup: Secure Boot Control `Disabled` -> boots as before. The NVIDIA driver
back = `rpm-ostree install akmod-nvidia` + a new MOK key (not planned).
