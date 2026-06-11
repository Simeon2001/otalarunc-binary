#!/usr/bin/env bash
set -euo pipefail

REPO="Simeon2001/otalarunc-binary"
BINARY_NAME="otala-runc"
INSTALL_DIR="/usr/local/bin"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${CYAN}▸ $1${NC}"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo &>/dev/null; then
            warn "Root required. Re-running with sudo..."
            exec sudo bash "$0" "$@"
        else
            error "Please run this script as root (no sudo available)."
        fi
    fi
}

check_systemd() {
    if ! pidof systemd &>/dev/null && ! command -v systemctl &>/dev/null; then
        error "systemd not detected. $BINARY_NAME requires systemd for cgroup management."
    fi
    info "systemd detected."
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="arm" ;;
        *)       error "Unsupported architecture: $(uname -m)" ;;
    esac
    info "Architecture: $ARCH"
}

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO="$ID"
    elif [ -f /etc/debian_version ]; then
        DISTRO="debian"
    elif [ -f /etc/arch-release ]; then
        DISTRO="arch"
    elif [ -f /etc/fedora-release ]; then
        DISTRO="fedora"
    else
        error "Unsupported distribution."
    fi
    info "Distribution: $DISTRO"
}

install_system_deps() {
    step "Installing runtime dependencies..."

    case "$DISTRO" in
        debian|ubuntu|pop|elementary|linuxmint|neon)
            apt-get update -qq
            # passt is only in default repos from Ubuntu 22.04+ / Debian 12+
            # For older Ubuntu (20.04), add the passt PPA
            if [ "$DISTRO" = "ubuntu" ]; then
                UBUNTU_VER=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2 | cut -d'.' -f1)
                if [ "$UBUNTU_VER" -lt 22 ] 2>/dev/null; then
                    warn "Ubuntu $UBUNTU_VER detected. Adding PPA for passt..."
                    apt-get install -y -qq software-properties-common
                    add-apt-repository -y ppa:passt/passt
                    apt-get update -qq
                elif [ "$UBUNTU_VER" -lt 20 ]; then
                    error "Ubuntu $UBUNTU_VER is too old. Minimum supported version is 20.04."
                fi
            fi
            apt-get install -y -qq \
                shadow-utils passt libseccomp2 \
                iptables iproute2 procps
            ;;
        fedora|rhel|centos|ol)
            # Enable EPEL (needed for passt on RHEL/OL/CentOS 9)
            if ! rpm -q epel-release &>/dev/null; then
                RHEL_VER=$(rpm -E %rhel)
                if [ "$DISTRO" = "rhel" ]; then
                    # RHEL requires optional repos enabled via subscription-manager first
                    subscription-manager repos \
                        --enable "codeready-builder-for-rhel-${RHEL_VER}-$(uname -m)-rpms" 2>/dev/null || \
                        warn "Could not enable CodeReady Builder repo (may not be subscribed). Continuing..."
                fi
                dnf install -y \
                    "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${RHEL_VER}.noarch.rpm" || \
                    dnf install -y epel-release || \
                    warn "Could not install EPEL. passt may not be available."
            fi
            dnf install -y \
                shadow-utils passt libseccomp \
                iptables iproute procps-ng
            ;;
        arch|manjaro|endeavouros)
            pacman -Sy --noconfirm \
                shadow passt libseccomp \
                iptables iproute2 procps-ng
            ;;
        suse|opensuse*)
            zypper install -y \
                shadow passt libseccomp2 \
                iptables iproute2 procps
            ;;
        *)
            error "Unsupported distro: $DISTRO"
    esac

    info "Runtime dependencies installed."
}

fetch_latest_version() {
    step "Fetching latest release..."

    if command -v curl &>/dev/null; then
        VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
            | grep '"tag_name"' \
            | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    elif command -v wget &>/dev/null; then
        VERSION=$(wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" \
            | grep '"tag_name"' \
            | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    else
        error "Neither curl nor wget found. Please install one."
    fi

    if [ -z "$VERSION" ]; then
        error "Could not determine latest release version."
    fi

    info "Latest version: $VERSION"
}

download_binary() {
    step "Downloading $BINARY_NAME $VERSION for linux/$ARCH..."

    # Asset name convention: otala-runc-linux-amd64
    ASSET_NAME="${BINARY_NAME}-linux-${ARCH}"
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET_NAME}"

    TMP_BIN=$(mktemp)
    trap 'rm -f "$TMP_BIN"' EXIT

    if command -v curl &>/dev/null; then
        curl -fsSL --progress-bar "$DOWNLOAD_URL" -o "$TMP_BIN"
    else
        wget -q --show-progress "$DOWNLOAD_URL" -O "$TMP_BIN"
    fi

    # Verify checksum if a .sha256 is published alongside the binary
    CHECKSUM_URL="${DOWNLOAD_URL}.sha256"
    if command -v sha256sum &>/dev/null; then
        EXPECTED=$(curl -fsSL "$CHECKSUM_URL" 2>/dev/null | awk '{print $1}') || true
        if [ -n "$EXPECTED" ]; then
            ACTUAL=$(sha256sum "$TMP_BIN" | awk '{print $1}')
            if [ "$ACTUAL" != "$EXPECTED" ]; then
                error "Checksum mismatch! Expected $EXPECTED, got $ACTUAL. Aborting."
            fi
            info "Checksum verified ✓"
        else
            warn "No checksum file found — skipping verification."
        fi
    fi

    chmod 755 "$TMP_BIN"
    mv "$TMP_BIN" "$TMP_BIN.bin"    # keep the trap from removing it before install
    DOWNLOADED_BIN="$TMP_BIN.bin"
}

install_binary() {
    step "Installing to $INSTALL_DIR/$BINARY_NAME..."

    [ -d "$INSTALL_DIR" ] || mkdir -p "$INSTALL_DIR"
    mv "$DOWNLOADED_BIN" "$INSTALL_DIR/$BINARY_NAME"
    chmod 755 "$INSTALL_DIR/$BINARY_NAME"

    info "Installed: $INSTALL_DIR/$BINARY_NAME"
}

verify_install() {
    step "Verifying installation..."

    if command -v "$BINARY_NAME" &>/dev/null; then
        info "$BINARY_NAME is available globally!"
        echo ""
        "$BINARY_NAME" --help 2>/dev/null || "$BINARY_NAME" version 2>/dev/null || true
    else
        warn "$BINARY_NAME installed at $INSTALL_DIR but not found in PATH."
        echo "  export PATH=\$PATH:$INSTALL_DIR"
    fi
}

main() {
    echo ""
    echo "========================================"
    echo "  otala-runc — Container Runtime Installer"
    echo "========================================"
    echo ""

    check_root "$@"
    check_systemd
    detect_arch
    detect_distro
    install_system_deps
    fetch_latest_version
    download_binary
    install_binary
    verify_install

    echo ""
    info "Installation complete! 🏺"
    echo ""
}

main "$@"
