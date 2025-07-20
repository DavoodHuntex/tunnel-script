#!/bin/bash

# Read foreign IP from stdin
read -r FOREIGN_IP
IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
LOCAL_PORT=443
REMOTE_PORT=443

echo "[+] Starting cleanup of previous tunnel configuration..."

# Flush iptables
echo "[+] Flushing iptables rules..."
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -t raw -F
iptables -t raw -X

echo "[+] Resetting iptables policies..."
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Disable IP forwarding
echo "[+] Disabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=0
sed -i '/^net\.ipv4\.ip_forward=1/d' /etc/sysctl.conf
sysctl -p >/dev/null 2>&1

# Remove previous systemd service and tunnel script
echo "[+] Removing old systemd service and tunnel script if exist..."
systemctl stop tunnel443.service 2>/dev/null
systemctl disable tunnel443.service 2>/dev/null
rm -f /etc/systemd/system/tunnel443.service
rm -f /usr/local/bin/tunnel443.sh
systemctl daemon-reload
systemctl reset-failed

echo "[âœ“] Cleanup complete. Applying new tunnel settings..."
sleep 3

# Enable IP forwarding
echo "[+] Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
grep -q '^net\.ipv4\.ip_forward=1' /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1

# Set up iptables rules
echo "[+] Setting up iptables NAT and forwarding rules..."
iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
iptables -t nat -A PREROUTING -p tcp --dport $LOCAL_PORT -j DNAT --to-destination $FOREIGN_IP:$REMOTE_PORT
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -p tcp -d "$FOREIGN_IP" --dport $REMOTE_PORT -j ACCEPT

# Save iptables
echo "[+] Installing and saving iptables-persistent..."
apt-get update -y >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1
iptables-save > /etc/iptables/rules.v4

# Create tunnel execution script
echo "[+] Creating tunnel execution script..."
cat > /usr/local/bin/tunnel443.sh << EOL
#!/bin/bash
iptables -t nat -F PREROUTING
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
iptables -t nat -A PREROUTING -p tcp --dport $LOCAL_PORT -j DNAT --to-destination $FOREIGN_IP:$REMOTE_PORT
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -p tcp -d "$FOREIGN_IP" --dport $REMOTE_PORT -j ACCEPT
EOL

chmod +x /usr/local/bin/tunnel443.sh

# Create systemd service
echo "[+] Creating systemd service..."
cat > /etc/systemd/system/tunnel443.service << EOL
[Unit]
Description=TCP Tunnel to $FOREIGN_IP:443
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tunnel443.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOL

# Enable and start systemd service
echo "[+] Enabling and starting systemd service..."
systemctl daemon-reload
systemctl enable --now tunnel443.service

# Enable network wait services
echo "[+] Enabling network wait-online services..."
systemctl enable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl start systemd-networkd-wait-online.service 2>/dev/null || true
systemctl enable NetworkManager-wait-online.service 2>/dev/null || true
systemctl start NetworkManager-wait-online.service 2>/dev/null || true

echo "[âœ“] Tunnel to $FOREIGN_IP:443 via $IFACE is now active and persistent."
