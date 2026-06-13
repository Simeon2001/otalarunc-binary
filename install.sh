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
                passwd uidmap passt libseccomp2 \
                iptables iproute2 procps apparmor apparmor-utils
            ;;
        fedora|rhel|centos|ol)
            # Enable EPEL (needed for passt on RHEL/OL/CentOS 9)
            if ! rpm -q epel-release &>/dev/null; then
                RHEL_VER=$(rpm -E %rhel)
                if [ "$DISTRO" = "ol" ]; then
                    # Oracle Linux has its own EPEL mirror — much faster on OCI
                    dnf install -y oracle-epel-release-el${RHEL_VER} || \
                    dnf install -y epel-release || \
                    warn "Could not install EPEL. passt may not be available."
                elif [ "$DISTRO" = "rhel" ]; then
                    subscription-manager repos \
                        --enable "codeready-builder-for-rhel-${RHEL_VER}-$(uname -m)-rpms" 2>/dev/null || \
                        warn "Could not enable CodeReady Builder repo. Continuing..."
                    dnf install -y \
                        "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${RHEL_VER}.noarch.rpm" || \
                        warn "Could not install EPEL. passt may not be available."
                else
                    dnf install -y epel-release || \
                    warn "Could not install EPEL. passt may not be available."
                fi
            fi
            dnf install -y \
                shadow-utils newuidmap passt libseccomp \
                iptables iproute procps-ng
            ;;
        arch|manjaro|endeavouros|garuda)
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

setup_apparmor() {
    # Only applies to distros using AppArmor
    case "$DISTRO" in
        debian|ubuntu|pop|elementary|linuxmint|neon|suse|opensuse*) ;;
        *) return 0 ;;  # Skip for non-AppArmor distros
    esac

    if ! command -v apparmor_parser &>/dev/null; then
        warn "apparmor_parser not found — skipping AppArmor profile setup."
        return 0
    fi

    step "Setting up AppArmor profile for $BINARY_NAME..."

    # Resolve the real install path
    BINARY_PATH="${INSTALL_DIR}/${BINARY_NAME}"
    PROFILE_PATH="/etc/apparmor.d/${BINARY_NAME}"

    cat > "$PROFILE_PATH" <<APPARMOR_PROFILE
# AppArmor profile for $BINARY_NAME (rootless container runtime)
# Generated by install.sh — do not edit manually

abi <abi/4.0>,

profile $BINARY_NAME $BINARY_PATH flags=(unconfined) {
  userns,

  # Allow re-exec via /proc/self/exe (required for namespace setup)
  /proc/self/exe mr,

  # Process and system info
  /proc/*/status r,
  /proc/*/attr/current r,
  /proc/sys/kernel/** r,
  /proc/** r,

  # cgroup v2 (for memory/cpu limits via systemd or cgroupfs)
  /sys/fs/cgroup/** rw,

  # UID/GID mapping helpers
  /usr/bin/newuidmap Px,
  /usr/bin/newgidmap Px,

  # Network helpers (pasta / slirp4netns)
  /usr/bin/pasta Px,
  /usr/bin/slirp4netns Px,

  # Filesystem access for container root setup
  /tmp/** rwk,
  /run/user/** rwk,
  /home/** r,

  # Executing the contained command
  /** px,
}
APPARMOR_PROFILE

    # Load the profile immediately
    if apparmor_parser -r "$PROFILE_PATH" 2>/dev/null; then
        info "AppArmor profile loaded: $PROFILE_PATH"
    else
        warn "Could not load AppArmor profile (may need reboot or older AppArmor version)."
        warn "Profile written to $PROFILE_PATH — it will load on next boot."
    fi

    # On Ubuntu 24.04+ specifically: also relax the userns sysctl
    # (AppArmor profile above handles per-binary; sysctl is the global gate)
    if [ "$DISTRO" = "ubuntu" ]; then
        UBUNTU_VER=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2 | cut -d'.' -f1)
        if [ "${UBUNTU_VER}" -ge 24 ] 2>/dev/null; then
            SYSCTL_CONF="/etc/sysctl.d/99-${BINARY_NAME}-userns.conf"
            if [ ! -f "$SYSCTL_CONF" ]; then
                echo "kernel.apparmor_restrict_unprivileged_userns=0" > "$SYSCTL_CONF"
                sysctl --system -q 2>/dev/null || true
                info "Disabled apparmor_restrict_unprivileged_userns for $BINARY_NAME."
            else
                info "sysctl config already exists at $SYSCTL_CONF — skipping."
            fi
        fi
    fi
}

setup_selinux() {
    # Only applies to SELinux distros (Fedora, RHEL, CentOS)
    case "$DISTRO" in
        fedora|rhel|centos|ol) ;;
        *) return 0 ;;
    esac

    if ! command -v getenforce &>/dev/null; then
        return 0  # SELinux not present
    fi

    SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Disabled")
    if [ "$SELINUX_STATUS" = "Disabled" ] || [ "$SELINUX_STATUS" = "Permissive" ]; then
        info "SELinux is $SELINUX_STATUS — no policy changes needed."
        return 0
    fi

    step "Configuring SELinux for rootless containers..."

    # container_use_dri and the container_t domain handle most container needs
    # These booleans are provided by container-selinux (pulled in by shadow-utils on newer RHEL)
    for bool in container_use_dri virt_use_usb; do
        if getsebool "$bool" &>/dev/null; then
            setsebool -P "$bool" on 2>/dev/null || warn "Could not set SELinux boolean: $bool"
        fi
    done

    # Label the binary with container_runtime_exec_t if available
    if command -v chcon &>/dev/null; then
        chcon -t container_runtime_exec_t "${INSTALL_DIR}/${BINARY_NAME}" 2>/dev/null || \
            warn "Could not set SELinux context on binary — may need container-selinux package."
    fi

    info "SELinux configuration applied."
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

install_or_update_pasta() {
    step "Checking pasta version..."

    local INSTALLED_VERSION=""
    if command -v pasta &>/dev/null; then
        INSTALLED_VERSION=$(pasta --version 2>&1 | head -1 | awk '{print $2}')
    fi

    if [ -z "${INSTALLED_VERSION}" ] || [ "${INSTALLED_VERSION}" = "unknown" ]; then
        warn "pasta is missing or too old. Building from source..."

        local TMP_DIR
        TMP_DIR=$(mktemp -d)
        trap 'rm -rf "${TMP_DIR:-/tmp/unknown}"' EXIT

        case "$DISTRO" in
            debian|ubuntu|pop|elementary|linuxmint|neon)
                apt-get install -y -qq git make gcc libssl-dev
                ;;
            fedora|rhel|centos|ol)
                dnf install -y git make gcc openssl-devel
                ;;
            arch|manjaro|endeavouros|garuda)
                pacman -Sy --noconfirm git make gcc openssl
                ;;
            suse|opensuse*)
                zypper install -y git make gcc libopenssl-devel
                ;;
        esac

        GIT_TERMINAL_PROMPT=0 git clone --depth 1 https://passt.top/passt "$TMP_DIR/passt"
        make -C "$TMP_DIR/passt" --silent
        make -C "$TMP_DIR/passt" install
        info "pasta $(pasta --version 2>&1 | head -1) built and installed from source."
    else
        info "pasta version: $INSTALLED_VERSION"
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
    install_or_update_pasta
    fetch_latest_version
    download_binary
    install_binary
    setup_apparmor       # must run after install_binary so BINARY_PATH exists
    setup_selinux        # must run after install_binary so binary can be labelled
    verify_install

    echo ""
    info "Installation complete! 🏺"
    echo ""
}

main "$@"