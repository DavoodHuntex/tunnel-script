#!/bin/bash

# 🛡️ اسکریپت یک‌تکه برای راه‌اندازی تانل TCP به IP خارجی فقط روی پورت 443

# ----------------------------
# 🧩 دریافت آی‌پی از stdin
# ----------------------------
read -r FOREIGN_IP
if [[ -z "$FOREIGN_IP" ]]; then
  echo "❌ لطفاً IP سرور خارجی را وارد کنید (مثلاً: echo '1.2.3.4' | bash ...)"
  exit 1
fi

# ----------------------------
# 🧠 ساخت فایل اصلی tunnel.sh
# ----------------------------
cat > /usr/local/bin/tunnel.sh << EOF
#!/bin/bash
set -e

MAIN_IFACE=\$(ip route | grep default | awk '{print \$5}' | head -n1)
[ -z "\$MAIN_IFACE" ] && { echo "❌ اینترفیس پیش‌فرض یافت نشد"; exit 1; }

FOREIGN_IP="$FOREIGN_IP"
LOCAL_PORT=443
REMOTE_PORT=443

echo "🔄 فعال‌سازی IP Forwarding..."
sysctl -w net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1

echo "🧹 پاکسازی قوانین..."
iptables -F
iptables -t nat -F
iptables -t filter -F FORWARD

echo "🔧 تنظیم NAT..."
iptables -t nat -A PREROUTING -i \$MAIN_IFACE -p tcp --dport \$LOCAL_PORT -j DNAT --to-destination \$FOREIGN_IP:\$REMOTE_PORT
iptables -t nat -A POSTROUTING -o \$MAIN_IFACE -j MASQUERADE

echo "🔒 تنظیم فایروال..."
iptables -A FORWARD -p tcp -d \$FOREIGN_IP --dport \$REMOTE_PORT -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -p tcp --dport \$REMOTE_PORT ! -d \$FOREIGN_IP -j DROP
iptables -A FORWARD -p udp -j DROP

echo "💾 ذخیره قوانین..."
if [ -f /etc/redhat-release ]; then
  iptables-save > /etc/sysconfig/iptables
else
  apt-get update >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y iptables iptables-persistent >/dev/null 2>&1
  iptables-save > /etc/iptables/rules.v4
fi

echo -e "\\n🎉 تانل فعال شد!"
echo "• فقط دسترسی به \$FOREIGN_IP:\$REMOTE_PORT مجاز است"
echo "• UDP بلاک شده، ICMP باز است"
EOF

# ----------------------------
# 📦 ساخت فایل سرویس systemd
# ----------------------------
cat > /etc/systemd/system/tunnel.service << 'EOF'
[Unit]
Description=Secure Tunnel Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/tunnel.sh
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# ----------------------------
# 🔐 فعال‌سازی سرویس
# ----------------------------
chmod +x /usr/local/bin/tunnel.sh
systemctl daemon-reload
systemctl enable --now tunnel.service
systemctl status tunnel.service --no-pager || true

# ----------------------------
# 🌐 اجرای auto reconnect شبکه
# ----------------------------
systemctl enable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl start systemd-networkd-wait-online.service 2>/dev/null || true
systemctl enable NetworkManager-wait-online.service 2>/dev/null || true
systemctl start NetworkManager-wait-online.service 2>/dev/null || true
