# Debian GNU Coreutils Compatibility

OperaLinux keeps the pacman-owned Artix/Arch `coreutils` package intact so upgrades
remain safe. This directory provides a small compatibility layer for scripts that
expect Debian-flavoured command defaults.

To opt in for a shell session:

```sh
export PATH="/opt/operalinux/debian-coreutils/bin:$PATH"
```

The wrappers intentionally cover only behaviour that can be adjusted without
replacing pacman-owned files.
