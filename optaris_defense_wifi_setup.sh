#!/bin/bash
# optaris_defense_wifi_setup.sh
# System setup script for optaris_defense Wi-Fi management
# This script installs and configures the necessary packages for Wi-Fi management
# Author: GitHub Copilot Assistant

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
LOG_FILE="/var/log/optaris-defense-wifi-setup.log"

log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log "INFO" "$1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    log "SUCCESS" "$1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log "WARNING" "$1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log "ERROR" "$1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Update package list
update_packages() {
    print_status "Updating package list..."
    apt-get update || {
        print_error "Failed to update package list"
        exit 1
    }
    print_success "Package list updated"
}

# Install required packages
install_packages() {
    print_status "Installing required packages..."
    
    local packages=(
        "hostapd"
        "dnsmasq"
        "iptables-persistent"
        "network-manager"
        "wireless-tools"
        "wpasupplicant"
        "rfkill"
    )
    
    for package in "${packages[@]}"; do
        print_status "Installing $package..."
        if apt-get install -y "$package"; then
            print_success "$package installed successfully"
        else
            print_error "Failed to install $package"
            exit 1
        fi
    done
}

# Configure services
configure_services() {
    print_status "Configuring services..."
    
    # Stop and disable hostapd and dnsmasq (we'll start them manually)
    systemctl stop hostapd || true
    systemctl stop dnsmasq || true
    systemctl disable hostapd || true
    systemctl disable dnsmasq || true
    
    # Enable and start NetworkManager
    systemctl enable NetworkManager
    systemctl start NetworkManager
    
    # Unmask hostapd (in case it was masked)
    systemctl unmask hostapd || true
    
    print_success "Services configured"
}

# Configure network interface
configure_interface() {
    print_status "Configuring network interface..."
    
    # Create configuration directory for optaris_defense
    mkdir -p /etc/optaris_defense/wifi
    
    # Create a backup of NetworkManager configuration
    if [[ -f /etc/NetworkManager/NetworkManager.conf ]]; then
        cp /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/NetworkManager.conf.backup
    fi
    
    # Configure NetworkManager to manage wifi interfaces
    cat > /etc/NetworkManager/NetworkManager.conf << EOF
[main]
plugins=ifupdown,keyfile
dhcp=dhclient

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=no
EOF

    print_success "Network interface configured"
}

# Set up IP forwarding and NAT (for AP mode)
setup_forwarding() {
    print_status "Setting up IP forwarding and NAT..."
    
    # Enable IP forwarding
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    
    # Create iptables rules for NAT
    cat > /etc/optaris_defense/wifi/iptables-rules.sh << 'EOF'
#!/bin/bash
# iptables rules for optaris_defense Wi-Fi AP mode

# Clear existing rules
iptables -t nat -F
iptables -F

# Set up NAT
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT

# Allow traffic on loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow AP traffic
iptables -A INPUT -i wlan0 -j ACCEPT

# Save rules
iptables-save > /etc/iptables/rules.v4
EOF
    
    chmod +x /etc/optaris_defense/wifi/iptables-rules.sh
    
    print_success "IP forwarding and NAT configured"
}

# Create systemd service for optaris_defense Wi-Fi management
create_systemd_service() {
    print_status "Creating systemd service..."
    
    cat > /etc/systemd/system/optaris-defense-wifi.service << EOF
[Unit]
Description=optaris_defense Wi-Fi Management Service
After=network.target
Wants=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/optaris-defense-wifi-daemon
ExecStop=/usr/local/bin/optaris-defense-wifi-stop
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    # Create daemon scripts
    cat > /usr/local/bin/optaris-defense-wifi-daemon << 'EOF'
#!/bin/bash
# optaris_defense Wi-Fi daemon starter
cd /opt/optaris_defense
python3 -c "
from wifi_manager import WiFiManager
from init_shared import shared_data
import signal
import sys

def signal_handler(sig, frame):
    print('Stopping Wi-Fi manager...')
    wifi_manager.stop()
    sys.exit(0)

wifi_manager = WiFiManager(shared_data)
signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

wifi_manager.start()
while True:
    try:
        time.sleep(1)
    except KeyboardInterrupt:
        wifi_manager.stop()
        break
" &
echo $! > /var/run/optaris-defense-wifi.pid
EOF

    cat > /usr/local/bin/optaris-defense-wifi-stop << 'EOF'
#!/bin/bash
# Stop optaris_defense Wi-Fi daemon
if [ -f /var/run/optaris-defense-wifi.pid ]; then
    PID=$(cat /var/run/optaris-defense-wifi.pid)
    if kill -0 $PID 2>/dev/null; then
        kill $PID
        rm -f /var/run/optaris-defense-wifi.pid
    fi
fi
EOF

    chmod +x /usr/local/bin/optaris-defense-wifi-daemon
    chmod +x /usr/local/bin/optaris-defense-wifi-stop
    
    systemctl daemon-reload
    
    print_success "Systemd service created"
}

# Create utility scripts
create_utility_scripts() {
    print_status "Creating utility scripts..."
    
    # Wi-Fi connection helper
    cat > /usr/local/bin/optaris-defense-wifi-connect << 'EOF'
#!/bin/bash
# optaris_defense Wi-Fi connection helper
# Usage: optaris-defense-wifi-connect <SSID> [password]

if [ $# -lt 1 ]; then
    echo "Usage: $0 <SSID> [password]"
    exit 1
fi

SSID="$1"
PASSWORD="$2"

if [ -n "$PASSWORD" ]; then
    nmcli dev wifi connect "$SSID" password "$PASSWORD"
else
    nmcli dev wifi connect "$SSID"
fi
EOF

    # Wi-Fi AP starter
    cat > /usr/local/bin/optaris-defense-wifi-ap << 'EOF'
#!/bin/bash
# optaris_defense Wi-Fi AP mode helper
# Usage: optaris-defense-wifi-ap [start|stop]

ACTION="${1:-start}"

case "$ACTION" in
    start)
        echo "Starting optaris_defense Wi-Fi AP mode..."
        # This will be handled by the Python Wi-Fi manager
        systemctl start optaris-defense-wifi
        ;;
    stop)
        echo "Stopping optaris_defense Wi-Fi AP mode..."
        systemctl stop optaris-defense-wifi
        ;;
    *)
        echo "Usage: $0 [start|stop]"
        exit 1
        ;;
esac
EOF

    # Wi-Fi status checker
    cat > /usr/local/bin/optaris-defense-wifi-status << 'EOF'
#!/bin/bash
# optaris_defense Wi-Fi status checker

echo "=== optaris_defense Wi-Fi Status ==="
echo

# Check Wi-Fi interface
echo "Wi-Fi Interface Status:"
ip addr show wlan0 2>/dev/null || echo "wlan0 not found"
echo

# Check active connections
echo "Active Connections:"
nmcli con show --active
echo

# Check available networks
echo "Available Networks:"
nmcli dev wifi list
echo

# Check AP mode processes
echo "AP Mode Processes:"
pgrep -l hostapd || echo "hostapd not running"
pgrep -l dnsmasq || echo "dnsmasq not running"
echo

# Check optaris_defense Wi-Fi service
echo "optaris_defense Wi-Fi Service:"
systemctl status optaris-defense-wifi --no-pager -l
EOF

    chmod +x /usr/local/bin/optaris-defense-wifi-connect
    chmod +x /usr/local/bin/optaris-defense-wifi-ap
    chmod +x /usr/local/bin/optaris-defense-wifi-status
    
    print_success "Utility scripts created"
}

# Set up permissions
setup_permissions() {
    print_status "Setting up permissions..."
    
    # Create optaris_defense group if it doesn't exist
    getent group optaris_defense >/dev/null || groupadd optaris_defense
    
    # Add optaris_defense user to necessary groups
    if id "optaris_defense" &>/dev/null; then
        usermod -a -G netdev,sudo optaris_defense
    fi
    
    # Set permissions on configuration directory
    chown -R root:optaris_defense /etc/optaris_defense
    chmod -R 750 /etc/optaris_defense
    
    print_success "Permissions configured"
}

# Create uninstall script
create_uninstall_script() {
    print_status "Creating uninstall script..."
    
    cat > /usr/local/bin/optaris-defense-wifi-uninstall << 'EOF'
#!/bin/bash
# optaris_defense Wi-Fi uninstall script

echo "Uninstalling optaris_defense Wi-Fi management..."

# Stop and disable service
systemctl stop optaris-defense-wifi 2>/dev/null || true
systemctl disable optaris-defense-wifi 2>/dev/null || true

# Remove systemd service
rm -f /etc/systemd/system/optaris-defense-wifi.service
systemctl daemon-reload

# Remove scripts
rm -f /usr/local/bin/optaris-defense-wifi-daemon
rm -f /usr/local/bin/optaris-defense-wifi-stop
rm -f /usr/local/bin/optaris-defense-wifi-connect
rm -f /usr/local/bin/optaris-defense-wifi-ap
rm -f /usr/local/bin/optaris-defense-wifi-status
rm -f /usr/local/bin/optaris-defense-wifi-uninstall

# Remove configuration directory
rm -rf /etc/optaris_defense/wifi

# Restore NetworkManager configuration if backup exists
if [ -f /etc/NetworkManager/NetworkManager.conf.backup ]; then
    mv /etc/NetworkManager/NetworkManager.conf.backup /etc/NetworkManager/NetworkManager.conf
    systemctl restart NetworkManager
fi

echo "optaris_defense Wi-Fi management uninstalled"
EOF

    chmod +x /usr/local/bin/optaris-defense-wifi-uninstall
    
    print_success "Uninstall script created"
}

# Main installation function
main() {
    print_status "Starting optaris_defense Wi-Fi management setup..."
    
    check_root
    update_packages
    install_packages
    configure_services
    configure_interface
    setup_forwarding
    create_systemd_service
    create_utility_scripts
    setup_permissions
    create_uninstall_script
    
    print_success "optaris_defense Wi-Fi management setup completed!"
    print_status "Available commands:"
    echo "  - optaris-defense-wifi-status    : Check Wi-Fi status"
    echo "  - optaris-defense-wifi-connect   : Connect to Wi-Fi network"
    echo "  - optaris-defense-wifi-ap        : Start/stop AP mode"
    echo "  - optaris-defense-wifi-uninstall : Uninstall Wi-Fi management"
    echo ""
    print_status "To enable the Wi-Fi service:"
    echo "  sudo systemctl enable optaris-defense-wifi"
    echo "  sudo systemctl start optaris-defense-wifi"
    echo ""
    print_warning "Please reboot the system to ensure all changes take effect."
}

# Run main function
main "$@"
