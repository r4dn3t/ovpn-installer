#!/usr/bin/env bash
# ==============================================================================
# Firewall & NAT Rules Management Helper for OpenVPN Installer
# ==============================================================================

# Apply iptables NAT & Forwarding rules (including Docker compatibility)
apply_iptables_rules() {
    local proto="${1:-udp}"
    local port="${2:-1194}"
    local subnet="${3:-10.8.0.0/24}"
    local iface="${4:-}"

    if [[ -z "$iface" ]]; then
        iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)
    fi

    # 1. Allow OpenVPN Incoming Port
    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT

    # 2. Allow Packet Forwarding (required when Docker sets FORWARD DROP)
    iptables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -m state --state RELATED,ESTABLISHED -j ACCEPT

    iptables -C FORWARD -s "$subnet" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 2 -s "$subnet" -j ACCEPT

    iptables -C FORWARD -i tun+ -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 3 -i tun+ -j ACCEPT

    iptables -C FORWARD -o tun+ -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 4 -o tun+ -j ACCEPT

    # 3. Docker Chain Compatibility (Docker redirects FORWARD to DOCKER-USER)
    if iptables -L DOCKER-USER &>/dev/null; then
        iptables -C DOCKER-USER -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -I DOCKER-USER 1 -m state --state RELATED,ESTABLISHED -j ACCEPT

        iptables -C DOCKER-USER -s "$subnet" -j ACCEPT 2>/dev/null || \
        iptables -I DOCKER-USER 2 -s "$subnet" -j ACCEPT

        iptables -C DOCKER-USER -i tun+ -j ACCEPT 2>/dev/null || \
        iptables -I DOCKER-USER 3 -i tun+ -j ACCEPT

        iptables -C DOCKER-USER -o tun+ -j ACCEPT 2>/dev/null || \
        iptables -I DOCKER-USER 4 -o tun+ -j ACCEPT
    fi

    # 4. NAT Table POSTROUTING Masquerade
    if [[ -n "$iface" ]]; then
        iptables -t nat -C POSTROUTING -s "$subnet" -o "$iface" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -I POSTROUTING 1 -s "$subnet" -o "$iface" -j MASQUERADE
    fi

    # Outbound masquerade fallback (any non-VPN destination)
    iptables -t nat -C POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -I POSTROUTING 2 -s "$subnet" ! -d "$subnet" -j MASQUERADE
}

# Create persistent script and systemd unit for firewall & NAT rules
create_persistent_firewall_script() {
    local proto="${1:-udp}"
    local port="${2:-1194}"
    local subnet="${3:-10.8.0.0/24}"
    local iface="${4:-}"

    if [[ -z "$iface" ]]; then
        iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)
    fi

    mkdir -p /etc/openvpn
    cat <<EOF > /etc/openvpn/iptables-rules.sh
#!/usr/bin/env bash
# OpenVPN Persistent Firewall & NAT Rules
action="\${1:-start}"

case "\$action" in
    start)
        iptables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p ${proto} --dport ${port} -j ACCEPT
        iptables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -m state --state RELATED,ESTABLISHED -j ACCEPT
        iptables -C FORWARD -s ${subnet} -j ACCEPT 2>/dev/null || iptables -I FORWARD 2 -s ${subnet} -j ACCEPT
        iptables -C FORWARD -i tun+ -j ACCEPT 2>/dev/null || iptables -I FORWARD 3 -i tun+ -j ACCEPT
        iptables -C FORWARD -o tun+ -j ACCEPT 2>/dev/null || iptables -I FORWARD 4 -o tun+ -j ACCEPT

        if iptables -L DOCKER-USER &>/dev/null; then
            iptables -C DOCKER-USER -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 1 -m state --state RELATED,ESTABLISHED -j ACCEPT
            iptables -C DOCKER-USER -s ${subnet} -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 2 -s ${subnet} -j ACCEPT
            iptables -C DOCKER-USER -i tun+ -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 3 -i tun+ -j ACCEPT
            iptables -C DOCKER-USER -o tun+ -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 4 -o tun+ -j ACCEPT
        fi

        if [[ -n "${iface}" ]]; then
            iptables -t nat -C POSTROUTING -s ${subnet} -o ${iface} -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s ${subnet} -o ${iface} -j MASQUERADE
        fi
        iptables -t nat -C POSTROUTING -s ${subnet} ! -d ${subnet} -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 2 -s ${subnet} ! -d ${subnet} -j MASQUERADE
        ;;
    stop)
        iptables -D INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -s ${subnet} -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -i tun+ -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -o tun+ -j ACCEPT 2>/dev/null || true

        if iptables -L DOCKER-USER &>/dev/null; then
            iptables -D DOCKER-USER -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
            iptables -D DOCKER-USER -s ${subnet} -j ACCEPT 2>/dev/null || true
            iptables -D DOCKER-USER -i tun+ -j ACCEPT 2>/dev/null || true
            iptables -D DOCKER-USER -o tun+ -j ACCEPT 2>/dev/null || true
        fi

        if [[ -n "${iface}" ]]; then
            iptables -t nat -D POSTROUTING -s ${subnet} -o ${iface} -j MASQUERADE 2>/dev/null || true
        fi
        iptables -t nat -D POSTROUTING -s ${subnet} ! -d ${subnet} -j MASQUERADE 2>/dev/null || true
        ;;
esac
EOF
    chmod +x /etc/openvpn/iptables-rules.sh

    # Create and enable persistent systemd service
    cat <<EOF > /etc/systemd/system/openvpn-iptables.service
[Unit]
Description=OpenVPN Firewall & NAT Rules Persistence
After=network.target docker.service
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/openvpn/iptables-rules.sh start
ExecStop=/etc/openvpn/iptables-rules.sh stop

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now openvpn-iptables.service &>/dev/null || true
}

# Configure IP Forwarding and Firewall NAT rules
setup_firewall() {
    local proto="$1"      # udp or tcp
    local port="$2"       # 1194
    local subnet="$3"     # 10.8.0.0/24
    local iface="$4"      # eth0 / ens34 etc.

    msg_info "Enabling IPv4 forwarding in kernel..."
    mkdir -p /etc/sysctl.d
    cat <<EOF > /etc/sysctl.d/99-openvpn.conf
net.ipv4.ip_forward=1
EOF
    sysctl --system &>/dev/null || sysctl -p /etc/sysctl.d/99-openvpn.conf &>/dev/null || echo 1 > /proc/sys/net/ipv4/ip_forward

    # Always apply direct iptables & Docker forwarding rules
    apply_iptables_rules "$proto" "$port" "$subnet" "$iface"
    create_persistent_firewall_script "$proto" "$port" "$subnet" "$iface"

    # Also integrate with Firewalld or UFW if active
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        msg_info "Configuring firewalld..."
        firewall-cmd --zone=trusted --add-source="$subnet" --permanent &>/dev/null || true
        firewall-cmd --zone=public --add-port="${port}/${proto}" --permanent &>/dev/null || true
        firewall-cmd --zone=public --add-masquerade --permanent &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
    elif systemctl is-active --quiet ufw 2>/dev/null; then
        msg_info "Configuring UFW (Uncomplicated Firewall)..."
        ufw allow "${port}/${proto}" comment "OpenVPN Port" &>/dev/null || true
        if [[ -f /etc/default/ufw ]]; then
            sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
        fi
        ufw reload &>/dev/null || true
    fi

    msg_success "Firewall NAT & forwarding rules applied successfully."
}

# Clean up Firewall NAT rules upon uninstallation
remove_firewall() {
    local proto="$1"
    local port="$2"
    local subnet="$3"
    local iface="$4"

    msg_info "Removing OpenVPN firewall rules..."

    # Stop and disable systemd persistence service
    systemctl disable --now openvpn-iptables.service &>/dev/null || true
    rm -f /etc/systemd/system/openvpn-iptables.service
    systemctl daemon-reload

    if [[ -f /etc/openvpn/iptables-rules.sh ]]; then
        /etc/openvpn/iptables-rules.sh stop 2>/dev/null || true
        rm -f /etc/openvpn/iptables-rules.sh
    fi

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --zone=trusted --remove-source="$subnet" --permanent &>/dev/null || true
        firewall-cmd --zone=public --remove-port="${port}/${proto}" --permanent &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
    elif systemctl is-active --quiet ufw 2>/dev/null; then
        ufw delete allow "${port}/${proto}" &>/dev/null || true
        ufw reload &>/dev/null || true
    fi

    # Remove sysctl configuration file
    if [[ -f /etc/sysctl.d/99-openvpn.conf ]]; then
        rm -f /etc/sysctl.d/99-openvpn.conf
        sysctl --system &>/dev/null || true
    fi

    msg_success "Firewall rules removed."
}
