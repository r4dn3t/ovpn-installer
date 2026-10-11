#!/usr/bin/env bash
# ==============================================================================
# OpenVPN Server Installation & Initial Configuration Script
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/firewall.sh"
source "${SCRIPT_DIR}/lib/templates.sh"

check_root
detect_os
detect_network

msg_section "OpenVPN Server Installation Wizard"
echo -e "Target OS Detected: ${BOLD}${OS_NAME}${NC} (Family: ${OS_FAMILY})"

# Check if OpenVPN is already installed
if is_installed; then
    msg_warn "OpenVPN server is already installed on this system!"
    echo -e "If you want to reinstall, please run ${BOLD}./uninstall.sh${NC} first."
    exit 1
fi

# ==============================================================================
# Step 1: Install Required Dependencies & Packages
# ==============================================================================
msg_section "Step 1: Installing Required System Packages"

case "$OS_FAMILY" in
    debian)
        export DEBIAN_FRONTEND=noninteractive
        msg_info "Updating package repositories..."
        apt-get update -qq
        msg_info "Installing OpenVPN, Easy-RSA, OpenSSL, iptables, and utilities..."
        apt-get install -y -qq openvpn easy-rsa openssl iptables ca-certificates curl qrencode tar iproute2
        ;;
    redhat)
        msg_info "Checking EPEL repository for RHEL/CentOS family..."
        if ! $PKG_MANAGER repolist | grep -i epel &>/dev/null; then
            $PKG_MANAGER install -y epel-release || true
        fi
        msg_info "Installing OpenVPN, Easy-RSA, OpenSSL, iptables, and utilities..."
        $PKG_MANAGER install -y openvpn easy-rsa openssl iptables-services ca-certificates curl qrencode tar iproute
        ;;
    arch)
        msg_info "Updating pacman repositories..."
        pacman -Sy --noconfirm
        msg_info "Installing OpenVPN, Easy-RSA, OpenSSL, iptables, and utilities..."
        pacman -S --noconfirm --needed openvpn easy-rsa openssl iptables ca-certificates curl qrencode iproute2
        ;;
    *)
        msg_error "Unsupported OS family: ${OS_FAMILY}"
        exit 1
        ;;
esac

msg_success "Dependencies installed successfully."

# ==============================================================================
# Step 2: Gather User Preferences & Server Configurations
# ==============================================================================
msg_section "Step 2: Server Configuration & User Preferences"

# 1. Public IPv4 / Hostname
echo -e "${BOLD}1. Public Server IP or Domain Name:${NC}"
read -rp "   Enter public IPv4 or domain [default: ${PUBLIC_IP}]: " input_ip
SERVER_IP="${input_ip:-$PUBLIC_IP}"
if [[ -z "$SERVER_IP" ]]; then
    msg_error "Invalid IP address or domain name."
    exit 1
fi

# 2. Public Network Interface
echo -e "\n${BOLD}2. Server Network Interface:${NC}"
read -rp "   Enter outgoing network interface [default: ${PUBLIC_IFACE}]: " input_iface
SERVER_IFACE="${input_iface:-$PUBLIC_IFACE}"

# 3. Protocol Selection
echo -e "\n${BOLD}3. OpenVPN Protocol:${NC}"
echo "   1) UDP (Recommended for maximum speed & stability)"
echo "   2) TCP (Recommended for strict firewalls or MikroTik v6)"
read -rp "   Select protocol [1-2, default 1]: " proto_choice
case "$proto_choice" in
    2) OPENVPN_PROTO="tcp" ;;
    *) OPENVPN_PROTO="udp" ;;
esac

# 4. Listening Port
echo -e "\n${BOLD}4. OpenVPN Listening Port:${NC}"
read -rp "   Enter port number [1-65535, default: 1194]: " input_port
OPENVPN_PORT="${input_port:-1194}"
if ! is_valid_port "$OPENVPN_PORT"; then
    msg_error "Invalid port number '$OPENVPN_PORT'."
    exit 1
fi

# 5. OpenVPN IP Subnet / Subnet Mask
echo -e "\n${BOLD}5. OpenVPN VPN Subnet CIDR:${NC}"
read -rp "   Enter VPN IPv4 subnet [default: 10.8.0.0/24]: " input_subnet
OPENVPN_CIDR="${input_subnet:-10.8.0.0/24}"
if ! is_valid_cidr "$OPENVPN_CIDR"; then
    msg_error "Invalid CIDR range '$OPENVPN_CIDR'."
    exit 1
fi
OPENVPN_SUBNET=$(echo "$OPENVPN_CIDR" | cut -d'/' -f1)
CIDR_MASK=$(echo "$OPENVPN_CIDR" | cut -d'/' -f2)

# Convert CIDR prefix length to netmask
case "$CIDR_MASK" in
    24) OPENVPN_NETMASK="255.255.255.0" ;;
    16) OPENVPN_NETMASK="255.255.0.0" ;;
    8)  OPENVPN_NETMASK="255.0.0.0" ;;
    *)  OPENVPN_NETMASK="255.255.255.0" ;;
esac

# 6. DNS Resolvers Choice
echo -e "\n${BOLD}6. DNS Resolvers for Clients:${NC}"
echo "   1) Cloudflare (1.1.1.1, 1.0.0.1) [Recommended]"
echo "   2) Google (8.8.8.8, 8.8.4.4)"
echo "   3) Quad9 (9.9.9.9, 149.112.112.112)"
echo "   4) OpenDNS (208.67.222.222, 208.67.220.220)"
echo "   5) Custom DNS"
read -rp "   Select DNS option [1-5, default 1]: " dns_choice
case "$dns_choice" in
    2) DNS_1="8.8.8.8"; DNS_2="8.8.4.4" ;;
    3) DNS_1="9.9.9.9"; DNS_2="149.112.112.112" ;;
    4) DNS_1="208.67.222.222"; DNS_2="208.67.220.220" ;;
    5)
        read -rp "   Enter Primary DNS server IP: " DNS_1
        read -rp "   Enter Secondary DNS server IP (optional): " DNS_2
        DNS_2="${DNS_2:-$DNS_1}"
        ;;
    *) DNS_1="1.1.1.1"; DNS_2="1.0.0.1" ;;
esac

# 7. Encryption & Certificate Security Suite
echo -e "\n${BOLD}7. Encryption & Certificate Algorithm:${NC}"
echo "   1) Modern ECC (prime256v1 / EC) + AES-256-GCM [Fastest & Highly Secure]"
echo "   2) High Security RSA 4096-bit + AES-256-GCM"
echo "   3) Standard RSA 2048-bit + AES-256-GCM [Maximum Legacy Compatibility]"
read -rp "   Select encryption suite [1-3, default 1]: " crypto_choice
case "$crypto_choice" in
    2) CERT_TYPE="rsa"; KEY_SIZE="4096"; CIPHER="AES-256-GCM" ;;
    3) CERT_TYPE="rsa"; KEY_SIZE="2048"; CIPHER="AES-256-GCM" ;;
    *) CERT_TYPE="ec"; KEY_SIZE="prime256v1"; CIPHER="AES-256-GCM" ;;
esac

# 8. Redirect Gateway / Traffic Routing
echo -e "\n${BOLD}8. Client Internet Routing Strategy:${NC}"
echo "   1) Redirect ALL client internet traffic through VPN (Full Tunnel)"
echo "   2) Split Tunneling (Only route VPN internal subnet)"
read -rp "   Select routing strategy [1-2, default 1]: " route_choice
case "$route_choice" in
    2) REDIRECT_GATEWAY="0" ;;
    *) REDIRECT_GATEWAY="1" ;;
esac

# 9. Hardware Router (MikroTik RouterOS) Support
echo -e "\n${BOLD}9. Hardware Router (MikroTik RouterOS) Compatibility:${NC}"
echo "   1) Yes (Standard TLS - compatible with MikroTik routers, iOS, macOS, Windows, Android, Linux) [Recommended]"
echo "   2) No  (Enable tls-crypt - extra obfuscation, but incompatible with MikroTik)"
read -rp "   Enable MikroTik router support? [1-2, default 1]: " mikrotik_compat
case "$mikrotik_compat" in
    2) USE_TLS_CRYPT="1" ;;
    *) USE_TLS_CRYPT="0" ;;
esac

msg_info "Configuration choices collected."

# ==============================================================================
# Step 3: Setup Easy-RSA & Generate PKI / Certificates
# ==============================================================================
msg_section "Step 3: Generating Easy-RSA PKI & Server Certificates"

# Find Easy-RSA directory
EASYRSA_DIR="/etc/openvpn/easy-rsa"
rm -rf "$EASYRSA_DIR"
mkdir -p "$EASYRSA_DIR"

if [[ -d /usr/share/easy-rsa/3.0 ]]; then
    cp -r /usr/share/easy-rsa/3.0/* "$EASYRSA_DIR/"
elif [[ -d /usr/share/easy-rsa/3 ]]; then
    cp -r /usr/share/easy-rsa/3/* "$EASYRSA_DIR/"
elif [[ -d /usr/share/easy-rsa ]]; then
    cp -r /usr/share/easy-rsa/* "$EASYRSA_DIR/"
else
    msg_error "Could not locate Easy-RSA installed scripts in /usr/share/easy-rsa!"
    exit 1
fi

cd "$EASYRSA_DIR"

# Configure Easy-RSA vars file
cat <<EOF > vars
set_var EASYRSA_ALGO "${CERT_TYPE}"
EOF
if [[ "$CERT_TYPE" == "ec" ]]; then
    echo 'set_var EASYRSA_CURVE "prime256v1"' >> vars
else
    echo "set_var EASYRSA_KEY_SIZE ${KEY_SIZE}" >> vars
fi

msg_info "Initializing PKI..."
./easyrsa --batch init-pki

msg_info "Building Certificate Authority (CA)..."
./easyrsa --batch --req-cn="OpenVPN-CA" build-ca nopass

msg_info "Generating Server Certificate & Key..."
./easyrsa --batch build-server-full server nopass

if [[ "$CERT_TYPE" == "rsa" ]]; then
    msg_info "Generating Diffie-Hellman Parameters (DH)..."
    ./easyrsa --batch gen-dh
else
    # Create empty dh file or ec params if required by older openvpn versions
    openssl ecparam -name prime256v1 -out pki/dh.pem 2>/dev/null || true
fi

msg_info "Generating OpenVPN TLS Crypt Key..."
openvpn --genkey secret /etc/openvpn/tls-crypt.key

# Organize Server Certificate Files
mkdir -p /etc/openvpn/server
cp pki/ca.crt /etc/openvpn/server/
cp pki/issued/server.crt /etc/openvpn/server/
cp pki/private/server.key /etc/openvpn/server/
if [[ -f pki/dh.pem ]]; then
    cp pki/dh.pem /etc/openvpn/server/
fi

msg_success "PKI and server certificates generated."

# ==============================================================================
# Step 4: Write OpenVPN Server Configuration File
# ==============================================================================
msg_section "Step 4: Writing OpenVPN Server Configuration"

CONF_FILE="/etc/openvpn/server/server.conf"

cat <<EOF > "$CONF_FILE"
port ${OPENVPN_PORT}
proto ${OPENVPN_PROTO}
dev tun
ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key /etc/openvpn/server/server.key
EOF

if [[ -f /etc/openvpn/server/dh.pem && "$CERT_TYPE" == "rsa" ]]; then
    echo "dh /etc/openvpn/server/dh.pem" >> "$CONF_FILE"
else
    echo "dh none" >> "$CONF_FILE"
fi

cat <<EOF >> "$CONF_FILE"
topology subnet
server ${OPENVPN_SUBNET} ${OPENVPN_NETMASK}
ifconfig-pool-persist /etc/openvpn/server/ipp.txt

push "dhcp-option DNS ${DNS_1}"
push "dhcp-option DNS ${DNS_2}"
EOF

if [[ "$REDIRECT_GATEWAY" == "1" ]]; then
    echo 'push "redirect-gateway def1 bypass-dhcp"' >> "$CONF_FILE"
fi

OPENVPN_GROUP=$(get_openvpn_group)

cat <<EOF >> "$CONF_FILE"
keepalive 10 120
EOF

if [[ "$USE_TLS_CRYPT" == "1" ]]; then
    echo "tls-crypt /etc/openvpn/tls-crypt.key" >> "$CONF_FILE"
fi

cat <<EOF >> "$CONF_FILE"
cipher ${CIPHER}
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-256-CBC:AES-128-CBC
data-ciphers-fallback AES-256-CBC
auth SHA256
user nobody
group ${OPENVPN_GROUP}
persist-key
persist-tun
status /var/log/openvpn/openvpn-status.log
log-append /var/log/openvpn/openvpn.log
verb 3
EOF

if [[ "$OPENVPN_PROTO" == "udp" ]]; then
    echo "explicit-exit-notify 1" >> "$CONF_FILE"
fi

mkdir -p /var/log/openvpn
mkdir -p /etc/openvpn/client-profiles

msg_success "Server configuration written to ${CONF_FILE}"

# ==============================================================================
# Step 5: Configure Firewall, NAT & Systemd Service
# ==============================================================================
msg_section "Step 5: Applying Firewall NAT Rules & Starting Service"

setup_firewall "$OPENVPN_PROTO" "$OPENVPN_PORT" "$OPENVPN_CIDR" "$SERVER_IFACE" "$SERVER_IP"

# Save installer state variables
VARS_FILE="/etc/openvpn/installer-vars.conf"
cat <<EOF > "$VARS_FILE"
PUBLIC_IP="${SERVER_IP}"
PUBLIC_IFACE="${SERVER_IFACE}"
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
PKI_DIR="${EASYRSA_DIR}/pki"
CLIENT_DIR="/etc/openvpn/client-profiles"
USE_TLS_CRYPT="${USE_TLS_CRYPT}"
EOF

msg_info "Starting and enabling OpenVPN server systemd service..."
systemctl daemon-reload

SERVICE_NAME=""
if systemctl list-unit-files | grep -q openvpn-server@; then
    SERVICE_NAME="openvpn-server@server"
elif systemctl list-unit-files | grep -q openvpn@; then
    SERVICE_NAME="openvpn@server"
else
    SERVICE_NAME="openvpn-server@server"
fi

systemctl enable --now "$SERVICE_NAME" &>/dev/null || systemctl restart "$SERVICE_NAME" &>/dev/null || true

if systemctl is-active --quiet "$SERVICE_NAME"; then
    msg_success "OpenVPN service (${SERVICE_NAME}) is running successfully!"
else
    msg_warn "OpenVPN service started, but status check returned non-zero. Log check recommended."
fi

msg_section "Installation Complete!"
echo -e "${GREEN}${BOLD}OpenVPN Server is now fully installed and active!${NC}"
echo -e "Server Public IP : ${CYAN}${SERVER_IP}${NC}"
echo -e "Port / Protocol  : ${CYAN}${OPENVPN_PORT} / ${OPENVPN_PROTO}${NC}"
echo -e "VPN Subnet       : ${CYAN}${OPENVPN_CIDR}${NC}"

read -rp "Would you like to generate a new user client profile now? [Y/n]: " create_now
create_now="${create_now:-Y}"
if [[ "$create_now" =~ ^[Yy]$ ]]; then
    "${SCRIPT_DIR}/user-management.sh" add
fi
