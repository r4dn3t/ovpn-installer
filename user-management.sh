#!/usr/bin/env bash
# ==============================================================================
# OpenVPN User & Client Profile Management Script
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/templates.sh"

check_root

if ! is_installed; then
    msg_error "OpenVPN installation was not detected on this server."
    msg_error "Please run ./install.sh first to set up the OpenVPN server."
    exit 1
fi
load_installer_vars 2>/dev/null || true

EASYRSA_DIR="${EASYRSA_DIR:-/etc/openvpn/easy-rsa}"
PKI_DIR="${PKI_DIR:-${EASYRSA_DIR}/pki}"
CLIENT_DIR="${CLIENT_DIR:-/etc/openvpn/client-profiles}"

mkdir -p "$CLIENT_DIR"

# ==============================================================================
# Function: Add New Client
# ==============================================================================
add_client() {
    msg_section "Create New OpenVPN User Profile"

    # Prompt for Client Name
    read -rp "Enter unique Client / Username: " raw_name
    CLIENT_NAME=$(sanitize_name "$raw_name")

    if [[ -z "$CLIENT_NAME" ]]; then
        msg_error "Client name cannot be empty."
        return 1
    fi

    local ovpn_path="${CLIENT_DIR}/${CLIENT_NAME}.ovpn"
    if [[ -f "$ovpn_path" || -f "${PKI_DIR}/issued/${CLIENT_NAME}.crt" ]]; then
        msg_warn "A client with name '${CLIENT_NAME}' already exists!"
        read -rp "Do you want to overwrite existing profile for '${CLIENT_NAME}'? [y/N]: " overwrite_choice
        if [[ ! "$overwrite_choice" =~ ^[Yy]$ ]]; then
            msg_info "Operation cancelled."
            return 0
        fi
    fi

    # Certificate Generation Preference
    echo -e "\n${BOLD}Certificate Generation Mode:${NC}"
    echo "   1) Generate Client X.509 Certificate & Private Key (Standard PKI - Recommended)"
    echo "   2) Password-only / Cert-less mode (For custom auth plugins or static auth)"
    read -rp "Select certificate mode [1-2, default 1]: " cert_mode_choice
    cert_mode_choice="${cert_mode_choice:-1}"

    # Target Device / Platform Selection
    echo -e "\n${BOLD}Target Client Device / Platform:${NC}"
    echo "   1) iPhone / iPad (iOS)"
    echo "   2) Mac (macOS - Tunnelblick / OpenVPN Connect)"
    echo "   3) MikroTik Router (RouterOS v6 / v7)"
    echo "   4) Android Mobile / Tablet"
    echo "   5) Windows PC"
    echo "   6) Linux / Generic Client"
    read -rp "Select client device type [1-6, default 1]: " device_choice

    local device_type="generic"
    case "$device_choice" in
        1) device_type="ios" ;;
        2) device_type="mac" ;;
        3) device_type="mikrotik" ;;
        4) device_type="android" ;;
        5) device_type="windows" ;;
        *) device_type="linux" ;;
    esac

    msg_info "Generating client credentials for '${CLIENT_NAME}'..."

    cd "$EASYRSA_DIR"

    if [[ "$cert_mode_choice" == "1" ]]; then
        # Standard PKI Certificate Generation
        ./easyrsa --batch build-client-full "$CLIENT_NAME" nopass &>/dev/null || true
    fi

    if [[ "$device_type" == "mikrotik" ]]; then
        local mikrotik_dir="${CLIENT_DIR}/${CLIENT_NAME}_mikrotik"
        generate_mikrotik_config "$CLIENT_NAME" "${PUBLIC_IP:-127.0.0.1}" "${OPENVPN_PORT:-1194}" "${OPENVPN_PROTO:-udp}" "${CIPHER:-AES-256-GCM}" "$mikrotik_dir" "$PKI_DIR"
        ovpn_path="${mikrotik_dir}/${CLIENT_NAME}.ovpn"
    else
        generate_standard_ovpn "$CLIENT_NAME" "${PUBLIC_IP:-127.0.0.1}" "${OPENVPN_PORT:-1194}" "${OPENVPN_PROTO:-udp}" "${CIPHER:-AES-256-GCM}" "$ovpn_path" "$PKI_DIR"
    fi

    msg_section "User Profile Created Successfully!"
    echo -e "Client Name   : ${BOLD}${CLIENT_NAME}${NC}"
    echo -e "Profile Path  : ${YELLOW}${ovpn_path}${NC}"

    # Display Mobile QR Code for iOS / Android
    if [[ "$device_type" == "ios" || "$device_type" == "android" ]]; then
        display_qr_code "$ovpn_path"
    fi

    # Print device specific setup guidelines
    print_device_guidelines "$device_type" "$CLIENT_NAME" "$ovpn_path"
}

# ==============================================================================
# Function: Revoke Existing Client
# ==============================================================================
revoke_client() {
    msg_section "Revoke OpenVPN User Profile"

    local clients=()
    if [[ -d "${PKI_DIR}/issued" ]]; then
        while IFS= read -r file; do
            local name
            name=$(basename "$file" .crt)
            if [[ "$name" != "server" && "$name" != "ca" ]]; then
                clients+=("$name")
            fi
        done < <(find "${PKI_DIR}/issued" -name "*.crt" 2>/dev/null)
    fi

    if [[ ${#clients[@]} -eq 0 ]]; then
        msg_warn "No active client certificates found."
        return 0
    fi

    echo -e "${BOLD}Active Clients:${NC}"
    local idx=1
    for c in "${clients[@]}"; do
        echo "   ${idx}) ${c}"
        ((idx++))
    done

    read -rp "Enter client name or number to revoke: " input_revoke

    local target_client=""
    if [[ "$input_revoke" =~ ^[0-9]+$ ]] && [ "$input_revoke" -ge 1 ] && [ "$input_revoke" -le ${#clients[@]} ]; then
        target_client="${clients[$((input_revoke - 1))]}"
    else
        target_client=$(sanitize_name "$input_revoke")
    fi

    if [[ -z "$target_client" ]]; then
        msg_error "Invalid client selection."
        return 1
    fi

    read -rp "Are you sure you want to revoke access for '${target_client}'? [y/N]: " confirm_revoke
    if [[ ! "$confirm_revoke" =~ ^[Yy]$ ]]; then
        msg_info "Revocation cancelled."
        return 0
    fi

    msg_info "Revoking certificate for '${target_client}'..."
    cd "$EASYRSA_DIR"
    ./easyrsa --batch revoke "$target_client" &>/dev/null || true
    ./easyrsa --batch gen-crl &>/dev/null || true

    cp "${PKI_DIR}/crl.pem" /etc/openvpn/server/crl.pem
    chmod 644 /etc/openvpn/server/crl.pem

    # Ensure crl-verify is configured in server.conf
    if ! grep -q "crl-verify" /etc/openvpn/server/server.conf; then
        echo "crl-verify /etc/openvpn/server/crl.pem" >> /etc/openvpn/server/server.conf
    fi

    # Restart OpenVPN service to apply CRL
    systemctl restart openvpn-server@server &>/dev/null || systemctl restart openvpn@server &>/dev/null || true

    # Remove client configuration profiles
    rm -f "${CLIENT_DIR}/${target_client}.ovpn"
    rm -rf "${CLIENT_DIR}/${target_client}_mikrotik"

    msg_success "Client '${target_client}' certificate has been revoked and blocked."
}

# ==============================================================================
# Function: List Clients
# ==============================================================================
list_clients() {
    msg_section "List Registered OpenVPN Users"

    if [[ ! -d "${PKI_DIR}/issued" ]]; then
        msg_warn "PKI issued directory not found."
        return 0
    fi

    echo -e "${BOLD}%-20s %-30s %-15s${NC}" "Client Name" "Issue Date" "Status"
    echo "----------------------------------------------------------------------"

    for file in "${PKI_DIR}/issued"/*.crt; do
        [[ -e "$file" ]] || continue
        local name
        name=$(basename "$file" .crt)
        if [[ "$name" != "server" && "$name" != "ca" ]]; then
            local date_str
            date_str=$(openssl x509 -in "$file" -noout -startdate 2>/dev/null | cut -d'=' -f2)
            local status="${GREEN}Active${NC}"
            if [[ -f "${CLIENT_DIR}/${name}.ovpn" || -d "${CLIENT_DIR}/${name}_mikrotik" ]]; then
                status="${GREEN}Active (Profile Ready)${NC}"
            fi
            printf "%-20s %-30s %-15b\n" "$name" "$date_str" "$status"
        fi
    done
    echo ""
}

# ==============================================================================
# Function: Show / Export Guidelines for Existing Client
# ==============================================================================
show_client_guidelines() {
    msg_section "Display / Export Existing Client Profile"

    read -rp "Enter existing Client Name: " raw_name
    local client_name
    client_name=$(sanitize_name "$raw_name")
    local ovpn_path="${CLIENT_DIR}/${client_name}.ovpn"

    if [[ ! -f "$ovpn_path" && ! -d "${CLIENT_DIR}/${client_name}_mikrotik" ]]; then
        msg_error "No profile found for client '${client_name}'."
        return 1
    fi

    echo -e "\n${BOLD}Select Target Device to View Guidelines:${NC}"
    echo "   1) iPhone / iPad (iOS)"
    echo "   2) Mac (macOS)"
    echo "   3) MikroTik RouterOS"
    echo "   4) Android"
    echo "   5) Windows"
    echo "   6) Linux"
    read -rp "Select device [1-6, default 1]: " dev_choice

    local dev_type="ios"
    case "$dev_choice" in
        2) dev_type="mac" ;;
        3) dev_type="mikrotik" ;;
        4) dev_type="android" ;;
        5) dev_type="windows" ;;
        6) dev_type="linux" ;;
        *) dev_type="ios" ;;
    esac

    if [[ "$dev_type" == "ios" || "$dev_type" == "android" ]]; then
        display_qr_code "$ovpn_path"
    fi

    print_device_guidelines "$dev_type" "$client_name" "$ovpn_path"
}

# ==============================================================================
# Main Interactive Menu Routing
# ==============================================================================
action="${1:-menu}"

case "$action" in
    add|create)
        add_client
        ;;
    revoke|delete|remove)
        revoke_client
        ;;
    list|ls)
        list_clients
        ;;
    show|export)
        show_client_guidelines
        ;;
    menu|*)
        while true; do
            msg_section "OpenVPN User Management Menu"
            echo "   1) Add / Create New User Profile"
            echo "   2) Revoke / Remove User Access"
            echo "   3) List All Active Users"
            echo "   4) Show Setup Guidelines & QR Code for Existing User"
            echo "   5) Exit"
            read -rp "Select an option [1-5]: " choice
            case "$choice" in
                1) add_client ;;
                2) revoke_client ;;
                3) list_clients ;;
                4) show_client_guidelines ;;
                5) exit 0 ;;
                *) msg_warn "Invalid option. Please select 1-5." ;;
            esac
        done
        ;;
esac
