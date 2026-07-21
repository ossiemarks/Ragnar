#!/bin/bash

# optaris_defense Update Script
# This script safely updates optaris_defense while preserving configurations and data
# Author: infinition
# Version: 1.0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

optaris_defense_PATH="/home/optaris-defense/OptarisDefense"

echo -e "${BLUE}optaris_defense Update Script${NC}"
echo -e "${YELLOW}This will update optaris_defense while preserving your data and configurations.${NC}"

# Check if we're in the right directory
if [ ! -d "$optaris_defense_PATH" ]; then
    echo -e "${RED}Error: optaris_defense directory not found at $optaris_defense_PATH${NC}"
    exit 1
fi

if [ ! -d "$optaris_defense_PATH/.git" ]; then
    echo -e "${RED}Error: This is not a git repository. Cannot update.${NC}"
    echo -e "${YELLOW}Please reinstall optaris_defense using the installation script.${NC}"
    exit 1
fi

cd "$optaris_defense_PATH"

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root. Please use 'sudo'.${NC}"
    exit 1
fi

echo -e "\n${BLUE}Step 1: Stopping optaris_defense service...${NC}"
systemctl stop optaris-defense.service

echo -e "${BLUE}Step 1.5: Preparing git repository...${NC}"
# Root runs this script while the checkout belongs to user 'optaris_defense' — newer
# git refuses that mix ("detected dubious ownership") unless the path is
# whitelisted in root's global config. Interrupted runs can also leave stale
# lock files, and previous sudo runs leave root-owned files that break git.
git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$optaris_defense_PATH" \
    || git config --global --add safe.directory "$optaris_defense_PATH"
# Clear ALL stale git locks (index/HEAD/shallow AND ref locks like
# refs/remotes/origin/<branch>.lock, packed-refs.lock, config.lock) so an
# interrupted run never leaves a lock that needs a manual service stop.
find "$optaris_defense_PATH/.git" -name '*.lock' -type f -delete 2>/dev/null || true
chown -R optaris_defense:optaris_defense "$optaris_defense_PATH" 2>/dev/null || true
# Stash and merge commits need an author identity; root rarely has one.
GIT_ID=(-c user.name="OptarisDefense Updater" -c user.email="optaris-defense-updater@localhost" -c pull.rebase=false)

echo -e "${BLUE}Step 2: Backing up local changes...${NC}"
if git diff --quiet && git diff --staged --quiet; then
    echo -e "${GREEN}No local changes to backup.${NC}"
else
    echo -e "${YELLOW}Local changes detected. Creating backup...${NC}"
    git "${GIT_ID[@]}" stash push -m "Auto-backup before update $(date)"
    echo -e "${GREEN}Local changes backed up.${NC}"
fi

echo -e "${BLUE}Step 2.5: Preserving local runtime data...${NC}"
BACKUP_DIR=".local_backup"
mkdir -p "$BACKUP_DIR"
PRESERVE_FILES=("data/optaris_defense.db" "data/livestatus.csv" "data/netkb.csv" "data/pwnagotchi_status.json")
for file in "${PRESERVE_FILES[@]}"; do
    if [ -f "$file" ]; then
        cp -p "$file" "$BACKUP_DIR/$(basename $file)"
        echo -e "  ${GREEN}✓${NC} Backed up: $file"
    fi
done

echo -e "${BLUE}Step 3: Fetching latest updates...${NC}"
git fetch origin

echo -e "${BLUE}Step 4: Updating to latest version...${NC}"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
if [ "$CURRENT_BRANCH" = "HEAD" ]; then
    # Detached checkout (e.g. a past checkout of a tag) - go back to main.
    echo -e "${YELLOW}Detached checkout detected - switching back to main.${NC}"
    git checkout main 2>/dev/null || git checkout -B main origin/main
    CURRENT_BRANCH="main"
fi
if git "${GIT_ID[@]}" pull origin "$CURRENT_BRANCH"; then
    echo -e "${GREEN}Update completed successfully!${NC}"
else
    # Deterministic fallback: local changes are already in the stash and the
    # runtime data is copied aside below, so matching origin exactly is safe
    # and guarantees the update lands even on conflicted/diverged checkouts.
    echo -e "${YELLOW}git pull failed - forcing checkout to match origin/$CURRENT_BRANCH (local changes stay in the stash)...${NC}"
    if git fetch origin "$CURRENT_BRANCH" && git reset --hard "origin/$CURRENT_BRANCH"; then
        echo -e "${GREEN}Update completed via forced sync.${NC}"
    else
        echo -e "${RED}Update failed. Attempting to restore backup...${NC}"
        git "${GIT_ID[@]}" stash pop 2>/dev/null || true
        echo -e "${YELLOW}Backup restored. Please check for conflicts manually.${NC}"
        systemctl start optaris-defense.service
        exit 1
    fi
fi

echo -e "${BLUE}Step 5: Updating Python dependencies...${NC}"
# Fast path: one batch upgrade. If pip cannot satisfy the full set (e.g.
# one bad/unsatisfiable pin) it installs NOTHING, silently leaving every
# dependency un-upgraded. Fall back to installing each requirement on its
# own so a single bad package can not block all the others.
if ! pip3 install --break-system-packages --upgrade -r requirements.txt; then
    echo -e "${YELLOW}Batch dependency install failed - retrying package-by-package so one bad pin can not block the rest...${NC}"
    while IFS= read -r req || [ -n "$req" ]; do
        req="${req%%#*}"                 # strip inline comments
        req="$(echo "$req" | xargs)"     # trim whitespace
        [ -z "$req" ] && continue
        pip3 install --break-system-packages --upgrade "$req" \
            || echo -e "  ${YELLOW}!${NC} Failed to install: $req (continuing)"
    done < requirements.txt
fi

echo -e "${BLUE}Step 5.5: Restoring local runtime data...${NC}"
for file in "${PRESERVE_FILES[@]}"; do
    backup_file="$BACKUP_DIR/$(basename $file)"
    if [ -f "$backup_file" ]; then
        mkdir -p "$(dirname $file)"
        cp -p "$backup_file" "$file"
        echo -e "  ${GREEN}✓${NC} Restored: $file"
    fi
done
rm -rf "$BACKUP_DIR"
echo -e "${GREEN}Local runtime data restored.${NC}"

echo -e "${BLUE}Step 5.6: Initializing data files from templates...${NC}"
bash "$optaris_defense_PATH/init_data_files.sh"

echo -e "${BLUE}Step 6: Setting correct permissions...${NC}"
chown -R optaris_defense:optaris_defense "$optaris_defense_PATH"
chmod +x "$optaris_defense_PATH"/*.sh 2>/dev/null || true

# Ensure specific critical scripts are executable
chmod +x "$optaris_defense_PATH/kill_port_8000.sh" 2>/dev/null || true
chmod +x "$optaris_defense_PATH/update_optaris_defense.sh" 2>/dev/null || true
chmod +x "$optaris_defense_PATH/scripts/"*.sh 2>/dev/null || true

# RuSense sensing unit: upgrade the data-dir ExecStartPre to the root-run
# ('+') self-heal variant that also re-asserts ownership. Without it, files
# left root-owned by sudo runs make CSI recording fail ("internal_error" on
# recording/start) and block adaptive-model saves, since the sensing server
# runs as user optaris_defense. Idempotent: only rewrites the old plain-mkdir line;
# install_sensing.sh writes the new form on fresh installs.
SENSING_UNIT="/etc/systemd/system/optaris-defense-sensing.service"
if [ -f "$SENSING_UNIT" ] && grep -q '^ExecStartPre=/bin/mkdir' "$SENSING_UNIT"; then
    sed -i "s|^ExecStartPre=/bin/mkdir .*|ExecStartPre=+/bin/sh -c 'mkdir -p $optaris_defense_PATH/data/recordings $optaris_defense_PATH/data/models \&\& chown -R optaris_defense:optaris_defense $optaris_defense_PATH/data/recordings $optaris_defense_PATH/data/models; chown -f optaris_defense:optaris_defense $optaris_defense_PATH/data/adaptive_model.json; true'|" "$SENSING_UNIT"
    systemctl daemon-reload
    systemctl try-restart optaris-defense-sensing.service 2>/dev/null || true
    echo -e "${GREEN}Patched optaris-defense-sensing.service with ownership self-heal.${NC}"
fi

# Lift the multi-node fusion guard from the old 200 ms to 350 ms — field logs
# showed real-world timestamp spread reaching ~330 ms, so 200 ms rejected fusion
# cycles ("Timestamp spread exceeds guard interval"). Only rewrites the exact old
# default, so a hand-tuned value is left alone; idempotent.
if [ -f "$SENSING_UNIT" ] && grep -q '^Environment=WDP_GUARD_INTERVAL_US=200000' "$SENSING_UNIT"; then
    sed -i 's|^Environment=WDP_GUARD_INTERVAL_US=200000|Environment=WDP_GUARD_INTERVAL_US=350000|' "$SENSING_UNIT"
    systemctl daemon-reload
    systemctl try-restart optaris-defense-sensing.service 2>/dev/null || true
    echo -e "${GREEN}Raised sensing fusion guard to 350 ms (was 200 ms).${NC}"
fi

echo -e "${BLUE}Step 6.6: Ensuring hardware watchdog (auto-reboot on hard hang)...${NC}"
# Unattended / inline devices should reboot fast if the Pi wedges rather than
# black-holing the link. Enable the BCM watchdog and have systemd pet it.
# Idempotent; the config.txt bit applies on the next reboot.
BOOT_CFG=""
for c in /boot/firmware/config.txt /boot/config.txt; do
    [ -f "$c" ] && { BOOT_CFG="$c"; break; }
done
if [ -n "$BOOT_CFG" ] && ! grep -q '^dtparam=watchdog=on' "$BOOT_CFG"; then
    echo 'dtparam=watchdog=on' >> "$BOOT_CFG"
    echo -e "  ${GREEN}✓${NC} Enabled dtparam=watchdog=on in $BOOT_CFG (reboot to apply)"
fi
if [ -f /etc/systemd/system.conf ]; then
    sed -i '/^#\?RuntimeWatchdogSec=/d;/^#\?RebootWatchdogSec=/d' /etc/systemd/system.conf
    printf 'RuntimeWatchdogSec=15\nRebootWatchdogSec=2min\n' >> /etc/systemd/system.conf
    systemctl daemon-reexec 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} systemd watchdog set (RuntimeWatchdogSec=15)"
fi

echo -e "${BLUE}Step 6.7: Refreshing kiosk wrapper (if installed)...${NC}"
# Existing kiosk installs keep a COPY of the wrapper at /usr/local/bin; the
# active copy only updates when kiosk is re-installed. Refresh it here so the
# Pi Zero2W/4/5 hardening reaches boxes that just `git pull` + update.
KIOSK_WRAPPER_SRC="$optaris_defense_PATH/scripts/optaris_defense_kiosk_run.sh"
if [ -f /usr/local/bin/optaris-defense-kiosk-run ] && [ -f "$KIOSK_WRAPPER_SRC" ]; then
    install -m 0755 "$KIOSK_WRAPPER_SRC" /usr/local/bin/optaris-defense-kiosk-run
    echo -e "  ${GREEN}✓${NC} Kiosk wrapper refreshed from repo"
    # Seed the on-screen keyboard so touchscreen typing works on existing kiosk
    # installs too (not just fresh installs). Best-effort, guarded, idempotent:
    # squeekboard for the Wayland/autostart path, matchbox-keyboard for the X
    # service path. The wrapper only launches it when a touchscreen is detected.
    if [ -f /etc/systemd/system/optaris-defense-kiosk.service ]; then
        OSK_PKG="matchbox-keyboard"; command -v matchbox-keyboard >/dev/null 2>&1 && OSK_PKG=""
    else
        OSK_PKG="squeekboard"; command -v squeekboard >/dev/null 2>&1 && OSK_PKG=""
    fi
    if [ -n "$OSK_PKG" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$OSK_PKG" >/dev/null 2>&1 \
            && echo -e "  ${GREEN}✓${NC} On-screen keyboard installed ($OSK_PKG)" \
            || echo -e "  ${YELLOW}⚠${NC} Could not install on-screen keyboard ($OSK_PKG)"
    fi
    # Cap the kiosk restart loop on existing service-mode installs (drop-in, so
    # we don't rewrite the generated unit). Idempotent.
    if [ -f /etc/systemd/system/optaris-defense-kiosk.service ]; then
        install -d -m 0755 /etc/systemd/system/optaris-defense-kiosk.service.d
        cat > /etc/systemd/system/optaris-defense-kiosk.service.d/10-restart-limit.conf <<'DROPIN'
[Unit]
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
RestartSec=10
DROPIN
        systemctl daemon-reload 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} Kiosk restart-loop cap applied (drop-in)"
    fi
fi

echo -e "${BLUE}Step 6.5: Validating actions.json configuration...${NC}"
python3 << 'PYTHON_EOF'
import json
import os

actions_file = "/home/optaris-defense/OptarisDefense/config/actions.json"

try:
    with open(actions_file, 'r') as f:
        actions = json.load(f)
    
    has_scanning = any(action.get('b_module') == 'scanning' for action in actions)
    
    if not has_scanning:
        print("WARNING: scanning module missing, adding it...")
        scanning_action = {
            "b_module": "scanning",
            "b_class": "NetworkScanner",
            "b_port": None,
            "b_status": "network_scanner",
            "b_parent": None
        }
        actions.insert(0, scanning_action)
        
        with open(actions_file, 'w') as f:
            json.dump(actions, f, indent=4)
        print("SUCCESS: Added scanning module to actions.json")
    else:
        print("SUCCESS: scanning module validated")
        
except Exception as e:
    print(f"ERROR validating actions.json: {e}")
PYTHON_EOF

echo -e "${BLUE}Step 6.7: Checking Pwnagotchi migration...${NC}"
MIGRATE_SCRIPT="$optaris_defense_PATH/scripts/migrate_pwnagotchi.sh"
if [[ -d "/opt/pwnagotchi" ]] && [[ -f "$MIGRATE_SCRIPT" ]]; then
    chmod +x "$MIGRATE_SCRIPT"
    if bash "$MIGRATE_SCRIPT"; then
        echo -e "${GREEN}Pwnagotchi migration check completed.${NC}"
    else
        echo -e "${YELLOW}Pwnagotchi migration had issues. Check /var/log/optaris_defense/ for details.${NC}"
    fi

    # Ensure boot-time migration service is installed
    if [[ ! -f "/etc/systemd/system/optaris-defense-pwn-migrate.service" ]]; then
        cat >"/etc/systemd/system/optaris-defense-pwn-migrate.service" <<SVCEOF
[Unit]
Description=OptarisDefense Pwnagotchi Migration Check
After=local-fs.target network-online.target
Before=pwnagotchi.service optaris-defense.service
ConditionPathExists=/opt/pwnagotchi

[Service]
Type=oneshot
ExecStart=${MIGRATE_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
        chmod 644 "/etc/systemd/system/optaris-defense-pwn-migrate.service"
        systemctl daemon-reload
        systemctl enable optaris-defense-pwn-migrate >/dev/null 2>&1 || true
        echo -e "${GREEN}Boot-time migration service installed.${NC}"
    fi
else
    echo -e "${GREEN}No Pwnagotchi installation found or migration script missing. Skipping.${NC}"
fi

echo -e "${BLUE}Step 6.8: Provisioning radios + network tools (background)...${NC}"
# rfkill unblock, network diagnostic tools, and lldpd switch decoding now
# live in one shared script so the in-app Update button provisions the same
# things as this CLI updater (see webapp_modern.py _execute_git_update).
# Run it in the background so slow apt installs never hold up the optaris_defense
# service restart below -- the tools are not needed for optaris_defense to start.
if [ -f "$optaris_defense_PATH/scripts/provision_network_tools.sh" ]; then
    mkdir -p "$optaris_defense_PATH/data/logs"
    nohup bash "$optaris_defense_PATH/scripts/provision_network_tools.sh" \
        > "$optaris_defense_PATH/data/logs/provision_network_tools.log" 2>&1 &
    echo -e "  ${GREEN}✓${NC} Provisioning started in background (log: data/logs/provision_network_tools.log)"
else
    echo -e "${YELLOW}provision_network_tools.sh missing - skipping tool provisioning.${NC}"
fi

echo -e "${BLUE}Step 7: Starting optaris_defense service...${NC}"
systemctl start optaris-defense.service

# Check if service started successfully
sleep 3
if systemctl is-active --quiet optaris-defense.service; then
    echo -e "${GREEN}optaris_defense service started successfully!${NC}"
else
    echo -e "${RED}Warning: optaris_defense service failed to start. Check logs with:${NC}"
    echo -e "${YELLOW}sudo journalctl -u optaris-defense.service -f${NC}"
fi

echo -e "\n${GREEN}Update completed!${NC}"
echo -e "${BLUE}To check if your local changes were backed up:${NC}"
echo -e "  git stash list"
echo -e "${BLUE}To restore your local changes if needed:${NC}"
echo -e "  git stash pop"
echo -e "${BLUE}To check service status:${NC}"
echo -e "  sudo systemctl status optaris-defense.service"
