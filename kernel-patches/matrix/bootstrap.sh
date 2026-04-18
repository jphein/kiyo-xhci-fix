#!/bin/bash
# Bootstrap a stock Ubuntu install to run the Kiyo Pro test matrix.
#
# Phases (idempotent — safe to re-run):
#   1. apt deps
#   2. clone kiyo-xhci-fix (if not already present)
#   3. build patched uvcvideo module (CTRL_THROTTLE)
#   4. fetch kernel source, apply michal-xhci-test.patch, build kernel
#   5. install systemd queue-processor unit
#   6. generate queue.txt
#
# Assumptions:
#   - Ubuntu 24.04, 24.10, or 25.04 (anything that can run a 6.17 kernel)
#   - User 'jp' exists with passwordless sudo (or script is run as root
#     and ownership is fixed up at the end)
#   - Internet access for apt + git + kernel source
#   - A Razer Kiyo Pro plugged in (not checked at bootstrap time — only
#     at runner time)
#
# Usage:
#   bash bootstrap.sh             # full bootstrap
#   bash bootstrap.sh --phase=3   # run phase 3 only (e.g. rebuild uvcvideo)
#   bash bootstrap.sh --help

set -euo pipefail

RUN_USER="${SUDO_USER:-$USER}"
[ -z "$RUN_USER" ] && RUN_USER=jp

REPO_URL="https://github.com/jphein/kiyo-xhci-fix.git"
REPO_DIR="/home/$RUN_USER/Projects/kiyo-xhci-fix"
MATRIX_DIR="$REPO_DIR/kernel-patches/matrix"

PHASE=""
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            sed -n '2,28p' "$0"; exit 0 ;;
        --phase=*)
            PHASE="${arg#--phase=}" ;;
    esac
done

log()   { printf '\n\033[1;36m[bootstrap]\033[0m %s\n' "$*"; }
warn()  { printf '\n\033[1;33m[bootstrap] WARN:\033[0m %s\n' "$*"; }
die()   { printf '\n\033[1;31m[bootstrap] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

run_phase() {
    local n="$1"
    [ -n "$PHASE" ] && [ "$PHASE" != "$n" ] && return 1
    return 0
}

# ========================================================================
# Phase 1: apt deps
# ========================================================================
if run_phase 1; then
    log "Phase 1: installing apt dependencies"
    sudo apt-get update
    sudo apt-get install -y \
        git build-essential bc kmod cpio flex bison \
        libelf-dev libssl-dev libncurses-dev \
        dwarves rsync \
        linux-headers-"$(uname -r)" \
        v4l-utils ffmpeg \
        python3 python3-venv \
        fakeroot dpkg-dev \
        curl ca-certificates
    # Ubuntu HWE / 6.17 access
    if ! apt list --installed 2>/dev/null | grep -q 'linux-image-.*generic-hwe'; then
        warn "No HWE kernel installed — you may need to install it manually"
        warn "  sudo apt install linux-generic-hwe-24.04"
    fi
fi

# ========================================================================
# Phase 2: clone repo (if not present)
# ========================================================================
if run_phase 2; then
    log "Phase 2: ensuring repo at $REPO_DIR"
    if [ ! -d "$REPO_DIR/.git" ]; then
        sudo -u "$RUN_USER" -H mkdir -p "$(dirname "$REPO_DIR")"
        sudo -u "$RUN_USER" -H git clone "$REPO_URL" "$REPO_DIR"
    else
        log "Repo already present — pulling latest"
        sudo -u "$RUN_USER" -H git -C "$REPO_DIR" pull --ff-only || \
            warn "git pull failed — continuing with whatever is checked out"
    fi
fi

# ========================================================================
# Phase 3: build patched uvcvideo module
# ========================================================================
if run_phase 3; then
    log "Phase 3: building patched uvcvideo module (CTRL_THROTTLE)"
    if [ -f "$REPO_DIR/kernel-patches/uvcvideo-patched.ko" ]; then
        log "uvcvideo-patched.ko already exists — rebuilding anyway"
    fi
    (cd "$REPO_DIR/kernel-patches" && sudo -u "$RUN_USER" -H bash ./build-uvc-module.sh)
    # Sanity check
    [ -f "$REPO_DIR/kernel-patches/uvcvideo-patched.ko" ] || \
        die "uvcvideo-patched.ko not produced"
fi

# ========================================================================
# Phase 4: build Michal-patched kernel
# ========================================================================
if run_phase 4; then
    log "Phase 4: building kernel with michal-xhci-test.patch"

    CURRENT_KVER=$(uname -r)
    # Parse major.minor from 6.17.0-20-generic -> 6.17
    KBASE=$(echo "$CURRENT_KVER" | awk -F. '{print $1"."$2}')
    MICHAL_TAG="michal-xhci-test"
    BUILT_KERNEL_PKG="/tmp/kiyo-matrix-kernel-built"

    if [ -f "$BUILT_KERNEL_PKG" ] && dpkg -l | grep -q "linux-image-${KBASE}.*${MICHAL_TAG}"; then
        log "Michal-patched kernel already installed — skipping build"
    else
        BUILD_DIR="/tmp/kiyo-kbuild"
        sudo -u "$RUN_USER" -H mkdir -p "$BUILD_DIR"
        cd "$BUILD_DIR"

        # Prefer Ubuntu's linux-source package for the current tree
        SRC_PKG="linux-source-${KBASE}"
        if ! apt list --installed 2>/dev/null | grep -q "$SRC_PKG"; then
            log "Installing $SRC_PKG"
            sudo apt-get install -y "$SRC_PKG" || \
                warn "$SRC_PKG not available — falling back to kernel.org tarball"
        fi

        SRC_TAR=$(ls /usr/src/${SRC_PKG}.tar* 2>/dev/null | head -n1 || true)
        if [ -z "$SRC_TAR" ]; then
            log "Downloading upstream kernel source for $KBASE"
            KVER_FULL=$(curl -sL "https://www.kernel.org/releases.json" | \
                python3 -c "import sys,json; r=json.load(sys.stdin); \
                print([x['version'] for x in r['releases'] if x['version'].startswith('$KBASE.')][0])")
            curl -sL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KVER_FULL}.tar.xz" \
                -o "linux-${KVER_FULL}.tar.xz"
            tar -xf "linux-${KVER_FULL}.tar.xz"
            KSRC_DIR="$BUILD_DIR/linux-${KVER_FULL}"
        else
            log "Extracting $SRC_TAR"
            sudo -u "$RUN_USER" -H tar -xf "$SRC_TAR" -C "$BUILD_DIR"
            KSRC_DIR=$(ls -d "$BUILD_DIR"/linux-source-*/ 2>/dev/null | head -n1 | sed 's:/$::')
            [ -z "$KSRC_DIR" ] && KSRC_DIR=$(ls -d "$BUILD_DIR"/linux-*/ | head -n1 | sed 's:/$::')
        fi

        log "Kernel source at $KSRC_DIR"
        cd "$KSRC_DIR"

        # Apply Michal's patch
        log "Applying michal-xhci-test.patch"
        patch -p1 -N < "$REPO_DIR/kernel-patches/michal-xhci-test.patch" || \
            warn "Patch already applied or failed — continuing"

        # Copy current config as baseline, then set LOCALVERSION
        cp "/boot/config-$CURRENT_KVER" .config
        scripts/config --set-str LOCALVERSION "-${MICHAL_TAG}"
        scripts/config --disable DEBUG_INFO
        scripts/config --disable DEBUG_INFO_DWARF5
        scripts/config --disable DEBUG_INFO_BTF
        scripts/config --disable SYSTEM_TRUSTED_KEYS
        scripts/config --disable SYSTEM_REVOCATION_KEYS
        scripts/config --enable  LOCALVERSION_AUTO=n || true
        yes '' | make olddefconfig

        log "Building kernel (this will take a while)"
        make -j"$(nproc)" bindeb-pkg LOCALVERSION="-${MICHAL_TAG}" 2>&1 | tail -80

        log "Installing built kernel packages"
        sudo dpkg -i ../linux-image-*${MICHAL_TAG}*.deb \
                     ../linux-headers-*${MICHAL_TAG}*.deb || \
            warn "dpkg -i had errors — check output"
        sudo update-grub
        touch "$BUILT_KERNEL_PKG"
    fi
fi

# ========================================================================
# Phase 5: install systemd queue-processor unit
# ========================================================================
if run_phase 5; then
    log "Phase 5: installing matrix-queue systemd unit"
    # Generate a unit with the real user baked in
    sed "s|User=jp|User=$RUN_USER|g; s|Group=jp|Group=$RUN_USER|g; \
         s|/home/jp|/home/$RUN_USER|g" \
        "$MATRIX_DIR/matrix-queue.service" | \
        sudo tee /etc/systemd/system/matrix-queue.service >/dev/null
    sudo systemctl daemon-reload
    log "Unit installed. Enable with: sudo systemctl enable matrix-queue.service"
    log "(Not auto-enabled — you probably want to hand-run the first few reps to eyeball output)"
fi

# ========================================================================
# Phase 6: generate queue
# ========================================================================
if run_phase 6; then
    log "Phase 6: generating queue.txt (5 reps per cell, 50 runs total)"
    sudo -u "$RUN_USER" -H bash "$MATRIX_DIR/setup.sh" 5
fi

# ========================================================================
# Grub help
# ========================================================================
log "Bootstrap complete"
cat <<EOF

=====================================================================
NEXT STEPS

Four boot configurations are needed. Using grub, you have two options:

  Option 1 — Named menu entries (recommended):
    Add these to /etc/grub.d/40_custom (adjust kernel paths):

    menuentry 'Matrix A: stock, no NO_LPM' { ... }
    menuentry 'Matrix B: stock, NO_LPM'    { linux ... usbcore.quirks=1532:0e05:k }
    menuentry 'Matrix C: michal, no NO_LPM'{ linux /boot/vmlinuz-*-${MICHAL_TAG:-michal} ... }
    menuentry 'Matrix D: michal, NO_LPM'   { linux /boot/vmlinuz-*-${MICHAL_TAG:-michal} ... usbcore.quirks=1532:0e05:k }

  Option 2 — Manually edit /etc/default/grub between configs:
    GRUB_CMDLINE_LINUX_DEFAULT="quiet splash usbcore.quirks=1532:0e05:k"
    sudo update-grub && sudo reboot

RUNNING THE MATRIX

  1. Boot into config A (stock, no NO_LPM)
  2. Make sure Kiyo Pro is plugged in and /dev/video0 works
  3. Run by hand for the first rep to verify detection:
       bash $MATRIX_DIR/queue.sh
  4. Once confident, enable auto-run:
       sudo systemctl enable --now matrix-queue.service
  5. Monitor from SSH:
       tail -f $MATRIX_DIR/results/queue.log
  6. Pause at any time:
       touch /tmp/kiyo-matrix-pause
  7. When queue drains:
       bash $MATRIX_DIR/summary.sh

The queue is pre-ordered cell 1 → 5. Each config switch requires a
reboot into the right grub entry. Within a config (e.g. cell 3 → 4),
the runner handles DKMS module swap itself — no reboot needed.

For full reference: cat $MATRIX_DIR/README.md
=====================================================================
EOF
