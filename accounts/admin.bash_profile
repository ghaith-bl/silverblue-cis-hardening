# ~/.bash_profile of the admin account (harden-workstation.sh accounts, accounts/admin.*)
# Immutable (chattr +i), like ~/.bashrc, ~/.bash_logout, ~/.inputrc and the top of this
# home: a script run as the admin cannot plant an alias, a function or a PATH entry here.
# Change: sudo chattr -i <file>, edit, sudo chattr +i <file> (or edit accounts/admin.* and
# run the accounts section again)

if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi
