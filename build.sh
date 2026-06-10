#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="OperaLinux"
ARCH="x86_64"
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${PROJECT_DIR}/config"
PACKAGES_DIR="${PROJECT_DIR}/packages"
OVERLAY_DIR="${PROJECT_DIR}/overlay"
SONNET_SRC="${PROJECT_DIR}/sonnet/sonnet"
VIOLIN_SRC="${PROJECT_DIR}/violin/violin"
WORK_DIR="${WORK_DIR:-${PROJECT_DIR}/work}"
ROOTFS_DIR="${ROOTFS_DIR:-${WORK_DIR}/rootfs}"
ISO_DIR="${ISO_DIR:-${WORK_DIR}/iso}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}"
LOG_DIR="${LOG_DIR:-${PROJECT_DIR}/logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/build.log}"
BUILD_PACMAN_CONF="${WORK_DIR}/pacman-build.conf"
ISO_NAME="OperaLinux-x86_64.iso"
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

# shellcheck source=/dev/null
source "${CONFIG_DIR}/release.conf"

ISO_LABEL="OPERALINUX_${VERSION_ID//./}"

log() {
    local level="$1"
    shift
    mkdir -p "$LOG_DIR"
    printf '[%s] [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR" "$*"
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this builder as root: sudo ./build.sh"
}

require_command() {
    have "$1" || die "Missing required command: $1"
}

check_host_dependencies() {
    local required=(
        bash awk sed grep find sort tail basename dirname date tee
        pacman pacman-key curl tar zstd sha256sum
        grub-mkrescue mksquashfs xorriso mformat
        mount umount chroot cp install mkdir rm
    )

    for cmd in "${required[@]}"; do
        require_command "$cmd"
    done

    if ! have basestrap && ! have pacstrap; then
        die "Need basestrap from Artix or pacstrap from arch-install-scripts"
    fi
}

cleanup_mounts() {
    local mountpoint
    for mountpoint in \
        "${ROOTFS_DIR}/run" \
        "${ROOTFS_DIR}/dev/pts" \
        "${ROOTFS_DIR}/dev" \
        "${ROOTFS_DIR}/proc" \
        "${ROOTFS_DIR}/sys"; do
        if mountpoint -q "$mountpoint"; then
            umount -R "$mountpoint" || true
        fi
    done
}

cleanup() {
    cleanup_mounts
}
trap cleanup EXIT

prepare_workspace() {
    log "INFO" "Preparing workspace"
    rm -rf "$WORK_DIR"
    mkdir -p "$ROOTFS_DIR" "$ISO_DIR" "$OUTPUT_DIR" "$LOG_DIR"
    : > "$LOG_FILE"
}

write_build_pacman_conf() {
    log "INFO" "Writing build-local pacman configuration"
    awk -v artix_mirror="${CONFIG_DIR}/pacman.d/mirrorlist" \
        -v arch_mirror="${CONFIG_DIR}/pacman.d/mirrorlist-arch" '
        $0 ~ /^[[:space:]]*Include[[:space:]]*=[[:space:]]*\/etc\/pacman\.d\/mirrorlist[[:space:]]*$/ {
            print "Include = " artix_mirror
            next
        }
        $0 ~ /^[[:space:]]*Include[[:space:]]*=[[:space:]]*\/etc\/pacman\.d\/mirrorlist-arch[[:space:]]*$/ {
            print "Include = " arch_mirror
            next
        }
        { print }
    ' "${CONFIG_DIR}/pacman.conf" > "$BUILD_PACMAN_CONF"
}

read_package_files() {
    awk '
        /^[[:space:]]*($|#)/ { next }
        { print $1 }
    ' "$@" | sort -u
}

systemd_deny_regex() {
    awk '
        /^[[:space:]]*($|#)/ { next }
        {
            gsub(/[.[\]()*+?{}|^$\\]/, "\\\\&")
            items[++n] = $0
        }
        END {
            printf "^("
            for (i = 1; i <= n; i++) {
                if (i > 1) printf "|"
                printf "%s", items[i]
            }
            printf ")$"
        }
    ' "${CONFIG_DIR}/no-systemd-denylist.txt"
}

check_requested_packages() {
    log "INFO" "Checking package requests against the no-systemd denylist"
    local regex
    regex="$(systemd_deny_regex)"
    local offenders
    offenders="$(
        read_package_files "${PACKAGES_DIR}"/*.list |
            grep -E "$regex" || true
    )"
    [[ -z "$offenders" ]] || die "Forbidden package requested: ${offenders//$'\n'/, }"
}

install_rootfs() {
    log "INFO" "Installing root filesystem"
    local package_list
    mapfile -t package_list < <(read_package_files "${PACKAGES_DIR}"/*.list)

    if have basestrap; then
        basestrap -C "$BUILD_PACMAN_CONF" "$ROOTFS_DIR" "${package_list[@]}" 2>&1 | tee -a "$LOG_FILE"
    else
        pacstrap -C "$BUILD_PACMAN_CONF" "$ROOTFS_DIR" "${package_list[@]}" 2>&1 | tee -a "$LOG_FILE"
    fi
}

mount_api_filesystems() {
    log "INFO" "Mounting API filesystems"
    mount -t proc proc "${ROOTFS_DIR}/proc"
    mount --rbind /sys "${ROOTFS_DIR}/sys"
    mount --make-rslave "${ROOTFS_DIR}/sys"
    mount --rbind /dev "${ROOTFS_DIR}/dev"
    mount --make-rslave "${ROOTFS_DIR}/dev"
    mount --rbind /run "${ROOTFS_DIR}/run"
    mount --make-rslave "${ROOTFS_DIR}/run"
}

chroot_run() {
    chroot "$ROOTFS_DIR" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM:-linux}" \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin \
        /bin/bash -lc "$*"
}

copy_pacman_configuration() {
    log "INFO" "Installing pacman configuration"
    install -Dm644 "${CONFIG_DIR}/pacman.conf" "${ROOTFS_DIR}/etc/pacman.conf"
    install -Dm644 "${CONFIG_DIR}/pacman.d/mirrorlist" "${ROOTFS_DIR}/etc/pacman.d/mirrorlist"
    install -Dm644 "${CONFIG_DIR}/pacman.d/mirrorlist-arch" "${ROOTFS_DIR}/etc/pacman.d/mirrorlist-arch"
}

copy_project_payload() {
    log "INFO" "Installing OperaLinux overlay, Sonnet, and Violin"
    cp -a "${OVERLAY_DIR}/." "$ROOTFS_DIR/"
    install -Dm755 "$SONNET_SRC" "${ROOTFS_DIR}/usr/bin/sonnet"
    install -Dm755 "$VIOLIN_SRC" "${ROOTFS_DIR}/usr/bin/violin"
    install -Dm644 "${CONFIG_DIR}/no-systemd-denylist.txt" "${ROOTFS_DIR}/etc/operalinux/no-systemd-denylist"
    install -Dm644 "${CONFIG_DIR}/mkinitcpio-live.conf" "${ROOTFS_DIR}/etc/mkinitcpio-live.conf"
    install -Dm644 "${CONFIG_DIR}/openrc-services.conf" "${ROOTFS_DIR}/etc/operalinux/openrc-services.conf"
    mkdir -p "${ROOTFS_DIR}/usr/share/operalinux"
    if [[ -d "${PROJECT_DIR}/repo-template" ]]; then
        cp -a "${PROJECT_DIR}/repo-template" "${ROOTFS_DIR}/usr/share/operalinux/repo-template"
    fi
    if [[ -d "${PROJECT_DIR}/releases" ]]; then
        cp -a "${PROJECT_DIR}/releases" "${ROOTFS_DIR}/usr/share/operalinux/releases"
    fi
}

render_branding() {
    log "INFO" "Writing release branding"
    cat > "${ROOTFS_DIR}/etc/os-release" <<EOF_OS
NAME="${NAME}"
PRETTY_NAME="${NAME} ${VERSION_ID} ${VERSION_CODENAME}"
ID=operalinux
ID_LIKE="artix arch"
VERSION="${VERSION_ID} ${VERSION_CODENAME}"
VERSION_ID="${VERSION_ID}"
VERSION_CODENAME="${VERSION_CODENAME}"
ANSI_COLOR="1;36"
HOME_URL="https://github.com/OperaLinux/"
SUPPORT_URL="https://github.com/OperaLinux/build/"
BUG_REPORT_URL="https://github.com/OperaLinux/build/issues"
EOF_OS
    printf 'operalinux\n' > "${ROOTFS_DIR}/etc/hostname"
    cat > "${ROOTFS_DIR}/etc/motd" <<EOF_MOTD
Welcome to OperaLinux ${VERSION_ID} "${VERSION_CODENAME}"
Simple. Recoverable. CLI-first. Gaming ready.

Type 'help' for a list of commands.
EOF_MOTD
    cat > "${ROOTFS_DIR}/etc/issue" <<EOF_ISSUE
OperaLinux ${VERSION_ID} "${VERSION_CODENAME}" \\r on \\m
\\l
EOF_ISSUE
}

configure_openrc() {
    log "INFO" "Configuring OpenRC services"
    chroot_run "sed -i 's/^#rc_parallel=.*/rc_parallel=\"YES\"/' /etc/rc.conf || true"
    while read -r service runlevel; do
        [[ -z "${service:-}" || "${service:0:1}" == "#" ]] && continue
        chroot_run "if [ -x /etc/init.d/${service} ]; then rc-update add '${service}' '${runlevel}'; fi"
    done < "${CONFIG_DIR}/openrc-services.conf"
    chroot_run "passwd -d root >/dev/null 2>&1 || true"
}

install_proton_ge() {
    if [[ "${INSTALL_PROTON_GE:-1}" != "1" ]]; then
        log "INFO" "Skipping Proton GE install because INSTALL_PROTON_GE is not 1"
        return
    fi
    log "INFO" "Installing latest Proton GE"
    chroot_run "update-proton-ge"
}

install_yay() {
    log "INFO" "Installing yay AUR helper"
    if chroot_run "pacman -Si yay >/dev/null 2>&1"; then
        chroot_run "pacman -S --needed --noconfirm yay"
        return
    fi

    chroot_run "useradd -m -r -s /bin/bash build-yay || true"
    chroot_run "printf 'build-yay ALL=(ALL) NOPASSWD: /usr/bin/pacman\n' > /etc/sudoers.d/90-build-yay && chmod 0440 /etc/sudoers.d/90-build-yay"
    chroot_run "cd /tmp && rm -rf yay-bin && runuser -u build-yay -- git clone https://aur.archlinux.org/yay-bin.git"
    chroot_run "cd /tmp/yay-bin && runuser -u build-yay -- makepkg -si --noconfirm --needed"
    chroot_run "rm -rf /tmp/yay-bin /etc/sudoers.d/90-build-yay && userdel -r build-yay || true"
}

configure_initramfs() {
    log "INFO" "Generating live initramfs"
    local kernel_version
    kernel_version="$(find "${ROOTFS_DIR}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep zen | sort -V | tail -n 1 || true)"
    [[ -n "$kernel_version" ]] || die "Could not find an installed linux-zen module directory"
    chroot_run "mkinitcpio -c /etc/mkinitcpio-live.conf -g /boot/initramfs-linux-zen-live.img -k '${kernel_version}'"
}

validate_no_systemd() {
    log "INFO" "Validating no-systemd policy"
    local regex offenders
    regex="$(systemd_deny_regex)"
    offenders="$(chroot "$ROOTFS_DIR" pacman -Qq 2>/dev/null | grep -E "$regex" || true)"
    [[ -z "$offenders" ]] || die "Forbidden systemd package installed: ${offenders//$'\n'/, }"

    local forbidden_ctl="system""ctl"
    [[ ! -e "${ROOTFS_DIR}/usr/bin/${forbidden_ctl}" ]] || die "Forbidden systemd control binary found"
    [[ ! -d "${ROOTFS_DIR}/etc/systemd" ]] || die "Forbidden /etc/systemd directory found"
    [[ ! -d "${ROOTFS_DIR}/usr/lib/systemd/system" ]] || die "Forbidden service directory found"
}

validate_live_users() {
    log "INFO" "Validating live user policy"
    local users
    users="$(awk -F: '$3 >= 1000 && $3 < 60000 { print $1 }' "${ROOTFS_DIR}/etc/passwd" || true)"
    [[ -z "$users" ]] || die "Live ISO must not ship normal users: ${users//$'\n'/, }"
}

build_iso_tree() {
    log "INFO" "Building ISO tree"
    mkdir -p "${ISO_DIR}/boot/grub" "${ISO_DIR}/operalinux/${ARCH}"
    cp "${ROOTFS_DIR}/boot/vmlinuz-linux-zen" "${ISO_DIR}/boot/vmlinuz-linux-zen"
    cp "${ROOTFS_DIR}/boot/initramfs-linux-zen-live.img" "${ISO_DIR}/boot/initramfs-linux-zen-live.img"
    [[ -f "${ROOTFS_DIR}/boot/intel-ucode.img" ]] && cp "${ROOTFS_DIR}/boot/intel-ucode.img" "${ISO_DIR}/boot/intel-ucode.img"
    [[ -f "${ROOTFS_DIR}/boot/amd-ucode.img" ]] && cp "${ROOTFS_DIR}/boot/amd-ucode.img" "${ISO_DIR}/boot/amd-ucode.img"

    sed \
        -e "s/@ISO_LABEL@/${ISO_LABEL}/g" \
        -e "s/@VERSION@/${VERSION_ID}/g" \
        -e "s/@CODENAME@/${VERSION_CODENAME}/g" \
        "${CONFIG_DIR}/grub.cfg" > "${ISO_DIR}/boot/grub/grub.cfg"

    mksquashfs "$ROOTFS_DIR" "${ISO_DIR}/operalinux/${ARCH}/airootfs.sfs" \
        -noappend -comp zstd -Xcompression-level 19 2>&1 | tee -a "$LOG_FILE"
    (cd "${ISO_DIR}/operalinux/${ARCH}" && sha256sum airootfs.sfs > airootfs.sfs.sha256)
}

generate_iso() {
    log "INFO" "Generating ${ISO_PATH}"
    rm -f "$ISO_PATH"
    grub-mkrescue -volid "$ISO_LABEL" -o "$ISO_PATH" "$ISO_DIR" 2>&1 | tee -a "$LOG_FILE"
    [[ -s "$ISO_PATH" ]] || die "ISO was not created"
    log "INFO" "Built ${ISO_PATH}"
}

main() {
    require_root
    check_host_dependencies
    check_requested_packages
    prepare_workspace
    write_build_pacman_conf
    install_rootfs
    mount_api_filesystems
    copy_pacman_configuration
    copy_project_payload
    render_branding
    configure_openrc
    install_proton_ge
    install_yay
    configure_initramfs
    validate_no_systemd
    validate_live_users
    cleanup_mounts
    build_iso_tree
    generate_iso
}

main "$@"
