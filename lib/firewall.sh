#!/usr/bin/env bash
# ==============================================================================
# Firewall & NAT Rules Management Helper for OpenVPN Installer
# ==============================================================================

# Check if OpenVPN forwarding or NAT rules are active in iptables
is_iptables_active() {
    local subnet="${1:-${OPENVPN_CIDR:-10.8.0.0/24}}"
    if iptables -C FORWARD -s "$subnet" -j ACCEPT 2>/dev/null || \
       iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- "-s ${subnet}"; then
        return 0
    fi
    return 1
}

# Determine the active NAT mode and translation IP in iptables
get_iptables_nat_mode() {
    local subnet="${1:-${OPENVPN_CIDR:-10.8.0.0/24}}"
    local snat_match
    snat_match=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -- "-s ${subnet}.*-j SNAT" | head -n1 || true)
    if [[ -n "$snat_match" ]]; then
        local ip
        ip=$(echo "$snat_match" | grep -oP '(?<=--to-source\s)[0-9.]+' || true)
        if [[ -n "$ip" ]]; then
            echo "SNAT ($ip)"
        else
            echo "SNAT"
        fi
        return 0
    fi
    if iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- "-s ${subnet}.*-j MASQUERADE"; then
        echo "MASQUERADE"
        return 0
    fi
    echo "Inactive"
    return 1
}

# Completely flush all OpenVPN-specific iptables rules (FORWARD, DOCKER-USER, NAT, INPUT)
flush_openvpn_iptables_rules() {
    local proto="${1:-${OPENVPN_PROTO:-udp}}"
    local port="${2:-${OPENVPN_PORT:-1194}}"
    local subnet="${3:-${OPENVPN_CIDR:-10.8.0.0/24}}"
    local iface="${4:-${PUBLIC_IFACE:-}}"

    # Clean INPUT rules for OpenVPN port
    while iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; do :; done

    # Clean FORWARD rules
    while iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -s "$subnet" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i tun+ -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -o tun+ -j ACCEPT 2>/dev/null; do :; done

    # Clean DOCKER-USER chain rules
    if iptables -L DOCKER-USER &>/dev/null; then
        while iptables -D DOCKER-USER -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
        while iptables -D DOCKER-USER -s "$subnet" -j ACCEPT 2>/dev/null; do :; done
        while iptables -D DOCKER-USER -i tun+ -j ACCEPT 2>/dev/null; do :; done
        while iptables -D DOCKER-USER -o tun+ -j ACCEPT 2>/dev/null; do :; done
    fi

    # Clean all POSTROUTING NAT rules targeting the VPN subnet
    while true; do
        local rule_num=""
        rule_num=$(iptables -t nat -L POSTROUTING --line-numbers -n 2>/dev/null | awk -v sub="$subnet" '$0 ~ sub {print $1; exit}' || true)
        if [[ -n "$rule_num" && "$rule_num" =~ ^[0-9]+$ ]]; then
            iptables -t nat -D POSTROUTING "$rule_num" 2>/dev/null || break
        else
            break
        fi
    done
}

# Apply iptables NAT & Forwarding rules (including Docker compatibility & SNAT)
apply_iptables_rules() {
    local proto="${1:-${OPENVPN_PROTO:-udp}}"
    local port="${2:-${OPENVPN_PORT:-1194}}"
    local subnet="${3:-${OPENVPN_CIDR:-10.8.0.0/24}}"
    local iface="${4:-${PUBLIC_IFACE:-}}"
    local outbound_ip="${5:-${OUTBOUND_IP:-${PUBLIC_IP:-}}}"
    local nat_mode="${6:-${NAT_MODE:-SNAT}}"

    if [[ -z "$iface" ]]; then
        iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)
    fi

    # Ensure kernel packet forwarding is active
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true

    # Flush existing OpenVPN rules to prevent stale orders and duplicates
    flush_openvpn_iptables_rules "$proto" "$port" "$subnet" "$iface"

    # 1. Allow OpenVPN Incoming Port
    iptables -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT

    # 2. Allow Packet Forwarding (required when Docker sets FORWARD DROP)
    iptables -I FORWARD 1 -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -I FORWARD 2 -s "$subnet" -j ACCEPT
    iptables -I FORWARD 3 -i tun+ -j ACCEPT
    iptables -I FORWARD 4 -o tun+ -j ACCEPT

    # 3. Docker Chain Compatibility (Docker redirects FORWARD to DOCKER-USER)
    if iptables -L DOCKER-USER &>/dev/null; then
        iptables -I DOCKER-USER 1 -m state --state RELATED,ESTABLISHED -j ACCEPT
        iptables -I DOCKER-USER 2 -s "$subnet" -j ACCEPT
        iptables -I DOCKER-USER 3 -i tun+ -j ACCEPT
        iptables -I DOCKER-USER 4 -o tun+ -j ACCEPT
    fi

    # 4. NAT Table POSTROUTING: SNAT vs MASQUERADE
    if [[ "$nat_mode" == "SNAT" ]] && is_valid_ip "$outbound_ip" && [[ "$outbound_ip" != "127.0.0.1" ]]; then
        if [[ -n "$iface" ]]; then
            iptables -t nat -I POSTROUTING 1 -s "$subnet" -o "$iface" -j SNAT --to-source "$outbound_ip"
        fi
        iptables -t nat -I POSTROUTING 2 -s "$subnet" ! -d "$subnet" -j SNAT --to-source "$outbound_ip"
    else
        # Dynamic interface IP MASQUERADE
        if [[ -n "$iface" ]]; then
            iptables -t nat -I POSTROUTING 1 -s "$subnet" -o "$iface" -j MASQUERADE
        fi
        iptables -t nat -I POSTROUTING 2 -s "$subnet" ! -d "$subnet" -j MASQUERADE
    fi

    # 5. Integration with UFW or Firewalld if running
    if systemctl is-active --quiet ufw 2>/dev/null; then
        ufw allow "${port}/${proto}" comment "OpenVPN Port" &>/dev/null || true
    elif systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --zone=public --add-port="${port}/${proto}" --permanent &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
    fi
}

# Create persistent script and systemd unit for firewall & NAT rules
create_persistent_firewall_script() {
    local proto="${1:-${OPENVPN_PROTO:-udp}}"
    local port="${2:-${OPENVPN_PORT:-1194}}"
    local subnet="${3:-${OPENVPN_CIDR:-10.8.0.0/24}}"
    local iface="${4:-${PUBLIC_IFACE:-}}"
    local outbound_ip="${5:-${OUTBOUND_IP:-${PUBLIC_IP:-}}}"
    local nat_mode="${6:-${NAT_MODE:-SNAT}}"

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
        # 1. Allow Incoming Port
        iptables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p ${proto} --dport ${port} -j ACCEPT

        # 2. Forwarding Chains
        iptables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -m state --state RELATED,ESTABLISHED -j ACCEPT
        iptables -C FORWARD -s ${subnet} -j ACCEPT 2>/dev/null || iptables -I FORWARD 2 -s ${subnet} -j ACCEPT
        iptables -C FORWARD -i tun+ -j ACCEPT 2>/dev/null || iptables -I FORWARD 3 -i tun+ -j ACCEPT
        iptables -C FORWARD -o tun+ -j ACCEPT 2>/dev/null || iptables -I FORWARD 4 -o tun+ -j ACCEPT

        # 3. Docker Chain Compatibility
        if iptables -L DOCKER-USER &>/dev/null; then
            iptables -C DOCKER-USER -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 1 -m state --state RELATED,ESTABLISHED -j ACCEPT
            iptables -C DOCKER-USER -s ${subnet} -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 2 -s ${subnet} -j ACCEPT
            iptables -C DOCKER-USER -i tun+ -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 3 -i tun+ -j ACCEPT
            iptables -C DOCKER-USER -o tun+ -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 4 -o tun+ -j ACCEPT
        fi
EOF

    if [[ "$nat_mode" == "SNAT" ]] && is_valid_ip "$outbound_ip" && [[ "$outbound_ip" != "127.0.0.1" ]]; then
        cat <<EOF >> /etc/openvpn/iptables-rules.sh

        # 4. SNAT Rules
        if [[ -n "${iface}" ]]; then
            iptables -t nat -C POSTROUTING -s ${subnet} -o ${iface} -j SNAT --to-source ${outbound_ip} 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s ${subnet} -o ${iface} -j SNAT --to-source ${outbound_ip}
        fi
        iptables -t nat -C POSTROUTING -s ${subnet} ! -d ${subnet} -j SNAT --to-source ${outbound_ip} 2>/dev/null || iptables -t nat -I POSTROUTING 2 -s ${subnet} ! -d ${subnet} -j SNAT --to-source ${outbound_ip}
        ;;
EOF
    else
        cat <<EOF >> /etc/openvpn/iptables-rules.sh

        # 4. MASQUERADE Rules
        if [[ -n "${iface}" ]]; then
            iptables -t nat -C POSTROUTING -s ${subnet} -o ${iface} -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s ${subnet} -o ${iface} -j MASQUERADE
        fi
        iptables -t nat -C POSTROUTING -s ${subnet} ! -d ${subnet} -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 2 -s ${subnet} ! -d ${subnet} -j MASQUERADE
        ;;
EOF
    fi

    cat <<EOF >> /etc/openvpn/iptables-rules.sh
    stop)
        while iptables -D INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null; do :; done
        while iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
        while iptables -D FORWARD -s ${subnet} -j ACCEPT 2>/dev/null; do :; done
        while iptables -D FORWARD -i tun+ -j ACCEPT 2>/dev/null; do :; done
        while iptables -D FORWARD -o tun+ -j ACCEPT 2>/dev/null; do :; done

        if iptables -L DOCKER-USER &>/dev/null; then
            while iptables -D DOCKER-USER -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
            while iptables -D DOCKER-USER -s ${subnet} -j ACCEPT 2>/dev/null; do :; done
            while iptables -D DOCKER-USER -i tun+ -j ACCEPT 2>/dev/null; do :; done
            while iptables -D DOCKER-USER -o tun+ -j ACCEPT 2>/dev/null; do :; done
        fi

        while true; do
            local rule_num=""
            rule_num=\$(iptables -t nat -L POSTROUTING --line-numbers -n 2>/dev/null | awk -v sub="${subnet}" '\$0 ~ sub {print \$1; exit}' || true)
            if [[ -n "\$rule_num" && "\$rule_num" =~ ^[0-9]+$ ]]; then
                iptables -t nat -D POSTROUTING "\$rule_num" 2>/dev/null || break
            else
                break
            fi
        done
        ;;
esac
EOF
    chmod +x /etc/openvpn/iptables-rules.sh

    # Create persistent systemd service
    cat <<EOF > /etc/systemd/system/openvpn-iptables.service
[Unit]
Description=OpenVPN Firewall & NAT Rules Persistence
After=network.target docker.service network-online.target
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

    # Also persist to /etc/iptables if iptables-persistent or netfilter-persistent is installed
    if command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save &>/dev/null || true
    fi
}

# Toggle OpenVPN iptables rules ON / OFF
toggle_iptables_rules() {
    load_installer_vars 2>/dev/null || true
    local proto="${OPENVPN_PROTO:-udp}"
    local port="${OPENVPN_PORT:-1194}"
    local subnet="${OPENVPN_CIDR:-10.8.0.0/24}"
    local iface="${PUBLIC_IFACE:-}"
    local outbound_ip="${OUTBOUND_IP:-${PUBLIC_IP:-}}"
    local nat_mode="${NAT_MODE:-SNAT}"

    if is_iptables_active "$subnet"; then
        msg_info "Disabling OpenVPN iptables rules..."
        flush_openvpn_iptables_rules "$proto" "$port" "$subnet" "$iface"
        systemctl stop openvpn-iptables.service &>/dev/null || true
        systemctl disable openvpn-iptables.service &>/dev/null || true
        IPTABLES_ENABLED="0"
        save_installer_vars
        if command -v iptables-save &>/dev/null; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save &>/dev/null || true
        fi
        msg_success "OpenVPN iptables rules have been DISABLED."
    else
        msg_info "Enabling OpenVPN iptables rules..."
        apply_iptables_rules "$proto" "$port" "$subnet" "$iface" "$outbound_ip" "$nat_mode"
        create_persistent_firewall_script "$proto" "$port" "$subnet" "$iface" "$outbound_ip" "$nat_mode"
        IPTABLES_ENABLED="1"
        save_installer_vars
        msg_success "OpenVPN iptables rules have been ENABLED and persisted (${nat_mode})."
    fi
}

# Interactive Management Menu for Firewall & iptables
manage_firewall_menu() {
    while true; do
        load_installer_vars 2>/dev/null || true
        local proto="${OPENVPN_PROTO:-udp}"
        local port="${OPENVPN_PORT:-1194}"
        local subnet="${OPENVPN_CIDR:-10.8.0.0/24}"
        local iface="${PUBLIC_IFACE:-}"
        local outbound_ip="${OUTBOUND_IP:-${PUBLIC_IP:-}}"
        local nat_mode="${NAT_MODE:-SNAT}"

        local status_text
        if is_iptables_active "$subnet"; then
            status_text="${GREEN}ACTIVE ($(get_iptables_nat_mode "$subnet"))${NC}"
        else
            status_text="${RED}DISABLED / INACTIVE${NC}"
        fi

        local ip_forward_val
        ip_forward_val=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")

        msg_section "Firewall & iptables Rules Management"
        echo -e "Current Status Overview:"
        echo -e "   - iptables Rules      : ${status_text}"
        echo -e "   - Configured NAT Mode : ${BOLD}${nat_mode}${NC} (Outbound IP: ${CYAN}${outbound_ip}${NC})"
        echo -e "   - Outbound Interface  : ${CYAN}${iface:-auto}${NC}"
        echo -e "   - VPN Subnet CIDR     : ${CYAN}${subnet}${NC}"
        echo -e "   - Kernel IP Forward   : ${CYAN}${ip_forward_val}${NC}"
        echo -e "   - Persistence Service : ${CYAN}openvpn-iptables.service${NC}\n"

        echo "   1) Toggle iptables Rules ON / OFF"
        echo "   2) Switch NAT Translation Mode (SNAT vs MASQUERADE)"
        echo "   3) Change Outbound SNAT IP (Current: ${outbound_ip})"
        echo "   4) Re-Apply & Persist Rules (Save to systemd & /etc/iptables)"
        echo "   5) View Raw iptables NAT & FORWARD Rules (Diagnostics)"
        echo "   6) Return to Main Menu"
        read -rp "Select an option [1-6]: " fw_choice

        case "$fw_choice" in
            1)
                toggle_iptables_rules
                read -rp "Press Enter to continue..."
                ;;
            2)
                if [[ "$nat_mode" == "SNAT" ]]; then
                    NAT_MODE="MASQUERADE"
                    msg_info "Switched NAT mode to: MASQUERADE"
                else
                    NAT_MODE="SNAT"
                    msg_info "Switched NAT mode to: SNAT (Source IP: ${outbound_ip})"
                fi
                save_installer_vars
                apply_iptables_rules "$proto" "$port" "$subnet" "$iface" "$outbound_ip" "$NAT_MODE"
                create_persistent_firewall_script "$proto" "$port" "$subnet" "$iface" "$outbound_ip" "$NAT_MODE"
                msg_success "NAT mode updated to ${NAT_MODE} and rules re-applied."
                read -rp "Press Enter to continue..."
                ;;
            3)
                echo -e "\nEnter new Outbound Public IPv4 for SNAT:"
                echo -e "Available IPs on ${iface}:"
                ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | while read -r rip; do
                    echo "   - $rip"
                done
                read -rp "Enter IP [default: ${outbound_ip}]: " input_snat_ip
                input_snat_ip="${input_snat_ip:-$outbound_ip}"
                if is_valid_ip "$input_snat_ip"; then
                    OUTBOUND_IP="$input_snat_ip"
                    NAT_MODE="SNAT"
                    save_installer_vars
                    apply_iptables_rules "$proto" "$port" "$subnet" "$iface" "$OUTBOUND_IP" "SNAT"
                    create_persistent_firewall_script "$proto" "$port" "$subnet" "$iface" "$OUTBOUND_IP" "SNAT"
                    msg_success "Outbound SNAT IP set to ${OUTBOUND_IP} and rules re-applied."
                else
                    msg_error "Invalid IP address: ${input_snat_ip}"
                fi
                read -rp "Press Enter to continue..."
                ;;
            4)
                msg_info "Re-applying and persisting iptables rules..."
                apply_iptables_rules "$proto" "$port" "$subnet" "$iface" "$outbound_ip" "$nat_mode"
                create_persistent_firewall_script "$proto" "$port" "$subnet" "$iface" "$outbound_ip" "$nat_mode"
                IPTABLES_ENABLED="1"
                save_installer_vars
                msg_success "iptables rules successfully re-applied and persisted."
                read -rp "Press Enter to continue..."
                ;;
            5)
                msg_section "Raw iptables Rules Dump"
                echo -e "${BOLD}--- [filter Table: FORWARD Chain] ---${NC}"
                iptables -L FORWARD -n -v --line-numbers 2>/dev/null || true
                echo -e "\n${BOLD}--- [filter Table: DOCKER-USER Chain] ---${NC}"
                iptables -L DOCKER-USER -n -v --line-numbers 2>/dev/null || echo "Chain DOCKER-USER does not exist"
                echo -e "\n${BOLD}--- [nat Table: POSTROUTING Chain] ---${NC}"
                iptables -t nat -L POSTROUTING -n -v --line-numbers 2>/dev/null || true
                echo ""
                read -rp "Press Enter to continue..."
                ;;
            6)
                break
                ;;
            *)
                msg_warn "Invalid option. Please select 1-6."
                ;;
        esac
    done
}

# Initial configuration during install.sh
setup_firewall() {
    local proto="$1"
    local port="$2"
    local subnet="$3"
    local iface="$4"
    local public_ip="${5:-${PUBLIC_IP:-}}"
    local nat_mode="${6:-SNAT}"

    msg_info "Enabling IPv4 forwarding in kernel..."
    mkdir -p /etc/sysctl.d
    cat <<EOF > /etc/sysctl.d/99-openvpn.conf
net.ipv4.ip_forward=1
EOF
    sysctl --system &>/dev/null || sysctl -p /etc/sysctl.d/99-openvpn.conf &>/dev/null || echo 1 > /proc/sys/net/ipv4/ip_forward

    apply_iptables_rules "$proto" "$port" "$subnet" "$iface" "$public_ip" "$nat_mode"
    create_persistent_firewall_script "$proto" "$port" "$subnet" "$iface" "$public_ip" "$nat_mode"
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

    flush_openvpn_iptables_rules "$proto" "$port" "$subnet" "$iface"
    rm -f /etc/openvpn/iptables-rules.sh

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

    # Update saved iptables dump if present
    if command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save &>/dev/null || true
    fi

    msg_success "Firewall rules removed."
}
