#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="OperaLinux"
ARCH="x86_64"
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${PROJECT_DIR}/config"
PACKAGES_DIR="${PROJECT_DIR}/packages"
OVERLAY_DIR="${PROJECT_DIR}/overlay"
ARCHISO_DIR="${ARCHISO_DIR:-arch}"
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
        grub-mkrescue mksquashfs unsquashfs xorriso mformat
        mount umount chroot cp install mkdir rm stat du
    )

    for cmd in "${required[@]}"; do
        require_command "$cmd"
    done

    if ! have basestrap && ! have pacstrap; then
        die "Need basestrap from Artix or pacstrap from arch-install-scripts"
    fi
}

kill_rootfs_processes() {
    if have fuser; then
        fuser -km "${ROOTFS_DIR}" >/dev/null 2>&1 || true
    fi
}

clean_pacman_keyring_sockets() {
    local keyring_dir="/etc/pacman.d/gnupg"
    [[ -d "$keyring_dir" ]] || return 0
    log "INFO" "Cleaning pacman keyring runtime sockets before rootfs bootstrap"
    if have gpgconf; then
        gpgconf --homedir "$keyring_dir" --kill all >/dev/null 2>&1 || true
    fi
    find "$keyring_dir" -maxdepth 1 -type s -name 'S.gpg-agent*' -delete 2>/dev/null || true
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
            if ! umount -R "$mountpoint" 2>/dev/null; then
                kill_rootfs_processes
                umount -R "$mountpoint" 2>/dev/null || umount -Rl "$mountpoint" 2>/dev/null || true
            fi
        fi
    done
}

cleanup() {
    cleanup_mounts
}
trap cleanup EXIT

prepare_workspace() {
    log "INFO" "Preparing workspace"
    cleanup_mounts
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
    if [[ -s /etc/resolv.conf ]]; then
        install -Dm644 /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"
    fi
}

copy_project_payload() {
    log "INFO" "Installing OperaLinux overlay, Sonnet, and Violin"
    cp -a "${OVERLAY_DIR}/." "$ROOTFS_DIR/"
    find "${ROOTFS_DIR}/usr/local/bin" -maxdepth 1 -type f -exec chmod 0755 {} + 2>/dev/null || true
    find "${ROOTFS_DIR}/opt/operalinux/debian-coreutils/bin" -maxdepth 1 -type f -exec chmod 0755 {} + 2>/dev/null || true
    find "${ROOTFS_DIR}/etc/init.d" -maxdepth 1 -type f -exec chmod 0755 {} + 2>/dev/null || true
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

kernel_module_exists() {
    local kernel_version="$1"
    local module="$2"
    find "${ROOTFS_DIR}/usr/lib/modules/${kernel_version}" -type f \
        \( -name "${module}.ko" -o -name "${module}.ko.*" \) |
        grep -q .
}

write_live_mkinitcpio_config() {
    local kernel_version="$1"
    local module
    local modules=(loop squashfs overlay)

    for module in vboxguest vboxvideo; do
        if kernel_module_exists "$kernel_version" "$module"; then
            modules+=("$module")
        else
            log "WARN" "Kernel module ${module} not found for ${kernel_version}; not adding it to live initramfs"
        fi
    done

    cat > "${ROOTFS_DIR}/etc/mkinitcpio-live.conf" <<EOF_MKINITCPIO
MODULES=(${modules[*]})
BINARIES=()
FILES=()
HOOKS=(base udev modconf block keyboard filesystems archiso)
COMPRESSION="zstd"
EOF_MKINITCPIO
}

purge_systemd_artifacts() {
    log "INFO" "Removing packaged systemd units and runtime directories"
    local path
    local paths=(
        "${ROOTFS_DIR}/etc/systemd"
        "${ROOTFS_DIR}/run/systemd"
        "${ROOTFS_DIR}/usr/lib/systemd"
        "${ROOTFS_DIR}/usr/share/systemd"
        "${ROOTFS_DIR}/var/lib/systemd"
    )

    for path in "${paths[@]}"; do
        if [[ -e "$path" ]]; then
            rm -rf "$path"
        fi
    done
}

install_proton_ge() {
    if [[ "${INSTALL_PROTON_GE:-1}" != "1" ]]; then
        log "INFO" "Skipping Proton GE install because INSTALL_PROTON_GE is not 1"
        return
    fi
    log "INFO" "Installing latest Proton GE"
    if ! chroot_run "chmod 0755 /usr/local/bin/update-proton-ge && /usr/local/bin/update-proton-ge"; then
        log "WARN" "Proton GE install failed, likely because GitHub or DNS is unavailable; continuing ISO build"
    fi
}

disable_chroot_pacman_checkspace() {
    local pacman_conf="${ROOTFS_DIR}/etc/pacman.conf"
    local backup="${ROOTFS_DIR}/etc/pacman.conf.operalinux-build-backup"
    [[ -f "$pacman_conf" ]] || return 0
    cp "$pacman_conf" "$backup"
    sed -i 's/^[[:space:]]*CheckSpace/# CheckSpace disabled during OperaLinux chroot bootstrap/' "$pacman_conf"
}

restore_chroot_pacman_checkspace() {
    local pacman_conf="${ROOTFS_DIR}/etc/pacman.conf"
    local backup="${ROOTFS_DIR}/etc/pacman.conf.operalinux-build-backup"
    if [[ -f "$backup" ]]; then
        mv "$backup" "$pacman_conf"
    fi
}

install_yay() {
    log "INFO" "Installing yay AUR helper"
    disable_chroot_pacman_checkspace
    local status=0

    if chroot_run "pacman -Si yay >/dev/null 2>&1"; then
        chroot_run "pacman -S --needed --noconfirm yay" || status=$?
        restore_chroot_pacman_checkspace
        return "$status"
    fi

    chroot_run "useradd -m -r -s /bin/bash build-yay || true" || status=$?
    if [[ "$status" -eq 0 ]]; then
        chroot_run "printf 'build-yay ALL=(ALL) NOPASSWD: /usr/bin/pacman\n' > /etc/sudoers.d/90-build-yay && chmod 0440 /etc/sudoers.d/90-build-yay" || status=$?
    fi
    if [[ "$status" -eq 0 ]]; then
        chroot_run "cd /tmp && rm -rf yay-bin && runuser -u build-yay -- git clone https://aur.archlinux.org/yay-bin.git" || status=$?
    fi
    if [[ "$status" -eq 0 ]]; then
        chroot_run "cd /tmp/yay-bin && runuser -u build-yay -- makepkg -s --noconfirm --needed" || status=$?
    fi
    if [[ "$status" -eq 0 ]]; then
        chroot_run "pacman -U --noconfirm /tmp/yay-bin/yay-bin-*.pkg.tar.*" || status=$?
    fi
    chroot_run "rm -rf /tmp/yay-bin /etc/sudoers.d/90-build-yay && userdel -r build-yay || true"
    restore_chroot_pacman_checkspace
    return "$status"
}

configure_initramfs() {
    log "INFO" "Generating live initramfs"
    local kernel_version
    kernel_version="$(find "${ROOTFS_DIR}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep zen | sort -V | tail -n 1 || true)"
    [[ -n "$kernel_version" ]] || die "Could not find an installed linux-zen module directory"
    write_live_mkinitcpio_config "$kernel_version"
    chroot_run "mkinitcpio -P"
    chroot_run "mkinitcpio -c /etc/mkinitcpio-live.conf -g /boot/initramfs-linux-zen-live.img -k '${kernel_version}'"
}

validate_initramfs() {
    log "INFO" "Validating live initramfs modules"
    local initramfs="${ROOTFS_DIR}/boot/initramfs-linux-zen-live.img"
    [[ -s "$initramfs" ]] || die "Live initramfs missing: $initramfs"

    local contents
    contents="$(chroot "$ROOTFS_DIR" /usr/bin/lsinitcpio /boot/initramfs-linux-zen-live.img)"
    for module in loop squashfs overlay; do
        grep -Eq "(^|/)${module}\\.ko(\\.|$)" <<<"$contents" ||
            die "Live initramfs does not contain required module: ${module}"
    done
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
    local archiso_tree="${ISO_DIR}/${ARCHISO_DIR}/${ARCH}"
    mkdir -p "${ISO_DIR}/boot/grub" "$archiso_tree"
    cp "${ROOTFS_DIR}/boot/vmlinuz-linux-zen" "${ISO_DIR}/boot/vmlinuz-linux-zen"
    cp "${ROOTFS_DIR}/boot/initramfs-linux-zen-live.img" "${ISO_DIR}/boot/initramfs-linux-zen-live.img"
    [[ -f "${ROOTFS_DIR}/boot/intel-ucode.img" ]] && cp "${ROOTFS_DIR}/boot/intel-ucode.img" "${ISO_DIR}/boot/intel-ucode.img"
    [[ -f "${ROOTFS_DIR}/boot/amd-ucode.img" ]] && cp "${ROOTFS_DIR}/boot/amd-ucode.img" "${ISO_DIR}/boot/amd-ucode.img"

    sed \
        -e "s/@ISO_LABEL@/${ISO_LABEL}/g" \
        -e "s/@ARCHISO_DIR@/${ARCHISO_DIR}/g" \
        -e "s/@VERSION@/${VERSION_ID}/g" \
        -e "s/@CODENAME@/${VERSION_CODENAME}/g" \
        "${CONFIG_DIR}/grub.cfg" > "${ISO_DIR}/boot/grub/grub.cfg"

    mksquashfs "$ROOTFS_DIR" "${archiso_tree}/airootfs.sfs" \
        -noappend -comp zstd -Xcompression-level 19 2>&1 | tee -a "$LOG_FILE"
    unsquashfs -s "${archiso_tree}/airootfs.sfs" 2>&1 | tee -a "$LOG_FILE" >/dev/null
    (cd "$archiso_tree" && sha256sum airootfs.sfs > airootfs.sfs.sha256)
    log "INFO" "airootfs.sfs size: $(du -h "${archiso_tree}/airootfs.sfs" | awk '{print $1}')"
}

validate_iso_tree() {
    log "INFO" "Validating ISO boot assets and archiso layout"
    local kernel="${ISO_DIR}/boot/vmlinuz-linux-zen"
    local initramfs="${ISO_DIR}/boot/initramfs-linux-zen-live.img"
    local squashfs="${ISO_DIR}/${ARCHISO_DIR}/${ARCH}/airootfs.sfs"
    local grub_cfg="${ISO_DIR}/boot/grub/grub.cfg"

    [[ -s "$kernel" ]] || die "Missing kernel in ISO tree: $kernel"
    [[ -s "$initramfs" ]] || die "Missing initramfs in ISO tree: $initramfs"
    [[ -s "$squashfs" ]] || die "Missing squashfs in ISO tree: $squashfs"
    [[ "$(stat -c '%u:%g' "$squashfs")" == "0:0" ]] ||
        die "Squashfs must be owned by root:root: $squashfs"
    [[ -s "$grub_cfg" ]] || die "Missing GRUB config in ISO tree: $grub_cfg"
    [[ "$ARCHISO_DIR" == "arch" || "$ARCHISO_DIR" == "archiso" ]] ||
        die "ARCHISO_DIR must be arch or archiso, got: $ARCHISO_DIR"
    [[ "$ISO_LABEL" =~ ^[A-Z0-9_]+$ ]] || die "Invalid ISO label: $ISO_LABEL"
    [[ "${#ISO_LABEL}" -le 32 ]] || die "ISO label is too long for ISO9660: $ISO_LABEL"

    grep -Fq "archisolabel=${ISO_LABEL}" "$grub_cfg" ||
        die "GRUB archisolabel does not match ISO_LABEL=${ISO_LABEL}"
    grep -Fq "archisobasedir=${ARCHISO_DIR}" "$grub_cfg" ||
        die "GRUB archisobasedir does not match ARCHISO_DIR=${ARCHISO_DIR}"
    grep -Fq -- "--label ${ISO_LABEL}" "$grub_cfg" ||
        die "GRUB search label does not match ISO_LABEL=${ISO_LABEL}"
    grep -Fq '@ISO_LABEL@' "$grub_cfg" && die "Unrendered ISO label placeholder remains in GRUB config"
    grep -Fq '@ARCHISO_DIR@' "$grub_cfg" && die "Unrendered archiso dir placeholder remains in GRUB config"
    unsquashfs -s "$squashfs" >/dev/null ||
        die "Invalid squashfs image: $squashfs"
}

generate_iso() {
    log "INFO" "Generating ${ISO_PATH}"
    rm -f "$ISO_PATH"
    grub-mkrescue -iso-level 3 -volid "$ISO_LABEL" -o "$ISO_PATH" "$ISO_DIR" 2>&1 | tee -a "$LOG_FILE"
    [[ -s "$ISO_PATH" ]] || die "ISO was not created"
    log "INFO" "Built ${ISO_PATH}"
}

validate_generated_iso() {
    log "INFO" "Validating generated ISO volume label"
    if ! xorriso -indev "$ISO_PATH" -pvd_info 2>/dev/null | grep -Fq "Volume Id    : ${ISO_LABEL}"; then
        rm -f "$ISO_PATH"
        die "Generated ISO volume label does not match ${ISO_LABEL}"
    fi
}

main() {
    require_root
    check_host_dependencies
    check_requested_packages
    prepare_workspace
    write_build_pacman_conf
    clean_pacman_keyring_sockets
    install_rootfs
    mount_api_filesystems
    copy_pacman_configuration
    copy_project_payload
    render_branding
    configure_openrc
    install_proton_ge
    install_yay
    purge_systemd_artifacts
    configure_initramfs
    validate_initramfs
    validate_no_systemd
    validate_live_users
    cleanup_mounts
    build_iso_tree
    validate_iso_tree
    generate_iso
    validate_generated_iso
}

main "$@"
