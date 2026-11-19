# ~/.bashrc of the admin account (harden-workstation.sh accounts, accounts/admin.*)
# Immutable (chattr +i). Unlike Fedora's skel .bashrc: no ~/.bashrc.d, no directory from
# the home on PATH (~/.local/bin, ~/bin): every command the admin types, sudo included,
# comes from a root-owned directory.

if [ -f /etc/bashrc ]; then
    . /etc/bashrc
fi

PATH=/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin
export PATH
