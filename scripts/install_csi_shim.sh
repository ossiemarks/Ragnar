#!/usr/bin/env bash
# Install csi_shim systemd units on the Pi. Idempotent.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)/config/systemd"
for u in optaris-defense-csi-nexmon optaris-defense-csi-intel; do
  sudo install -m0644 "$SRC/$u.service" "/etc/systemd/system/$u.service"
done
sudo systemctl daemon-reload
echo "Installed. Enable per source, e.g.: sudo systemctl enable --now optaris-defense-csi-nexmon"
