#!/usr/bin/env bash
# ==============================================================================
# Client Profile Templates & Device Guidelines Helper for OpenVPN Installer
# ==============================================================================

# Render unified .ovpn client profile file with embedded certificates
generate_standard_ovpn() {
    local client_name="$1"
    local server_ip="$2"
    local port="$3"
    local proto="$4"
    local cipher="$5"
    local output_path="$6"
    local pki_dir="$7"

    local ca_cert="${pki_dir}/ca.crt"
    local client_cert="${pki_dir}/issued/${client_name}.crt"
    local client_key="${pki_dir}/private/${client_name}.key"
    local tls_key="/etc/openvpn/tls-crypt.key"

    if [[ ! -f "$ca_cert" || ! -f "$client_cert" || ! -f "$client_key" ]]; then
        msg_error "Required client certificates or CA files missing!"
        return 1
    fi

    cat <<EOF > "$output_path"
client
dev tun
proto ${proto}
remote ${server_ip} ${port}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher ${cipher}
auth SHA256
key-direction 1
verb 3

<ca>
$(cat "$ca_cert")
</ca>
<cert>
$(openssl x509 -in "$client_cert")
</cert>
<key>
$(cat "$client_key")
</key>
EOF

    if [[ -f "$tls_key" ]]; then
        cat <<EOF >> "$output_path"
<tls-crypt>
$(cat "$tls_key")
</tls-crypt>
EOF
    fi

    msg_success "Client profile generated at: ${output_path}"
}

# Render MikroTik RouterOS Configuration & CLI Script
generate_mikrotik_config() {
    local client_name="$1"
    local server_ip="$2"
    local port="$3"
    local proto="$4"
    local cipher="$5"
    local output_dir="$6"
    local pki_dir="$7"

    mkdir -p "$output_dir"

    local ca_cert="${pki_dir}/ca.crt"
    local client_cert="${pki_dir}/issued/${client_name}.crt"
    local client_key="${pki_dir}/private/${client_name}.key"

    cp "$ca_cert" "${output_dir}/ca.crt"
    cp "$client_cert" "${output_dir}/${client_name}.crt"
    cp "$client_key" "${output_dir}/${client_name}.key"

    # Also generate a standard .ovpn file for RouterOS v7 import
    generate_standard_ovpn "$client_name" "$server_ip" "$port" "$proto" "$cipher" "${output_dir}/${client_name}.ovpn" "$pki_dir"

    # Map cipher to valid MikroTik RouterOS cipher name (aes256 or aes128)
    local mikrotik_cipher="aes256"
    case "$cipher" in
        *128*) mikrotik_cipher="aes128" ;;
        *)     mikrotik_cipher="aes256" ;;
    esac

    # Generate RouterOS Import & Setup CLI Commands script
    cat <<EOF > "${output_dir}/mikrotik_setup.rsc"
# ==============================================================================
# MikroTik RouterOS Setup Script for OpenVPN Client (${client_name})
# ==============================================================================
# 1. Upload ca.crt, ${client_name}.crt, and ${client_name}.key to MikroTik files
# 2. Open RouterOS Terminal and run the commands below:

# Step A: Import Certificates
/certificate import file-name=ca.crt passphrase=""
/certificate import file-name=${client_name}.crt passphrase=""
/certificate import file-name=${client_name}.key passphrase=""

# Step B: Create OpenVPN Client Interface (RouterOS v7)
/interface ovpn-client add name="ovpn-${client_name}" \
    connect-to="${server_ip}" \
    port=${port} \
    mode=ip \
    user="${client_name}" \
    password="" \
    profile=default-encryption \
    certificate=${client_name}.crt_0 \
    auth=sha256 \
    cipher=${mikrotik_cipher} \
    add-default-route=yes \
    disabled=no

# Alternative for RouterOS v6 (requires auth=sha1 and TCP):
# /interface ovpn-client add name="ovpn-${client_name}" connect-to="${server_ip}" port=${port} mode=ip user="${client_name}" certificate=${client_name}.crt_0 auth=sha1 cipher=${mikrotik_cipher} add-default-route=yes disabled=no

# Step C: Firewall NAT for LAN Clients behind MikroTik
/ip firewall nat add chain=srcnat out-interface="ovpn-${client_name}" action=masquerade comment="OpenVPN Outbound NAT"
EOF

    msg_success "MikroTik files exported to: ${output_dir}"
}

# Print Mobile ASCII QR Code for .ovpn file
display_qr_code() {
    local filepath="$1"
    if command -v qrencode &>/dev/null; then
        msg_section "Scan QR Code with OpenVPN Mobile App (iOS / Android)"
        qrencode -t ANSI256 -r "$filepath" 2>/dev/null || qrencode -t UTF8 -r "$filepath" 2>/dev/null || true
    else
        msg_info "Tip: Install 'qrencode' package on server to display mobile QR codes directly in terminal."
    fi
}

# Output Platform-Specific Instructions & Guidelines
print_device_guidelines() {
    local device_type="$1"
    local client_name="$2"
    local ovpn_path="$3"

    case "$device_type" in
        ios|iphone|ipad)
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}"
            echo -e "${BOLD}📱 SETUP GUIDELINES FOR APPLE iOS (iPhone / iPad):${NC}"
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}"
            echo -e " 1. Install ${BOLD}'OpenVPN Connect'${NC} from the Apple App Store."
            echo -e " 2. Transfer the file ${YELLOW}${ovpn_path}${NC} to your iPhone:"
            echo -e "    - Option A: AirDrop the .ovpn file directly to your iOS device."
            echo -e "    - Option B: Save to iCloud Drive / Files app, tap the file, and open with OpenVPN."
            echo -e "    - Option C: Scan the QR code shown below (if applicable)."
            echo -e " 3. In the OpenVPN Connect app, tap ${GREEN}'ADD'${NC} to import the profile."
            echo -e " 4. Toggle the switch to CONNECT."
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}\n"
            ;;

        mac|macos)
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}"
            echo -e "${BOLD}💻 SETUP GUIDELINES FOR macOS:${NC}"
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}"
            echo -e " Recommended App: ${BOLD}Tunnelblick${NC} (Free & Open Source) or ${BOLD}OpenVPN Connect for Mac${NC}."
            echo -e " 1. Download & Install Tunnelblick from ${UNDERLINE}https://tunnelblick.net${NC}"
            echo -e " 2. Download the client profile file: ${YELLOW}${ovpn_path}${NC}"
            echo -e " 3. Double-click the ${BOLD}${client_name}.ovpn${NC} file to automatically import it into Tunnelblick."
            echo -e " 4. Click the Tunnelblick icon in the menu bar and select ${GREEN}'Connect ${client_name}'${NC}."
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}\n"
            ;;

        mikrotik|routeros)
            local mikrotik_cipher="aes256"
            case "${CIPHER:-AES-256-GCM}" in
                *128*) mikrotik_cipher="aes128" ;;
                *)     mikrotik_cipher="aes256" ;;
            esac

            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}"
            echo -e "${BOLD}🔌 SETUP GUIDELINES FOR MIKROTIK ROUTEROS:${NC}"
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}"
            echo -e " MikroTik files generated in directory: ${YELLOW}$(dirname "$ovpn_path" 2>/dev/null || echo "$ovpn_path")${NC}"
            echo -e " Files include: ${BOLD}ca.crt${NC}, ${BOLD}${client_name}.crt${NC}, ${BOLD}${client_name}.key${NC}, and ${BOLD}mikrotik_setup.rsc${NC}"
            echo -e ""
            echo -e " ${BOLD}Steps to configure on RouterOS:${NC}"
            echo -e " 1. Upload ${BOLD}ca.crt${NC}, ${BOLD}${client_name}.crt${NC}, and ${BOLD}${client_name}.key${NC} via WinBox -> Files (or SFTP)."
            echo -e " 2. Open WinBox Terminal (or SSH into RouterOS)."
            echo -e " 3. Import certificates:"
            echo -e "    ${CYAN}/certificate import file-name=ca.crt passphrase=\"\"${NC}"
            echo -e "    ${CYAN}/certificate import file-name=${client_name}.crt passphrase=\"\"${NC}"
            echo -e "    ${CYAN}/certificate import file-name=${client_name}.key passphrase=\"\"${NC}"
            echo -e " 4. Add OpenVPN client interface (RouterOS v7):"
            echo -e "    ${GREEN}/interface ovpn-client add name=\"ovpn-${client_name}\" connect-to=\"${PUBLIC_IP:-SERVER_IP}\" port=${OPENVPN_PORT:-1194} mode=ip user=\"${client_name}\" certificate=${client_name}.crt_0 auth=sha256 cipher=${mikrotik_cipher} add-default-route=yes disabled=no${NC}"
            echo -e " 5. Alternative for RouterOS v6 (requires auth=sha1):"
            echo -e "    ${CYAN}/interface ovpn-client add name=\"ovpn-${client_name}\" connect-to=\"${PUBLIC_IP:-SERVER_IP}\" port=${OPENVPN_PORT:-1194} mode=ip user=\"${client_name}\" certificate=${client_name}.crt_0 auth=sha1 cipher=${mikrotik_cipher} add-default-route=yes disabled=no${NC}"
            echo -e " Note: On RouterOS v6, ensure OpenVPN Server protocol is set to TCP."
            echo -e " Note: On RouterOS v7, both UDP and TCP protocols are supported."
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}\n"
            ;;

        android)
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}"
            echo -e "${BOLD}🤖 SETUP GUIDELINES FOR ANDROID:${NC}"
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}"
            echo -e " Recommended App: ${BOLD}OpenVPN for Android${NC} (by Arne Schwabe) or ${BOLD}OpenVPN Connect${NC}."
            echo -e " 1. Install the app from Google Play Store."
            echo -e " 2. Transfer ${YELLOW}${ovpn_path}${NC} to your Android storage or scan the QR Code below."
            echo -e " 3. Import the profile in the app and tap Connect."
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}\n"
            ;;

        windows)
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}"
            echo -e "${BOLD}🪟 SETUP GUIDELINES FOR WINDOWS:${NC}"
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}"
            echo -e " Recommended App: ${BOLD}OpenVPN GUI for Windows${NC}."
            echo -e " 1. Download and install OpenVPN from ${UNDERLINE}https://openvpn.net/community-downloads/${NC}"
            echo -e " 2. Copy ${YELLOW}${ovpn_path}${NC} to ${BOLD}C:\\Program Files\\OpenVPN\\config\\${NC}"
            echo -e " 3. Right-click OpenVPN GUI in the system tray and click ${GREEN}'Connect'${NC}."
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}\n"
            ;;

        *)
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}"
            echo -e "${BOLD}🐧 SETUP GUIDELINES FOR LINUX / GENERIC CLIENT:${NC}"
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}"
            echo -e " To connect from a Linux terminal:"
            echo -e " 1. Install openvpn: ${CYAN}sudo apt install openvpn${NC} or ${CYAN}sudo dnf install openvpn${NC}"
            echo -e " 2. Run OpenVPN with profile:"
            echo -e "    ${GREEN}sudo openvpn --config ${ovpn_path}${NC}"
            echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}\n"
            ;;
    esac
}
