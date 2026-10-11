# OpenVPN Server Suite: Complete Installer, User Manager & Uninstaller

A modular, robust, and secure Bash script suite designed to install, configure, manage users for, and uninstall an **OpenVPN Server** on Linux distributions.

---

## 🌟 Key Features

* **Multi-OS Detection & Support**: Automatically detects and configures dependencies on **Debian**, **Ubuntu**, **CentOS Stream**, **RHEL**, **Rocky Linux**, **AlmaLinux**, **Fedora**, and **Arch Linux**.
* **IP Auto-Detection**: Uses `api.ipify.org` as the primary public IPv4 detection endpoint with automated fallback mechanisms.
* **Detailed Path & Profile Inspector**: Displays a complete overview of all installation directories, PKI infrastructure keys, configuration files, and generated client `.ovpn` / MikroTik profiles.
* **Modern Cryptography & Security**: Supports modern Elliptic Curve Cryptography (`prime256v1` / ECDSA) and high-assurance RSA keys (2048/4096-bit), `AES-256-GCM` encryption, and `tls-crypt` packet authentication.
* **Flexible Networking**: Customize network interface, public IP / domain name, VPN CIDR IP range (e.g. `10.8.0.0/24`), protocol (UDP / TCP), custom port (default `1194`), and DNS resolvers (Cloudflare, Google, Quad9, OpenDNS, or Custom).
* **Automated Firewall NAT Configuration**: Seamless integration with **iptables**, **UFW**, and **firewalld**, with kernel IPv4 packet forwarding auto-configuration.
* **Platform-Specific Device Profiles & Guidelines**:
  * 📱 **iOS (iPhone/iPad)**: Single embedded `.ovpn` file + Terminal ASCII QR Code scanning.
  * 💻 **macOS**: Native profile format for **Tunnelblick** & OpenVPN Connect.
  * 🔌 **MikroTik RouterOS**: Specialized export format (`ca.crt`, `<client>.crt`, `<client>.key`, `<client>.ovpn`) plus copy-pasteable RouterOS CLI setup scripts (`mikrotik_setup.rsc`) compatible with RouterOS v6 and v7.
  * 🤖 **Android**: OpenVPN for Android / OpenVPN Connect support + QR code preview.
  * 🪟 **Windows**: Standard OpenVPN GUI file structure.
  * 🐧 **Linux**: Generic CLI connection profile.
* **Comprehensive Uninstallation**: Cleanly stops services, removes created NAT firewall rules, cleans systemd/sysctl configurations, and optionally purges packages with optional profile backups.

---

## 📁 Repository Structure

```
openvpn-installer/
├── openvpn.sh              # Interactive main control panel launcher
├── install.sh              # Installation wizard & PKI setup script
├── user-management.sh      # User creation, revocation, listing & export script
├── uninstall.sh            # Complete uninstallation & cleanup script
├── lib/
│   ├── common.sh           # OS detection, color outputs, input validations
│   ├── firewall.sh         # Firewall & NAT rule management (iptables/ufw/firewalld)
│   └── templates.sh        # Client profile generators & device setup guidelines
└── README.md               # Documentation & usage manual
```

---

## 🚀 Quick Start Guide

### 1. Make Scripts Executable
```bash
chmod +x openvpn.sh install.sh uninstall.sh user-management.sh lib/*.sh
```

### 2. Run Main Launcher
```bash
sudo ./openvpn.sh
```

---

## 🛠️ Usage Breakdown

### Installation (`install.sh`)
To install the OpenVPN server directly:
```bash
sudo ./install.sh
```
The wizard will guide you through:
1. Public Server IP / Domain
2. Network Interface (auto-detected)
3. Protocol (UDP recommended / TCP for strict networks)
4. Listening Port (default: 1194)
5. OpenVPN IP Subnet CIDR (default: `10.8.0.0/24`)
6. DNS Resolvers (Cloudflare, Google, Quad9, OpenDNS, Custom)
7. Encryption Algorithm (Modern ECC `prime256v1` or RSA 2048/4096)
8. Client Routing (Full Tunnel vs Split Tunnel)

### User Management (`user-management.sh`)
Manage clients interactively or via CLI subcommands:

```bash
# Open interactive user menu
sudo ./user-management.sh

# Direct CLI subcommands:
sudo ./user-management.sh add       # Add new user
sudo ./user-management.sh revoke    # Revoke user certificate
sudo ./user-management.sh list      # List registered users
sudo ./user-management.sh export    # Show setup guidelines & QR code
```

When creating a user, the script allows choosing between standard certificate generation or password-only mode, and prompts for the target device (iOS, Mac, MikroTik, Android, Windows, Linux) to generate tailored profiles and print platform setup instructions.

### Uninstallation (`uninstall.sh`)
To completely remove OpenVPN Server:
```bash
sudo ./uninstall.sh
```
Performs safety backups, stops systemd services, removes firewall NAT rules, cleans PKI keys and `/etc/openvpn/` configuration directories, and offers to purge installed packages.

---

## 🔌 MikroTik RouterOS Configuration Example

When a user is created with target device **MikroTik RouterOS**, files are generated in `/etc/openvpn/client-profiles/<username>_mikrotik/`.

**Quick RouterOS Import CLI Commands:**
```routeros
# Upload ca.crt, client.crt, client.key to MikroTik Files, then execute:
/certificate import file-name=ca.crt passphrase=""
/certificate import file-name=client.crt passphrase=""
/certificate import file-name=client.key passphrase=""

/interface ovpn-client add name="ovpn-client" \
    connect-to="YOUR_SERVER_IP" \
    port=1194 \
    mode=ip \
    user="username" \
    certificate=client.crt_0 \
    auth=sha256 \
    cipher=aes256 \
    add-default-route=yes \
    disabled=no
```

---

## 🔒 Security Best Practices

* PKI keys are built using **Easy-RSA 3** in non-interactive batch mode.
* TLS packets are protected with `tls-crypt` key authentication.
* Default cipher is set to authenticated encryption `AES-256-GCM`.
* Revoked client certificates are immediately added to the Certificate Revocation List (`crl.pem`) and enforced by OpenVPN.
