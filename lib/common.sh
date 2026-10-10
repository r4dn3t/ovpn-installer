#!/usr/bin/env bash
# ==============================================================================
# Common Helper Functions & Utility Library for OpenVPN Installer
# ==============================================================================

# Output Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Print Message Utilities
msg_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

msg_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

msg_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

msg_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

msg_section() {
    echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}\n"
}

# Require Root Privileges
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        msg_error "This script must be run as root (or using sudo)."
        exit 1
    fi
}

# Detect Underlying Operating System
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_NAME="${PRETTY_NAME:-Linux}"
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="rhel"
        OS_VERSION=$(cat /etc/redhat-release | grep -oE '[0-9]+(\.[0-9]+)?')
        OS_NAME=$(cat /etc/redhat-release)
    elif [[ -f /etc/debian_version ]]; then
        OS_ID="debian"
        OS_VERSION=$(cat /etc/debian_version)
        OS_NAME="Debian ${OS_VERSION}"
    else
        msg_error "Unsupported operating system. /etc/os-release not found."
        exit 1
    fi

    # Normalize OS family
    case "$OS_ID" in
        ubuntu|debian|pop|mint|kali|raspbian)
            OS_FAMILY="debian"
            PKG_MANAGER="apt"
            ;;
        centos|rhel|rocky|almalinux|fedora|ol|oracle)
            OS_FAMILY="redhat"
            PKG_MANAGER="dnf"
            if ! command -v dnf &>/dev/null; then
                PKG_MANAGER="yum"
            fi
            ;;
        arch|manjaro|archarm)
            OS_FAMILY="arch"
            PKG_MANAGER="pacman"
            ;;
        alpine)
            OS_FAMILY="alpine"
            PKG_MANAGER="apk"
            ;;
        *)
            msg_error "Operating System family '$OS_ID' is not explicitly supported."
            exit 1
            ;;
    esac
}

# Detect Default Network Interface & Public IP
detect_network() {
    # Default public interface
    PUBLIC_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)
    if [[ -z "$PUBLIC_IFACE" ]]; then
        PUBLIC_IFACE=$(ip link show | grep -v "lo:" | awk -F': ' '$2!="" {print $2}' | head -n1)
    fi

    # Public IPv4 detection using external services with timeout
    PUBLIC_IP=$(curl -s4 --max-time 5 https://ifconfig.me || \
                curl -s4 --max-time 5 https://api.ipify.org || \
                curl -s4 --max-time 5 https://icanhazip.com || true)

    if [[ -z "$PUBLIC_IP" && -n "$PUBLIC_IFACE" ]]; then
        PUBLIC_IP=$(ip -4 addr show "$PUBLIC_IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)
    fi
}

# IP Address Validation
is_valid_ip() {
    local ip="$1"
    local rx='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if [[ $ip =~ $rx ]]; then
        local IFS='.'
        local -a a=($ip)
        [[ ${a[0]} -le 255 && ${a[1]} -le 255 && ${a[2]} -le 255 && ${a[3]} -le 255 ]]
        return $?
    fi
    return 1
}

# Port Number Validation
is_valid_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

# CIDR Subnet Validation
is_valid_cidr() {
    local cidr="$1"
    local rx='^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$'
    if [[ $cidr =~ $rx ]]; then
        local ip="${cidr%/*}"
        is_valid_ip "$ip"
        return $?
    fi
    return 1
}

# Sanitize Username / Client Name
sanitize_name() {
    local name="$1"
    # Allow alphanumeric, underscores, hyphens
    echo "$name" | sed 's/[^a-zA-Z0-9_-]/_/g'
}

# Load OpenVPN Installer Config Vars if present
load_installer_vars() {
    VARS_FILE="/etc/openvpn/installer-vars.conf"
    if [[ -f "$VARS_FILE" ]]; then
        # Source the configuration variables safely
        source "$VARS_FILE"
        return 0
    else
        return 1
    fi
}
