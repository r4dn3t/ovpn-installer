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

# IP Address Validation
is_valid_ip() {
    local ip="${1:-}"
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
    local port="${1:-}"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

# CIDR Subnet Validation
is_valid_cidr() {
    local cidr="${1:-}"
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
    echo "$name" | sed 's/[^a-zA-Z0-9_-]/_/g'
}

# Detect Default Network Interface & Public IP via api.ipify.org with IP regex validation
detect_network() {
    # Default public interface
    PUBLIC_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)
    if [[ -z "$PUBLIC_IFACE" ]]; then
        PUBLIC_IFACE=$(ip link show | grep -v "lo:" | awk -F': ' '$2!="" {print $2}' | head -n1)
    fi

    PUBLIC_IP=""
    local endpoints=(
        "https://api.ipify.org"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://api4.ipify.org"
        "https://ipinfo.io/ip"
    )

    for url in "${endpoints[@]}"; do
        local raw_res
        raw_res=$(curl -s4 --fail --max-time 4 "$url" 2>/dev/null || true)
        # Extract only valid IPv4 pattern, ignoring HTML/error tags
        local extracted_ip
        extracted_ip=$(echo "$raw_res" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)
        if is_valid_ip "$extracted_ip"; then
            PUBLIC_IP="$extracted_ip"
            break
        fi
    done

    # Fallback to local interface IP if external services fail or return HTML
    if ! is_valid_ip "${PUBLIC_IP:-}" && [[ -n "${PUBLIC_IFACE:-}" ]]; then
        local iface_ip
        iface_ip=$(ip -4 addr show "$PUBLIC_IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)
        if is_valid_ip "$iface_ip"; then
            PUBLIC_IP="$iface_ip"
        fi
    fi

    # Final fallback if no valid IP detected
    if ! is_valid_ip "${PUBLIC_IP:-}"; then
        PUBLIC_IP="127.0.0.1"
    fi
}

# Check if OpenVPN Server is installed on the system
is_installed() {
    # 1. Primary check: installer configuration file
    if [[ -f "/etc/openvpn/installer-vars.conf" ]]; then
        return 0
    fi

    # 2. Server configuration file check
    if [[ -f "/etc/openvpn/server/server.conf" || -f "/etc/openvpn/server.conf" ]]; then
        return 0
    fi

    # 3. Active systemd service check
    if systemctl is-active --quiet openvpn-server@server 2>/dev/null || \
       systemctl is-active --quiet openvpn@server 2>/dev/null || \
       systemctl is-active --quiet openvpn 2>/dev/null; then
        return 0
    fi

    # 4. Installed binary + server config directory check
    if command -v openvpn &>/dev/null && [[ -d "/etc/openvpn/server" || -d "/etc/openvpn/easy-rsa" ]]; then
        return 0
    fi

    return 1
}

# Load OpenVPN Installer Config Vars (with auto-reconstruction & default fallbacks)
load_installer_vars() {
    VARS_FILE="/etc/openvpn/installer-vars.conf"
    
    if [[ -f "$VARS_FILE" ]]; then
        source "$VARS_FILE"
        # Validate sourced PUBLIC_IP - if invalid (e.g. contains HTML tags), re-detect & sanitize VARS_FILE
        if ! is_valid_ip "${PUBLIC_IP:-}"; then
            detect_network
            sed -i "s|^PUBLIC_IP=.*|PUBLIC_IP=\"${PUBLIC_IP}\"|" "$VARS_FILE" 2>/dev/null || true
        fi
    else
        # If installer-vars.conf is missing but server.conf exists, reconstruct vars
        local conf=""
        if [[ -f "/etc/openvpn/server/server.conf" ]]; then
            conf="/etc/openvpn/server/server.conf"
        elif [[ -f "/etc/openvpn/server.conf" ]]; then
            conf="/etc/openvpn/server.conf"
        fi

        if [[ -n "$conf" ]]; then
            detect_network
            OPENVPN_PORT=$(grep -E '^port ' "$conf" | awk '{print $2}' | head -n1 || echo "1194")
            OPENVPN_PROTO=$(grep -E '^proto ' "$conf" | awk '{print $2}' | head -n1 || echo "udp")
            
            local server_line
            server_line=$(grep -E '^server ' "$conf" | head -n1 || true)
            if [[ -n "$server_line" ]]; then
                OPENVPN_SUBNET=$(echo "$server_line" | awk '{print $2}')
                OPENVPN_NETMASK=$(echo "$server_line" | awk '{print $3}')
            else
                OPENVPN_SUBNET="10.8.0.0"
                OPENVPN_NETMASK="255.255.255.0"
            fi
            
            OPENVPN_CIDR="${OPENVPN_SUBNET}/24"
            DNS_1=$(grep -E 'dhcp-option DNS' "$conf" | head -n1 | awk '{print $3}' || echo "1.1.1.1")
            DNS_2=$(grep -E 'dhcp-option DNS' "$conf" | sed -n '2p' | awk '{print $3}' || echo "1.0.0.1")
            CIPHER=$(grep -E '^cipher ' "$conf" | awk '{print $2}' | head -n1 || echo "AES-256-GCM")
            CERT_TYPE="ec"
            EASYRSA_DIR="/etc/openvpn/easy-rsa"
            PKI_DIR="/etc/openvpn/easy-rsa/pki"
            CLIENT_DIR="/etc/openvpn/client-profiles"

            # Auto-create the installer-vars.conf file for future script executions
            mkdir -p /etc/openvpn
            cat <<EOF > "$VARS_FILE"
PUBLIC_IP="${PUBLIC_IP}"
PUBLIC_IFACE="${PUBLIC_IFACE}"
OPENVPN_PROTO="${OPENVPN_PROTO}"
OPENVPN_PORT="${OPENVPN_PORT}"
OPENVPN_CIDR="${OPENVPN_CIDR}"
OPENVPN_SUBNET="${OPENVPN_SUBNET}"
OPENVPN_NETMASK="${OPENVPN_NETMASK}"
DNS_1="${DNS_1}"
DNS_2="${DNS_2}"
CIPHER="${CIPHER}"
CERT_TYPE="${CERT_TYPE}"
EASYRSA_DIR="${EASYRSA_DIR}"
PKI_DIR="${PKI_DIR}"
CLIENT_DIR="${CLIENT_DIR}"
EOF
            source "$VARS_FILE"
        fi
    fi

    # Set robust default fallbacks for ALL installer variables to ensure set -u never fails
    PUBLIC_IP="${PUBLIC_IP:-127.0.0.1}"
    PUBLIC_IFACE="${PUBLIC_IFACE:-eth0}"
    OPENVPN_PROTO="${OPENVPN_PROTO:-udp}"
    OPENVPN_PORT="${OPENVPN_PORT:-1194}"
    OPENVPN_CIDR="${OPENVPN_CIDR:-10.8.0.0/24}"
    OPENVPN_SUBNET="${OPENVPN_SUBNET:-10.8.0.0}"
    OPENVPN_NETMASK="${OPENVPN_NETMASK:-255.255.255.0}"
    DNS_1="${DNS_1:-1.1.1.1}"
    DNS_2="${DNS_2:-1.0.0.1}"
    CIPHER="${CIPHER:-AES-256-GCM}"
    CERT_TYPE="${CERT_TYPE:-ec}"
    EASYRSA_DIR="${EASYRSA_DIR:-/etc/openvpn/easy-rsa}"
    PKI_DIR="${PKI_DIR:-${EASYRSA_DIR}/pki}"
    CLIENT_DIR="${CLIENT_DIR:-/etc/openvpn/client-profiles}"

    return 0
}

# Display Detailed System Paths, Folders and Generated Profiles Info
show_detailed_info() {
    msg_section "Detailed Installation Directory & Generated Files Overview"

    load_installer_vars 2>/dev/null || true

    echo -e "${BOLD}1. System & Network Variables:${NC}"
    echo -e "   - Public IP           : ${CYAN}${PUBLIC_IP:-Unknown}${NC}"
    echo -e "   - Network Interface   : ${CYAN}${PUBLIC_IFACE:-Unknown}${NC}"
    echo -e "   - OpenVPN Port / Proto: ${CYAN}${OPENVPN_PORT:-1194} / ${OPENVPN_PROTO:-udp}${NC}"
    echo -e "   - VPN Subnet CIDR     : ${CYAN}${OPENVPN_CIDR:-10.8.0.0/24}${NC}"
    echo -e "   - Cipher & Cert Type  : ${CYAN}${CIPHER:-AES-256-GCM} (${CERT_TYPE:-ec})${NC}"
    echo ""

    echo -e "${BOLD}2. Installation Directories Used:${NC}"
    local dirs=(
        "/etc/openvpn/server:Server Configuration Directory"
        "/etc/openvpn/easy-rsa:Easy-RSA Directory"
        "${PKI_DIR:-/etc/openvpn/easy-rsa/pki}:PKI Certificate Directory"
        "${CLIENT_DIR:-/etc/openvpn/client-profiles}:Generated Client Profiles Directory"
        "/var/log/openvpn:Server Log Directory"
    )

    for entry in "${dirs[@]}"; do
        local path="${entry%%:*}"
        local desc="${entry#*:}"
        if [[ -d "$path" ]]; then
            echo -e "   - [${GREEN}EXISTS${NC}] ${BOLD}${desc}${NC}: ${path}"
        else
            echo -e "   - [${RED}MISSING${NC}] ${BOLD}${desc}${NC}: ${path}"
        fi
    done
    echo ""

    echo -e "${BOLD}3. Key Infrastructure Files Generated:${NC}"
    local files=(
        "/etc/openvpn/installer-vars.conf:Installer State Variables"
        "/etc/openvpn/server/server.conf:Main Server Configuration"
        "/etc/openvpn/server/ca.crt:Certificate Authority (CA)"
        "/etc/openvpn/server/server.crt:Server Public Certificate"
        "/etc/openvpn/server/server.key:Server Private Key"
        "/etc/openvpn/tls-crypt.key:TLS Crypt Control Channel Key"
        "/etc/openvpn/server/dh.pem:Diffie-Hellman Parameters"
        "/etc/openvpn/server/crl.pem:Certificate Revocation List (CRL)"
        "/etc/sysctl.d/99-openvpn.conf:Kernel IP Forwarding Sysctl Config"
        "/var/log/openvpn/openvpn.log:Server Log File"
        "/var/log/openvpn/openvpn-status.log:Active Connection Status Log"
    )

    for entry in "${files[@]}"; do
        local path="${entry%%:*}"
        local desc="${entry#*:}"
        if [[ -f "$path" ]]; then
            local size
            size=$(du -h "$path" 2>/dev/null | cut -f1)
            echo -e "   - [${GREEN}EXISTS${NC}] ${BOLD}${desc}${NC}"
            echo -e "     Path: ${YELLOW}${path}${NC} (${size})"
        else
            echo -e "   - [${YELLOW}OPTIONAL/NOT GENERATED${NC}] ${desc} (${path})"
        fi
    done
    echo ""

    echo -e "${BOLD}4. Generated Client Profiles & Files:${NC}"
    local client_path="${CLIENT_DIR:-/etc/openvpn/client-profiles}"
    if [[ -d "$client_path" ]] && [[ "$(ls -A "$client_path" 2>/dev/null)" ]]; then
        echo -e "   Location: ${YELLOW}${client_path}${NC}"
        echo -e "   ----------------------------------------------------------------------"
        find "$client_path" -maxdepth 2 -type f 2>/dev/null | while read -r f; do
            local sz
            sz=$(du -h "$f" 2>/dev/null | cut -f1)
            local mod
            mod=$(date -r "$f" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "")
            echo -e "   - ${CYAN}${f}${NC} (${sz} | ${mod})"
        done
    else
        echo -e "   ${YELLOW}No client profiles generated yet in ${client_path}${NC}"
    fi
    echo ""
}

# Determine appropriate unprivileged group (nogroup on Debian/Ubuntu, nobody on RHEL/Arch)
get_openvpn_group() {
    if getent group nogroup &>/dev/null; then
        echo "nogroup"
    elif getent group nobody &>/dev/null; then
        echo "nobody"
    else
        echo "nogroup"
    fi
}

# Auto-repair common configuration errors (group nobody on Debian/Ubuntu, explicit-exit-notify on TCP)
repair_server_config() {
    local conf="/etc/openvpn/server/server.conf"
    [[ -f "$conf" ]] || return 0

    local changed=false
    local proper_group
    proper_group=$(get_openvpn_group)

    # 1. Fix unprivileged group (e.g. group nobody -> group nogroup on Debian/Ubuntu)
    if grep -qE '^group nobody' "$conf" && [[ "$proper_group" == "nogroup" ]]; then
        sed -i 's/^group nobody/group nogroup/' "$conf"
        changed=true
    fi

    # 2. Fix explicit-exit-notify if protocol is TCP
    if grep -qE '^proto tcp' "$conf" && grep -qE '^explicit-exit-notify' "$conf"; then
        sed -i '/^explicit-exit-notify/d' "$conf"
        changed=true
    fi

    if [[ "$changed" == true ]]; then
        msg_info "Auto-repaired server configuration compatibility settings..."
        systemctl restart openvpn-server@server &>/dev/null || systemctl restart openvpn@server &>/dev/null || true
    fi
}

