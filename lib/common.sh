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

# Check if an IP address is an RFC 1918 private / loopback / link-local address
is_private_ip() {
    local ip="${1:-}"
    [[ "$ip" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|127\.|169\.254\.) ]]
}

# Convert IPv4 netmask to CIDR prefix length (e.g. 255.255.255.0 -> 24)
netmask_to_cidr() {
    local mask="${1:-255.255.255.0}"
    local cidr=0
    local IFS='.'
    local -a octets=($mask)
    for octet in "${octets[@]}"; do
        case "$octet" in
            255) ((cidr += 8)) ;;
            254) ((cidr += 7)) ;;
            252) ((cidr += 6)) ;;
            248) ((cidr += 5)) ;;
            240) ((cidr += 4)) ;;
            224) ((cidr += 3)) ;;
            192) ((cidr += 2)) ;;
            128) ((cidr += 1)) ;;
            0)   ;;
            *)   ((cidr += 8)) ;;
        esac
    done
    echo "$cidr"
}

# Dynamically detect active OpenVPN subnet & CIDR from configuration or running interface
detect_vpn_subnet() {
    local conf=""
    if [[ -f "/etc/openvpn/server/server.conf" ]]; then
        conf="/etc/openvpn/server/server.conf"
    elif [[ -f "/etc/openvpn/server.conf" ]]; then
        conf="/etc/openvpn/server.conf"
    fi

    local detected_net=""
    local detected_mask=""
    local detected_cidr=""

    # 1. Primary ground truth: Active server.conf 'server' directive
    if [[ -n "$conf" ]]; then
        local server_line
        server_line=$(grep -E '^\s*server\s+' "$conf" | head -n1 || true)
        if [[ -n "$server_line" ]]; then
            detected_net=$(echo "$server_line" | awk '{print $2}' | tr -d '\r')
            detected_mask=$(echo "$server_line" | awk '{print $3}' | tr -d '\r')
            if is_valid_ip "$detected_net"; then
                if [[ -z "$detected_mask" ]] || ! is_valid_ip "$detected_mask"; then
                    detected_mask="255.255.255.0"
                fi
                local prefix
                prefix=$(netmask_to_cidr "$detected_mask")
                detected_cidr="${detected_net}/${prefix}"
            fi
        fi
    fi

    # 2. Secondary source: Live active tun interface (e.g. tun0)
    if [[ -z "$detected_cidr" ]] || ! is_valid_cidr "$detected_cidr"; then
        local tun_info
        tun_info=$(ip -o -4 addr show 2>/dev/null | grep -E '\s+tun[0-9]*\s+' | head -n1 || true)
        if [[ -n "$tun_info" ]]; then
            local tun_cidr
            tun_cidr=$(echo "$tun_info" | awk '{print $4}' | head -n1 || true)
            if [[ "$tun_cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$ ]]; then
                local tun_ip="${tun_cidr%/*}"
                local tun_prefix="${tun_cidr#*/}"
                if [[ "$tun_prefix" == "32" ]]; then
                    detected_net="${tun_ip%.*}.0"
                    detected_mask="255.255.255.0"
                    detected_cidr="${detected_net}/24"
                else
                    detected_net="${tun_ip%.*}.0"
                    detected_cidr="${detected_net}/${tun_prefix}"
                    case "$tun_prefix" in
                        24) detected_mask="255.255.255.0" ;;
                        16) detected_mask="255.255.0.0" ;;
                        8)  detected_mask="255.0.0.0" ;;
                        *)  detected_mask="255.255.255.0" ;;
                    esac
                fi
            fi
        fi
    fi

    # 3. Tertiary source: Existing installer-vars.conf if already set
    if [[ -z "$detected_cidr" ]] || ! is_valid_cidr "$detected_cidr"; then
        if [[ -n "${OPENVPN_CIDR:-}" ]] && is_valid_cidr "$OPENVPN_CIDR"; then
            detected_cidr="$OPENVPN_CIDR"
            detected_net="${OPENVPN_CIDR%/*}"
            detected_mask="${OPENVPN_NETMASK:-255.255.255.0}"
        fi
    fi

    # 4. Fallback default
    if [[ -z "$detected_cidr" ]] || ! is_valid_cidr "$detected_cidr"; then
        detected_net="10.8.0.0"
        detected_mask="255.255.255.0"
        detected_cidr="10.8.0.0/24"
    fi

    OPENVPN_SUBNET="$detected_net"
    OPENVPN_NETMASK="${detected_mask:-255.255.255.0}"
    OPENVPN_CIDR="$detected_cidr"
}

# Detect Default Network Interface & Public IP with multi-IP interface awareness
detect_network() {
    # Default public interface: inspect default routing table
    PUBLIC_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1 || true)
    
    # If not found or not in /sys/class/net, find first physical/ethernet device (excluding docker, veth, br, tun, lo)
    if [[ -z "$PUBLIC_IFACE" || ! -d "/sys/class/net/$PUBLIC_IFACE" ]]; then
        PUBLIC_IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -vE '^(lo|docker[0-9]*|br-[0-9a-f]+|veth|tun[0-9]*|tap[0-9]*)' | head -n1 || true)
    fi

    # Detect Public IP
    PUBLIC_IP=""

    # 1. Check if PUBLIC_IFACE has a public IP address bound to it directly (e.g. multi-IP setups)
    if [[ -n "${PUBLIC_IFACE:-}" && -d "/sys/class/net/${PUBLIC_IFACE}" ]]; then
        local candidate_ips
        candidate_ips=$(ip -4 -o addr show dev "$PUBLIC_IFACE" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 || true)
        for cand in $candidate_ips; do
            if is_valid_ip "$cand" && ! is_private_ip "$cand"; then
                PUBLIC_IP="$cand"
                break
            fi
        done
    fi

    # 2. Query external IP check endpoints
    if ! is_valid_ip "${PUBLIC_IP:-}"; then
        local endpoints=(
            "https://api.ipify.org"
            "https://ifconfig.me"
            "https://icanhazip.com"
            "https://api4.ipify.org"
            "https://ipinfo.io/ip"
        )

        for url in "${endpoints[@]}"; do
            local raw_res
            raw_res=$(curl -s4 --fail --max-time 3 "$url" 2>/dev/null || true)
            # Extract only valid IPv4 pattern, ignoring HTML/error tags
            local extracted_ip
            extracted_ip=$(echo "$raw_res" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)
            if is_valid_ip "$extracted_ip"; then
                PUBLIC_IP="$extracted_ip"
                break
            fi
        done
    fi

    # 3. Fallback to primary IP of the interface if external services fail or return HTML
    if ! is_valid_ip "${PUBLIC_IP:-}" && [[ -n "${PUBLIC_IFACE:-}" && -d "/sys/class/net/${PUBLIC_IFACE}" ]]; then
        local iface_ip
        iface_ip=$(ip -4 addr show "$PUBLIC_IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)
        if is_valid_ip "$iface_ip"; then
            PUBLIC_IP="$iface_ip"
        fi
    fi

    # 4. Final fallback if no valid IP detected
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

# Load OpenVPN Installer Config Vars (with dynamic detection & synchronization from live config)
load_installer_vars() {
    VARS_FILE="/etc/openvpn/installer-vars.conf"
    
    # 1. Source VARS_FILE if it exists
    if [[ -f "$VARS_FILE" ]]; then
        source "$VARS_FILE"
    fi

    # 2. Locate active server.conf
    local conf=""
    if [[ -f "/etc/openvpn/server/server.conf" ]]; then
        conf="/etc/openvpn/server/server.conf"
    elif [[ -f "/etc/openvpn/server.conf" ]]; then
        conf="/etc/openvpn/server.conf"
    fi

    # 3. Synchronize Port, Proto, Cipher from server.conf if present
    if [[ -n "$conf" ]]; then
        local p
        p=$(grep -E '^\s*port\s+' "$conf" | awk '{print $2}' | tr -d '\r' | head -n1 || true)
        [[ -n "$p" ]] && OPENVPN_PORT="$p"

        local pr
        pr=$(grep -E '^\s*proto\s+' "$conf" | awk '{print $2}' | tr -d '\r' | head -n1 || true)
        [[ -n "$pr" ]] && OPENVPN_PROTO="$pr"

        local c
        c=$(grep -E '^\s*cipher\s+' "$conf" | awk '{print $2}' | tr -d '\r' | head -n1 || true)
        [[ -n "$c" ]] && CIPHER="$c"
    fi

    # 4. Always dynamically detect the active VPN Subnet & CIDR from server.conf / live tun
    detect_vpn_subnet

    # 5. Verify & detect PUBLIC_IFACE: if missing or interface doesn't exist on host, re-detect
    if [[ -z "${PUBLIC_IFACE:-}" || ! -d "/sys/class/net/${PUBLIC_IFACE}" ]]; then
        detect_network
    fi

    # 6. Verify & detect PUBLIC_IP
    if ! is_valid_ip "${PUBLIC_IP:-}" || [[ "${PUBLIC_IP:-}" == "127.0.0.1" ]]; then
        detect_network
    fi

    # 7. Verify & resolve OUTBOUND_IP: on multi-IP hosts, OUTBOUND_IP must be the public egress IP
    if ! is_valid_ip "${OUTBOUND_IP:-}" || is_private_ip "${OUTBOUND_IP:-}" || [[ "${OUTBOUND_IP:-}" == "127.0.0.1" ]]; then
        if is_valid_ip "${PUBLIC_IP:-}" && ! is_private_ip "${PUBLIC_IP:-}"; then
            OUTBOUND_IP="${PUBLIC_IP}"
        else
            OUTBOUND_IP="${PUBLIC_IP:-127.0.0.1}"
        fi
    fi

    # 8. Defaults for missing auxiliary parameters
    OPENVPN_PORT="${OPENVPN_PORT:-1194}"
    OPENVPN_PROTO="${OPENVPN_PROTO:-udp}"
    DNS_1="${DNS_1:-1.1.1.1}"
    DNS_2="${DNS_2:-1.0.0.1}"
    CIPHER="${CIPHER:-AES-256-GCM}"
    CERT_TYPE="${CERT_TYPE:-ec}"
    EASYRSA_DIR="${EASYRSA_DIR:-/etc/openvpn/easy-rsa}"
    PKI_DIR="${PKI_DIR:-${EASYRSA_DIR}/pki}"
    CLIENT_DIR="${CLIENT_DIR:-/etc/openvpn/client-profiles}"
    USE_TLS_CRYPT="${USE_TLS_CRYPT:-0}"
    NAT_MODE="${NAT_MODE:-SNAT}"
    IPTABLES_ENABLED="${IPTABLES_ENABLED:-1}"

    # 9. If server is installed, save synchronized variables so all scripts stay in sync
    if is_installed 2>/dev/null; then
        save_installer_vars 2>/dev/null || true
    fi

    return 0
}

# Save current installer and firewall variables to /etc/openvpn/installer-vars.conf
save_installer_vars() {
    VARS_FILE="/etc/openvpn/installer-vars.conf"
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
USE_TLS_CRYPT="${USE_TLS_CRYPT:-0}"
NAT_MODE="${NAT_MODE:-SNAT}"
OUTBOUND_IP="${OUTBOUND_IP:-${PUBLIC_IP}}"
IPTABLES_ENABLED="${IPTABLES_ENABLED:-1}"
EOF
}

# Display Detailed System Paths, Folders and Generated Profiles Info
show_detailed_info() {
    msg_section "Detailed Installation Directory & Generated Files Overview"

    load_installer_vars 2>/dev/null || true

    echo -e "${BOLD}1. System & Network Variables:${NC}"
    echo -e "   - Public IP           : ${CYAN}${PUBLIC_IP:-Unknown}${NC}"
    echo -e "   - Network Interface   : ${CYAN}${PUBLIC_IFACE:-Unknown}${NC}"
    echo -e "   - OpenVPN Port / Proto: ${CYAN}${OPENVPN_PORT:-1194} / ${OPENVPN_PROTO:-udp}${NC}"
    echo -e "   - VPN Subnet CIDR     : ${CYAN}${OPENVPN_CIDR}${NC}"
    echo -e "   - Cipher & Cert Type  : ${CYAN}${CIPHER:-AES-256-GCM} (${CERT_TYPE:-ec})${NC}"
    echo -e "   - NAT Mode & Outbound : ${CYAN}${NAT_MODE:-SNAT}${NC} (IP: ${YELLOW}${OUTBOUND_IP:-${PUBLIC_IP:-Unknown}}${NC})"
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
        "/etc/openvpn/iptables-rules.sh:Firewall & NAT Persistence Script"
        "/etc/systemd/system/openvpn-iptables.service:Firewall Systemd Service"
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

# Auto-repair common configuration errors and restore running service
repair_server_config() {
    local conf=""
    if [[ -f "/etc/openvpn/server/server.conf" ]]; then
        conf="/etc/openvpn/server/server.conf"
    elif [[ -f "/etc/openvpn/server.conf" ]]; then
        conf="/etc/openvpn/server.conf"
    fi

    [[ -n "$conf" ]] || return 0

    local changed=false
    local proper_group
    proper_group=$(get_openvpn_group)

    # 1. Fix unprivileged group (e.g. group nobody -> group nogroup on Debian/Ubuntu)
    if grep -qE '^group nobody' "$conf" && [[ "$proper_group" == "nogroup" ]]; then
        sed -i 's/^group nobody/group nogroup/' "$conf"
        msg_success "Auto-repaired group directive (nobody -> nogroup) in server.conf"
        changed=true
    fi

    # 2. Fix explicit-exit-notify if protocol is TCP
    if grep -qE '^proto tcp' "$conf" && grep -qE '^explicit-exit-notify' "$conf"; then
        sed -i '/^explicit-exit-notify/d' "$conf"
        msg_success "Auto-repaired: removed explicit-exit-notify directive from TCP server.conf"
        changed=true
    fi

    # 3. Ensure data-ciphers and data-ciphers-fallback exist for modern and legacy clients (e.g. MikroTik)
    if ! grep -qE '^data-ciphers ' "$conf"; then
        if grep -qE '^cipher ' "$conf"; then
            sed -i '/^cipher /a data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-256-CBC:AES-128-CBC\ndata-ciphers-fallback AES-256-CBC' "$conf"
            msg_success "Auto-repaired: added data-ciphers fallback negotiation to server.conf"
            changed=true
        fi
    fi

    # 4. Ensure IPv4 forwarding is active in kernel
    if [[ $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null) != "1" ]]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
        mkdir -p /etc/sysctl.d
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn.conf
        sysctl --system &>/dev/null || true
        msg_success "Auto-repaired: enabled net.ipv4.ip_forward=1 in kernel sysctl"
    fi

    # 5. Service health check: start/restart if modified or currently failed
    local srv="openvpn-server@server"
    if systemctl is-active --quiet openvpn-server@server 2>/dev/null; then
        srv="openvpn-server@server"
    elif systemctl is-active --quiet openvpn@server 2>/dev/null; then
        srv="openvpn@server"
    elif systemctl list-unit-files openvpn-server@.service &>/dev/null; then
        srv="openvpn-server@server"
    elif systemctl list-unit-files openvpn@.service &>/dev/null; then
        srv="openvpn@server"
    fi

    if [[ "$changed" == true ]] || ! systemctl is-active --quiet "$srv" 2>/dev/null; then
        msg_info "Restarting OpenVPN service (${srv}) with repaired configuration..."
        systemctl daemon-reload &>/dev/null || true
        systemctl restart "$srv" &>/dev/null || systemctl start "$srv" &>/dev/null || true
        if systemctl is-active --quiet "$srv" 2>/dev/null; then
            msg_success "OpenVPN server (${srv}) is now active and running healthy!"
        else
            local alt_srv="openvpn-server@server"
            [[ "$srv" == "openvpn-server@server" ]] && alt_srv="openvpn@server"
            systemctl restart "$alt_srv" &>/dev/null || systemctl start "$alt_srv" &>/dev/null || true
            if systemctl is-active --quiet "$alt_srv" 2>/dev/null; then
                msg_success "OpenVPN server (${alt_srv}) is now active and running healthy!"
            else
                msg_warn "OpenVPN service (${srv}) status check returned non-zero."
            fi
        fi
    fi
}

