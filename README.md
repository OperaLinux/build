# OperaLinux ISO Builder

OperaLinux is a Bash-built, Artix/Arch-compatible Linux distribution project.

Philosophy:

- Simple
- Rolling with stable named releases
- Recoverable upgrades
- CLI-first
- Gaming ready
- OpenRC only

Initial release: OperaLinux 1.0.0 "lynx"

## Build

```sh
git clone OperaLinux
cd OperaLinux
chmod +x build.sh
sudo ./build.sh
```

The final ISO is written to:

```text
output/OperaLinux-x86_64.iso
```

By default the build downloads and installs the latest Proton GE release into
the image. For an offline build, run:

```sh
sudo INSTALL_PROTON_GE=0 ./build.sh
```

## Host Requirements

Build on an Artix or Arch-compatible host with pacman tooling and:

- `basestrap` or `pacstrap`
- `grub-mkrescue`
- `libisoburn` for the `xorriso` command
- `mtools`
- `squashfs-tools`
- `zstd`
- network access to Artix, Arch, AUR, and GitHub

## Policy

OperaLinux is OpenRC only. The builder refuses forbidden init packages, enables
OpenRC services, uses Artix `udev` and elogind, and installs a pacman transaction guard.

Artix repositories are configured before Arch compatibility repositories. Arch
`core` is intentionally absent.

## Live ISO

The live ISO logs in as root on TTY1 and creates no regular user. Run:

```sh
sonnet
```

to install OperaLinux to disk.

## Package Managers

`pacman` is the primary package manager.

`yay` is installed for AUR packages and wrapped with an OpenRC policy warning.

`violin` is the simple OperaLinux community package and system upgrade manager.
