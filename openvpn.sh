#!/usr/bin/env bash
# ==============================================================================
# OpenVPN Server Installer & Manager Launcher
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

check_root
detect_os

# Check installation status
if load_installer_vars 2>/dev/null; then
    IS_INSTALLED=true
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
    msg_section "OpenVPN Control Center"
    echo -e "Server Public IP : ${CYAN}${PUBLIC_IP}${NC}"
    echo -e "Port / Protocol  : ${CYAN}${OPENVPN_PORT} / ${OPENVPN_PROTO}${NC}"
    echo -e "VPN Subnet       : ${CYAN}${OPENVPN_CIDR}${NC}\n"

    echo "   1) User Management (Add, Revoke, List, Export Profiles)"
    echo "   2) Create a New User Profile"
    echo "   3) Check OpenVPN Service Status & Active Connections"
    echo "   4) Uninstall OpenVPN Server"
    echo "   5) Exit"
    read -rp "Select an option [1-5]: " main_choice

    case "$main_choice" in
        1)
            "${SCRIPT_DIR}/user-management.sh" menu
            ;;
        2)
            "${SCRIPT_DIR}/user-management.sh" add
            ;;
        3)
            msg_section "OpenVPN Service & Active Connections"
            systemctl status openvpn-server@server --no-pager 2>/dev/null || systemctl status openvpn@server --no-pager 2>/dev/null || true
            if [[ -f /var/log/openvpn/openvpn-status.log ]]; then
                msg_info "Recent Active Connections Log (/var/log/openvpn/openvpn-status.log):"
                cat /var/log/openvpn/openvpn-status.log
            fi
            echo ""
            read -rp "Press Enter to return to main menu..."
            ;;
        4)
            "${SCRIPT_DIR}/uninstall.sh"
            exit 0
            ;;
        5)
            exit 0
            ;;
        *)
            msg_warn "Invalid option. Please select 1-5."
            ;;
    esac
done
