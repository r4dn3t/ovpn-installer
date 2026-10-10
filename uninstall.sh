#!/usr/bin/env bash
# ==============================================================================
# OpenVPN Server Uninstallation Script
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/firewall.sh"

check_root
detect_os

msg_section "OpenVPN Server Uninstallation Wizard"

if ! load_installer_vars 2>/dev/null; then
    msg_warn "OpenVPN installer configuration /etc/openvpn/installer-vars.conf was not found."
    read -rp "Are you sure you want to attempt manual cleanup of OpenVPN? [y/N]: " confirm_manual
    if [[ ! "$confirm_manual" =~ ^[Yy]$ ]]; then
        exit 0
    fi
    PUBLIC_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)
    OPENVPN_PROTO="udp"
    OPENVPN_PORT="1194"
    OPENVPN_CIDR="10.8.0.0/24"
fi

echo -e "${RED}${BOLD}WARNING: This action will stop OpenVPN server, remove firewall rules, and delete all client profiles and CA keys!${NC}"
read -rp "Do you want to proceed with uninstallation? [y/N]: " confirm_uninstall
if [[ ! "$confirm_uninstall" =~ ^[Yy]$ ]]; then
    msg_info "Uninstallation aborted."
    exit 0
fi

# Step 1: Backup client profiles if requested
CLIENT_DIR="${CLIENT_DIR:-/etc/openvpn/client-profiles}"
if [[ -d "$CLIENT_DIR" ]] && [[ "$(ls -A "$CLIENT_DIR" 2>/dev/null)" ]]; then
    read -rp "Would you like to backup generated client profiles before removal? [Y/n]: " backup_choice
    backup_choice="${backup_choice:-Y}"
    if [[ "$backup_choice" =~ ^[Yy]$ ]]; then
        BACKUP_FILE="/root/openvpn-clients-backup-$(date +%Y%m%d_%H%M%S).tar.gz"
        tar -czf "$BACKUP_FILE" -C "$CLIENT_DIR" . 2>/dev/null || true
        msg_success "Client profiles backed up to: ${BACKUP_FILE}"
    fi
fi

# Step 2: Stop and Disable OpenVPN Systemd Services
msg_info "Stopping OpenVPN services..."
systemctl disable --now openvpn-server@server &>/dev/null || true
systemctl disable --now openvpn@server &>/dev/null || true
systemctl stop openvpn-server@server &>/dev/null || true
systemctl stop openvpn@server &>/dev/null || true

# Step 3: Remove Firewall NAT Rules
remove_firewall "$OPENVPN_PROTO" "$OPENVPN_PORT" "$OPENVPN_CIDR" "$PUBLIC_IFACE"

# Step 4: Remove Configuration, Keys & PKI Files
msg_info "Removing OpenVPN directories and configuration files..."
rm -rf /etc/openvpn/server
rm -rf /etc/openvpn/easy-rsa
rm -rf /etc/openvpn/client-profiles
rm -f /etc/openvpn/tls-crypt.key
rm -f /etc/openvpn/installer-vars.conf
rm -rf /var/log/openvpn

# Step 5: Optional Package Purge
echo -e "\n${BOLD}Package Cleanup Option:${NC}"
read -rp "Do you want to uninstall OpenVPN and Easy-RSA packages from the system? [y/N]: " remove_pkgs
if [[ "$remove_pkgs" =~ ^[Yy]$ ]]; then
    msg_info "Removing packages..."
    case "$OS_FAMILY" in
        debian)
            apt-get remove --purge -y -qq openvpn easy-rsa || true
            apt-get autoremove -y -qq || true
            ;;
        redhat)
            $PKG_MANAGER remove -y openvpn easy-rsa || true
            ;;
        arch)
            pacman -Rns --noconfirm openvpn easy-rsa || true
            ;;
    esac
    msg_success "Packages removed."
fi

msg_section "Uninstallation Complete!"
msg_success "OpenVPN Server has been successfully removed from this system."
