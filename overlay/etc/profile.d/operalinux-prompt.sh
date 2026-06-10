# OperaLinux shell branding.
if [ -n "${BASH_VERSION:-}" ]; then
    PS1='\[\e[1;36m\]OperaLinux\[\e[0m\] \u@\h:\w\$ '
fi

if [ -d /opt/operalinux/debian-coreutils/bin ]; then
    export OPERALINUX_DEBIAN_COREUTILS="/opt/operalinux/debian-coreutils/bin"
fi
