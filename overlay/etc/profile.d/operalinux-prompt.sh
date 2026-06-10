# OperaLinux shell branding.
if [ -n "${BASH_VERSION:-}" ]; then
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        PS1='\[\e[1;31m\][\u@\h]:\w$\[\e[0m\] '
    else
        PS1='\[\e[1;32m\][\u@\h]:\w$\[\e[0m\] '
    fi
fi

if [ -d /opt/operalinux/debian-coreutils/bin ]; then
    export OPERALINUX_DEBIAN_COREUTILS="/opt/operalinux/debian-coreutils/bin"
fi
