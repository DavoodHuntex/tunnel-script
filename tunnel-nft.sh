#!/bin/bash

clear

# Green ASCII logo
echo -e "\033[1;32m"
cat << "BANNER"
██╗  ██╗██╗   ██╗███╗  ██╗████████╗███████╗██╗  ██╗
██║  ██║██║   ██║████╗ ██║╚══██╔══╝██╔════╝╚██╗██╔╝
███████║██║   ██║██╔██╗██║   ██║   █████╗   ╚███╔╝ 
██╔══██║██║   ██║██║╚████║   ██║   ██╔══╝   ██╔██╗ 
██║  ██║╚██████╔╝██║ ╚███║   ██║   ███████╗██╔╝ ██╗
╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚══╝   ╚═╝   ╚══════╝╚═╝  ╚═╝
BANNER
echo -e "\033[0m"

# Read foreign IP
read -r FOREIGN_IP || { echo "[❌] Failed to read IP" >&2; exit 1; }

# Detect default interface
IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
[ -z "$IFACE" ] && { echo "[❌] No default network interface found!" >&2; exit 1; }

# Clean legacy iptables
echo -e "\033[1;36m[+] Flushing legacy iptables rules...\033[0m"
iptables -F; iptables -X
iptables -t nat -F; iptables -t nat -X
iptables -t mangle -F; iptables -t mangle -X
iptables -t raw -F; iptables -t raw -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6
systemctl stop tunnel443.service 2>/dev/null
systemctl disable tunnel443.service 2>/dev/null
rm -f /etc/systemd/system/tunnel443.service
rm -f /usr/local/bin/tunnel443.sh

# Clean old nftables files & service
systemctl stop tunnel443-nft.service 2>/dev/null
systemctl disable tunnel443-nft.service 2>/dev/null
rm -f /etc/systemd/system/tunnel443-nft.service
rm -f /usr/local/bin/tunnel443-nft.sh

# Install nftables with spinner
echo -ne "\033[1;36m[+] Installing nftables: \033[0m"
{
  apt-get update -y >/dev/null 2>&1
  apt-get install -y nftables >/dev/null 2>&1
} & PID=$!
spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
i=0
while kill -0 $PID 2>/dev/null; do
  i=$(( (i+1) %8 ))
  printf "\r\033[1;36m[+] Installing nftables: \033[0m${spin:$i:1}"
  sleep 0.1
done
printf "\r\033[1;32m[✓] nftables installed.\033[0m\n"

# Flush old nftables
echo -e "\033[1;36m[+] Flushing old nftables rules...\033[0m"
nft flush ruleset

sleep 2

# Write nftables config
echo -e "\033[1;36m[1] Creating /etc/nftables.conf...\033[0m"
cat > /etc/nftables.conf << EOL
table ip huntex_tunnel {
  chain prerouting {
    type nat hook prerouting priority -100;
    tcp dport 443 dnat to $FOREIGN_IP:443
  }
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "$IFACE" masquerade
  }
  chain forward {
    type filter hook forward priority 0;
    ct state related,established accept
    ip daddr $FOREIGN_IP tcp dport 443 accept
  }
}
EOL

# Enable IP forwarding
echo -e "\033[1;36m[2] Enabling IP forwarding...\033[0m"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sed -i '/^net\.ipv4\.ip_forward=/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1

# Enable nftables service
echo -e "\033[1;36m[3] Enabling nftables service...\033[0m"
systemctl enable nftables >/dev/null 2>&1
systemctl restart nftables

# Create executable script
echo -e "\033[1;36m[4] Creating tunnel script...\033[0m"
cat > /usr/local/bin/tunnel443-nft.sh << EOT
#!/bin/bash
nft -f /etc/nftables.conf
EOT
chmod +x /usr/local/bin/tunnel443-nft.sh

sleep 1
# Create systemd service
echo -e "\033[1;36m[5] Creating systemd service...\033[0m"
cat > /etc/systemd/system/tunnel443-nft.service << EOT
[Unit]
Description=Tunnel to $FOREIGN_IP:443 (via nftables)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tunnel443-nft.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOT

# Reload and start service
systemctl daemon-reload
systemctl enable --now tunnel443-nft.service

sleep 2
echo -e "\033[1;32m[✓] Tunnel to $FOREIGN_IP via nftables is now ACTIVE.\033[0m"
echo -e "\033[1;33m[*] Test: curl -vk https://localhost\033[0m"
