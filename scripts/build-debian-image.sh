#!/usr/bin/env bash
# build-debian-image.sh — Build Debian rootfs + kernel for DevBox crosvm VM
#
# Produces (in ./output/):
#   debian-rootfs-aarch64.img.gz   — Debian bookworm root filesystem image
#   debian-rootfs-x86_64.img.gz    — Same for x86_64
#   vmlinuz-aarch64                — Kernel for aarch64
#   vmlinuz-x86_64                 — Kernel for x86_64
#   initrd-aarch64.img             — Initrd for aarch64
#   initrd-x86_64.img              — Initrd for x86_64
#
# Requirements (run on a Debian/Ubuntu host or in CI):
#   sudo apt install debootstrap qemu-user-static binfmt-support
#                    libguestfs-tools linux-image-arm64 linux-image-amd64
#
# Upload output/ to GitHub Releases as bootstrap-<version> so DevBox can
# download at first launch via devbox-second-stage.sh.
#
# Usage:
#   ./scripts/build-debian-image.sh [aarch64|x86_64|all]
#   Default: all

set -euo pipefail

ARCH="${1:-all}"
OUTPUT_DIR="$(pwd)/output"
ROOTFS_SIZE="4G"          # raw image size (gets sparse-compressed with gzip)
DEBIAN_SUITE="bookworm"

mkdir -p "$OUTPUT_DIR"

log()  { echo "[DevBox] $*"; }
die()  { echo "[DevBox][ERROR] $*" >&2; exit 1; }

check_deps() {
    local missing=()
    for cmd in debootstrap qemu-img guestfish; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing: ${missing[*]}. Install with: sudo apt install debootstrap libguestfs-tools qemu-utils"
    fi
}

# ── Build rootfs for one arch ──────────────────────────────────────────────────
build_rootfs() {
    local arch="$1"          # aarch64 | x86_64
    local deb_arch           # Debian arch name
    local qemu_arch          # qemu-user-static binary name

    case "$arch" in
        aarch64) deb_arch="arm64";  qemu_arch="aarch64" ;;
        x86_64)  deb_arch="amd64";  qemu_arch="" ;;
        *) die "Unknown arch: $arch" ;;
    esac

    local raw_img="$OUTPUT_DIR/debian-rootfs-${arch}.img"
    local gz_img="${raw_img}.gz"

    log "Building Debian ${DEBIAN_SUITE} rootfs for ${arch}..."

    # ── 1. Create empty raw image ──────────────────────────────────────────────
    qemu-img create -f raw "$raw_img" "$ROOTFS_SIZE"
    mkfs.ext4 -F -L "debian-devbox" "$raw_img"

    # ── 2. Mount and debootstrap ───────────────────────────────────────────────
    local mnt
    mnt=$(mktemp -d)
    sudo mount -o loop "$raw_img" "$mnt"

    # Copy qemu-user-static for cross-arch debootstrap
    if [[ -n "$qemu_arch" ]]; then
        sudo cp "/usr/bin/qemu-${qemu_arch}-static" "$mnt/usr/bin/" 2>/dev/null || true
    fi

    log "Running debootstrap (${deb_arch})..."
    sudo debootstrap \
        --arch="$deb_arch" \
        --include="openssh-server,curl,socat,sudo,bash,zsh,coreutils,util-linux,net-tools,iproute2,procps,less,vim-tiny,python3,python3-pip,git,wget,ca-certificates" \
        "$DEBIAN_SUITE" \
        "$mnt" \
        "https://deb.debian.org/debian"

    # ── 3. Configure the rootfs ────────────────────────────────────────────────
    log "Configuring rootfs..."

    # Hostname
    echo "devbox" | sudo tee "$mnt/etc/hostname" >/dev/null

    # Network (virtio eth0 via DHCP)
    sudo tee "$mnt/etc/network/interfaces" >/dev/null <<'NET'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
NET

    # Root password (devbox) + enable root SSH
    sudo chroot "$mnt" /bin/bash -c "echo 'root:devbox' | chpasswd"
    sudo sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' "$mnt/etc/ssh/sshd_config"
    sudo sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' "$mnt/etc/ssh/sshd_config"

    # Serial console for crosvm
    sudo chroot "$mnt" /bin/bash -c "systemctl enable serial-getty@ttyS0.service" 2>/dev/null || true

    # Enable SSH on boot
    sudo chroot "$mnt" /bin/bash -c "systemctl enable ssh" 2>/dev/null || true

    # ── Install starship prompt ────────────────────────────────────────────────
    log "Installing starship prompt..."
    # Download the starship install script and run it inside the chroot
    sudo chroot "$mnt" /bin/bash -c "
        curl -sS https://starship.rs/install.sh -o /tmp/starship-install.sh
        chmod +x /tmp/starship-install.sh
        /tmp/starship-install.sh --yes --bin-dir /usr/local/bin
        rm -f /tmp/starship-install.sh
    " 2>/dev/null || log "WARNING: starship install failed — run manually: curl -sS https://starship.rs/install.sh | sh"

    # ── Configure zsh as default shell for root ────────────────────────────────
    log "Configuring zsh + starship for root..."
    sudo chroot "$mnt" /bin/bash -c "chsh -s /bin/zsh root" 2>/dev/null || true

    # .zshrc — starship init + sensible defaults
    sudo tee "$mnt/root/.zshrc" >/dev/null << 'ZSHRC'
# DevBox zsh config
export TERM="xterm-256color"
export LANG="en_US.UTF-8"
export EDITOR="vim"

# History
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE

# Auto-cd, extended glob, no beep
setopt AUTO_CD EXTENDED_GLOB NO_BEEP

# Completion
autoload -Uz compinit && compinit

# Key bindings (emacs style)
bindkey -e
bindkey '^[[A' history-search-backward
bindkey '^[[B' history-search-forward

# Aliases
alias ls='ls --color=auto'
alias ll='ls -lah'
alias la='ls -A'
alias grep='grep --color=auto'

# Starship prompt
eval "$(starship init zsh)"
ZSHRC

    # ── virtio-fs auto-mount for DevBox shared dir ─────────────────────────
    # crosvm mounts $PREFIX/share/devbox as virtio-fs tag "devbox"
    # This makes opensandbox + mobile-agent available at /mnt/devbox/
    # without being baked into the image — update via bootstrap zip only.
    sudo mkdir -p "$mnt/mnt/devbox"

    # /etc/fstab entry — mounts at boot
    echo "devbox  /mnt/devbox  virtiofs  defaults,nofail  0  0" \
        | sudo tee -a "$mnt/etc/fstab" >/dev/null

    # systemd mount unit for early boot (fstab alone is sometimes too late)
    sudo tee "$mnt/etc/systemd/system/mnt-devbox.mount" >/dev/null << 'UNIT'
[Unit]
Description=DevBox virtio-fs shared directory
DefaultDependencies=no
After=local-fs-pre.target
Before=local-fs.target

[Mount]
What=devbox
Where=/mnt/devbox
Type=virtiofs
Options=defaults

[Install]
WantedBy=local-fs.target
UNIT
    sudo chroot "$mnt" /bin/bash -c "systemctl enable mnt-devbox.mount" 2>/dev/null || true

    # Remove qemu static binary from rootfs
    [[ -n "$qemu_arch" ]] && sudo rm -f "$mnt/usr/bin/qemu-${qemu_arch}-static"

    sudo umount "$mnt"
    rmdir "$mnt"

    # ── 4. Compress ───────────────────────────────────────────────────────────
    log "Compressing rootfs (${arch})..."
    gzip -9 -c "$raw_img" > "$gz_img"
    rm -f "$raw_img"
    log "Done: $gz_img ($(du -sh "$gz_img" | cut -f1))"
}

# ── Extract kernel + initrd from Debian package ───────────────────────────────
extract_kernel() {
    local arch="$1"
    local deb_arch

    case "$arch" in
        aarch64) deb_arch="arm64" ;;
        x86_64)  deb_arch="amd64" ;;
    esac

    log "Extracting kernel for ${arch}..."

    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Download linux-image .deb directly from Debian mirror (works on Ubuntu runners)
    local pkg_name="linux-image-${deb_arch}"
    local debian_mirror="https://deb.debian.org/debian"

    log "Fetching package list for ${deb_arch} from Debian ${DEBIAN_SUITE}..."
    local pkg_list_url="${debian_mirror}/dists/${DEBIAN_SUITE}/main/binary-${deb_arch}/Packages.gz"
    local pkg_list="${tmp_dir}/Packages"

    if curl --fail --silent --location "${pkg_list_url}" | gunzip -c > "${pkg_list}" 2>/dev/null; then
        # linux-image-arm64/amd64 is a meta package - find the actual versioned kernel package
        local deb_path
        deb_path=$(grep -A 20 "^Package: linux-image-[0-9].*-${deb_arch}$" "${pkg_list}" | grep "^Filename:" | head -1 | awk '{print $2}')

        # Fallback to meta package if versioned not found
        if [[ -z "$deb_path" ]]; then
            deb_path=$(grep -A 20 "^Package: ${pkg_name}$" "${pkg_list}" | grep "^Filename:" | head -1 | awk '{print $2}')
        fi

        if [[ -n "$deb_path" ]]; then
            local deb_url="${debian_mirror}/${deb_path}"
            local deb_file="${tmp_dir}/${pkg_name}.deb"
            log "Downloading ${deb_url}..."
            if curl --fail --silent --location -o "${deb_file}" "${deb_url}"; then
                dpkg-deb -x "${deb_file}" "${tmp_dir}"
                rm -f "${deb_file}"
            fi
        fi
    fi

    # Find vmlinuz and initrd
    local vmlinuz
    vmlinuz=$(find "$tmp_dir" -name "vmlinuz*" | head -1)
    local initrd
    initrd=$(find "$tmp_dir" -name "initrd*" | head -1)

    if [[ -n "$vmlinuz" ]]; then
        cp "$vmlinuz" "$OUTPUT_DIR/vmlinuz-${arch}"
        log "Kernel: $OUTPUT_DIR/vmlinuz-${arch}"
    else
        log "WARNING: Could not extract vmlinuz for ${arch}. Provide manually."
        # Create placeholder so devbox-second-stage.sh can detect missing
        echo "PLACEHOLDER - replace with real kernel" > "$OUTPUT_DIR/vmlinuz-${arch}"
    fi

    if [[ -n "$initrd" ]]; then
        cp "$initrd" "$OUTPUT_DIR/initrd-${arch}.img"
        log "Initrd: $OUTPUT_DIR/initrd-${arch}.img"
    else
        log "WARNING: Could not extract initrd for ${arch}. Provide manually."
        echo "PLACEHOLDER - replace with real initrd" > "$OUTPUT_DIR/initrd-${arch}.img"
    fi

    rm -rf "$tmp_dir"
}

# ── Main ───────────────────────────────────────────────────────────────────────

check_deps

case "$ARCH" in
    aarch64)
        build_rootfs aarch64
        extract_kernel aarch64
        ;;
    x86_64)
        build_rootfs x86_64
        extract_kernel x86_64
        ;;
    all)
        build_rootfs aarch64
        extract_kernel aarch64
        build_rootfs x86_64
        extract_kernel x86_64
        ;;
    *)
        die "Usage: $0 [aarch64|x86_64|all]"
        ;;
esac

log ""
log "Output files:"
ls -lh "$OUTPUT_DIR"/
log ""
log "Upload these to GitHub Releases (mixos-go/devbox-packages) as:"
log "  bootstrap-<version> release tag"
log ""
log "Files expected by devbox-second-stage.sh:"
log "  debian-rootfs-aarch64.img.gz"
log "  debian-rootfs-x86_64.img.gz"
log "  vmlinuz-aarch64"
log "  vmlinuz-x86_64"
log "  initrd-aarch64.img"
log "  initrd-x86_64.img"

