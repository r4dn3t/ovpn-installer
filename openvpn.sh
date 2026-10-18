#!/usr/bin/env bash
# ==============================================================================
# OpenVPN Server Installer & Manager Launcher
# ==============================================================================

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/firewall.sh"

check_root
detect_os

# Check installation status
if is_installed; then
    IS_INSTALLED=true
    repair_server_config
    load_installer_vars 2>/dev/null || true
    # Only re-apply rules if IPTABLES_ENABLED is not explicitly 0
    if [[ "${IPTABLES_ENABLED:-1}" != "0" ]]; then
        apply_iptables_rules "${OPENVPN_PROTO:-udp}" "${OPENVPN_PORT:-1194}" "${OPENVPN_CIDR:-10.8.0.0/24}" "${PUBLIC_IFACE:-}" "${OUTBOUND_IP:-${PUBLIC_IP:-}}" "${NAT_MODE:-SNAT}"
    fi
else
    IS_INSTALLED=false
fi

if [[ "$IS_INSTALLED" == false ]]; then
    msg_section "Welcome to OpenVPN Server Installer"
    echo -e "Operating System: ${BOLD}${OS_NAME}${NC}"
    echo -e "Status          : ${YELLOW}Not Installed${NC}\n"
    read -rp "Would you like to install OpenVPN Server now? [Y/n]: " start_install
    start_install="${start_install:-Y}"
    if [[ "$start_install" =~ ^[Yy]$ ]]; then
        exec "${SCRIPT_DIR}/install.sh"
    else
        msg_info "Installation cancelled. Run ./openvpn.sh anytime to start installation."
        exit 0
    fi
fi

# Main Menu Loop for Installed Server Management
while true; do
    load_installer_vars 2>/dev/null || true
    CONF_FILE="/etc/openvpn/server/server.conf"
    local_has_tls_crypt=false
    if grep -qE '^tls-crypt' "$CONF_FILE" 2>/dev/null; then
        local_has_tls_crypt=true
        MIKROTIK_STATUS="${YELLOW}Disabled (tls-crypt active)${NC}"
    else
        MIKROTIK_STATUS="${GREEN}Enabled (Standard TLS / MikroTik Ready)${NC}"
    fi

    iptables_summary=""
    if is_iptables_active "${OPENVPN_CIDR:-10.8.0.0/24}"; then
        iptables_summary="${GREEN}Active ($(get_iptables_nat_mode "${OPENVPN_CIDR:-10.8.0.0/24}"))${NC}"
    else
        iptables_summary="${RED}Disabled / Inactive${NC}"
    fi

    msg_section "OpenVPN Control Center"
    echo -e "Server Public IP : ${CYAN}${PUBLIC_IP:-Unknown}${NC}"
    echo -e "Port / Protocol  : ${CYAN}${OPENVPN_PORT:-1194} / ${OPENVPN_PROTO:-udp}${NC}"
    echo -e "VPN Subnet       : ${CYAN}${OPENVPN_CIDR:-10.8.0.0/24}${NC}"
    echo -e "MikroTik Support : ${MIKROTIK_STATUS}"
    echo -e "iptables Rules   : ${iptables_summary}\n"

    echo "   1) User Management (Add, Revoke, List, Export Profiles)"
    echo "   2) Create a New User Profile"
    echo "   3) Display Installation Directories & Generated Profiles (Detail Info)"
    echo "   4) Toggle MikroTik Compatibility (Enable/Disable tls-crypt)"
    echo "   5) Firewall & iptables Rules Management (Toggle, SNAT/MASQUERADE, Persist)"
    echo "   6) Run Server Diagnostics & Repair Configuration"
    echo "   7) Check OpenVPN Service Status & Active Connections"
    echo "   8) Uninstall OpenVPN Server"
    echo "   9) Exit"
    read -rp "Select an option [1-9]: " main_choice

    case "$main_choice" in
        1)
            "${SCRIPT_DIR}/user-management.sh" menu
            ;;
        2)
            "${SCRIPT_DIR}/user-management.sh" add
            ;;
        3)
            show_detailed_info
            read -rp "Press Enter to return to main menu..."
            ;;
        4)
            if [[ "$local_has_tls_crypt" == true ]]; then
                msg_info "Disabling tls-crypt for MikroTik RouterOS compatibility..."
                sed -i 's/^tls-crypt /#tls-crypt /' "$CONF_FILE"
                systemctl restart openvpn-server@server &>/dev/null || systemctl restart openvpn@server &>/dev/null || true
                msg_success "MikroTik Compatibility ENABLED! Standard TLS active."
            else
                msg_info "Enabling tls-crypt for maximum security..."
                if grep -qE '^#tls-crypt' "$CONF_FILE"; then
                    sed -i 's/^#tls-crypt /tls-crypt /' "$CONF_FILE"
                else
                    echo "tls-crypt /etc/openvpn/tls-crypt.key" >> "$CONF_FILE"
                fi
                systemctl restart openvpn-server@server &>/dev/null || systemctl restart openvpn@server &>/dev/null || true
                msg_success "tls-crypt ENABLED! (Note: Hardware routers like MikroTik cannot connect with tls-crypt)."
            fi
            read -rp "Press Enter to return to main menu..."
            ;;
        5)
            manage_firewall_menu
            ;;
        6)
            msg_section "Server Diagnostics & Configuration Repair"
            repair_server_config
            apply_iptables_rules "${OPENVPN_PROTO:-udp}" "${OPENVPN_PORT:-1194}" "${OPENVPN_CIDR:-10.8.0.0/24}" "${PUBLIC_IFACE:-}" "${OUTBOUND_IP:-${PUBLIC_IP:-}}" "${NAT_MODE:-SNAT}"
            create_persistent_firewall_script "${OPENVPN_PROTO:-udp}" "${OPENVPN_PORT:-1194}" "${OPENVPN_CIDR:-10.8.0.0/24}" "${PUBLIC_IFACE:-}" "${OUTBOUND_IP:-${PUBLIC_IP:-}}" "${NAT_MODE:-SNAT}"
            msg_success "Configuration checked, and iptables rules re-applied and persisted."
            read -rp "Press Enter to return to main menu..."
            ;;
        7)
            msg_section "OpenVPN Service & Active Connections"
            systemctl status openvpn-server@server --no-pager 2>/dev/null || systemctl status openvpn@server --no-pager 2>/dev/null || true
            if [[ -f /var/log/openvpn/openvpn-status.log ]]; then
                msg_info "Recent Active Connections Log (/var/log/openvpn/openvpn-status.log):"
                cat /var/log/openvpn/openvpn-status.log
            fi
            echo ""
            read -rp "Press Enter to return to main menu..."
            ;;
        8)
            "${SCRIPT_DIR}/uninstall.sh"
            exit 0
            ;;
        9)
            exit 0
            ;;
        *)
            msg_warn "Invalid option. Please select 1-9."
            ;;
    esac
done
