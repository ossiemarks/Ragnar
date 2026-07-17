#!/usr/bin/env bash
# Bring the GL-MT3000 mt76-csi daemon live and pointed at the Pi.
# Usage: PI_IP=192.168.8.149 ROUTER=192.168.8.1 ROUTER_PW=... ./scripts/router_mt76_csi_bringup.sh
set -euo pipefail

ROUTER="${ROUTER:-192.168.8.1}"
PI_IP="${PI_IP:-192.168.8.149}"
PW="${ROUTER_PW:?set ROUTER_PW}"

rsh() { sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$ROUTER" "$@"; }

echo "[1/5] repoint udp.host -> $PI_IP in /etc/mt76-csi.conf"
rsh "sed -i 's/^host *=.*/host    = $PI_IP/' /etc/mt76-csi.conf && grep -A2 '\\[udp\\]' /etc/mt76-csi.conf"

echo "[2/5] ensure CSI-capable vif exists on the configured interface (ra0)"
rsh "iw dev | grep -q ra0 && echo 'ra0 present' || echo 'WARN: ra0 missing -- check [csi] interface in conf'"

echo "[3/5] enable + (re)start mt76-csi"
rsh "/etc/init.d/mt76-csi enable; /etc/init.d/mt76-csi restart; sleep 2; ps w | grep -v grep | grep mt76-csi-daemon || echo 'WARN: daemon not in ps'"

echo "[4/5] confirm debugfs csi_stats is advancing (needs an ACTIVE wifi client generating traffic near the router)"
rsh "PHY=\$(ls -d /sys/kernel/debug/ieee80211/*/mt76 2>/dev/null | grep -m1 phy0 || ls -d /sys/kernel/debug/ieee80211/*/mt76 2>/dev/null | head -1); echo \"using \$PHY/csi_stats\"; cat \"\$PHY/csi_stats\" 2>/dev/null; sleep 3; cat \"\$PHY/csi_stats\" 2>/dev/null"

echo "[5/5] done -- run the Pi-side capture to grab a sample frame:"
echo "  ssh -i ~/.ssh/id_ed25519 pi@\$PI_IP \"timeout 15 python3 - <<'PY'"
echo "import socket"
echo "s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('0.0.0.0',5500))"
echo "s.settimeout(12); d,a=s.recvfrom(65535)"
echo "open('/tmp/csi_sample.bin','wb').write(d)"
echo "print('from',a,'len',len(d),'head',d[:16].hex())"
echo "PY\""
