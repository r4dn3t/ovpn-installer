#!/usr/bin/env bash
# ==============================================================================
# Firewall & NAT Rules Management Helper for OpenVPN Installer
# ==============================================================================

# Configure IP Forwarding and Firewall NAT rules
setup_firewall() {
    local proto="$1"      # udp or tcp
    local port="$2"       # 1194
    local subnet="$3"     # 10.8.0.0/24
    local iface="$4"      # eth0 / ens3 etc.

    msg_info "Enabling IPv4 forwarding in kernel..."
    mkdir -p /etc/sysctl.d
    cat <<EOF > /etc/sysctl.d/99-openvpn.conf
net.ipv4.ip_forward=1
EOF
    sysctl --system &>/dev/null || sysctl -p /etc/sysctl.d/99-openvpn.conf &>/dev/null || echo 1 > /proc/sys/net/ipv4/ip_forward

    # Detect Active Firewall Service
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        msg_info "Configuring firewalld..."
        firewall-cmd --zone=trusted --add-source="$subnet" --permanent &>/dev/null || true
        firewall-cmd --zone=public --add-port="${port}/${proto}" --permanent &>/dev/null || true
        firewall-cmd --zone=public --add-masquerade --permanent &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
    elif systemctl is-active --quiet ufw 2>/dev/null; then
        msg_info "Configuring UFW (Uncomplicated Firewall)..."
        ufw allow "${port}/${proto}" comment "OpenVPN Port" &>/dev/null || true

        # Enable routed traffic forwarding in /etc/default/ufw
        if [[ -f /etc/default/ufw ]]; then
            sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
        fi

        # Check if NAT rule is already in /etc/ufw/before.rules
        if ! grep -q "OpenVPN NAT Rules" /etc/ufw/before.rules 2>/dev/null; then
            local ufw_nat_block="
# START OpenVPN NAT Rules
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${subnet} -o ${iface} -j MASQUERADE
COMMIT
# END OpenVPN NAT Rules
"
            sed -i "1s/^/$ufw_nat_block\n/" /etc/ufw/before.rules
        fi
        ufw reload &>/dev/null || true
    else
        msg_info "Configuring direct iptables NAT and forwarding rules..."
        iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
        iptables -I FORWARD -s "$subnet" -j ACCEPT
        iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
        iptables -t nat -A POSTROUTING -s "$subnet" -o "$iface" -j MASQUERADE

        # Save iptables rules across reboots
        if command -v iptables-save &>/dev/null; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi

        # Ensure netfilter-persistent / iptables-persistent loads on boot if available
        if systemctl list-unit-files | grep -q netfilter-persistent; then
            systemctl enable netfilter-persistent &>/dev/null || true
        fi
    fi
    msg_success "Firewall rules applied successfully."
}

# Clean up Firewall NAT rules upon uninstallation
remove_firewall() {
    local proto="$1"
    local port="$2"
    local subnet="$3"
    local iface="$4"

    msg_info "Removing OpenVPN firewall rules..."

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --zone=trusted --remove-source="$subnet" --permanent &>/dev/null || true
        firewall-cmd --zone=public --remove-port="${port}/${proto}" --permanent &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
    elif systemctl is-active --quiet ufw 2>/dev/null; then
        ufw delete allow "${port}/${proto}" &>/dev/null || true
        if [[ -f /etc/ufw/before.rules ]]; then
            sed -i '/# START OpenVPN NAT Rules/,/# END OpenVPN NAT Rules/d' /etc/ufw/before.rules
        fi
        ufw reload &>/dev/null || true
    else
        iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -s "$subnet" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
        iptables -t nat -D POSTROUTING -s "$subnet" -o "$iface" -j MASQUERADE 2>/dev/null || true

        if command -v iptables-save &>/dev/null && [[ -f /etc/iptables/rules.v4 ]]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi

    # Remove sysctl configuration file
    if [[ -f /etc/sysctl.d/99-openvpn.conf ]]; then
        rm -f /etc/sysctl.d/99-openvpn.conf
        sysctl --system &>/dev/null || true
    fi

    msg_success "Firewall rules removed."
}
