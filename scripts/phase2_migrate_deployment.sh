#!/usr/bin/env bash
# Phase 2 — live-Pi deployment migration: Ragnar -> OptarisDefense on optaris-edge.
#
# STATUS: DRAFT — written while the Pi was OFFLINE, so it is UNTESTED against live state.
#   Run interactively on the Pi, review each step's output, and keep the backups it makes.
#   The Phase-1 codebase rename (repo) is already merged to main; this migrates the *running box*.
#
# What it does (idempotent where practical, with backups):
#   1. Snapshot current unit files + key paths for rollback.
#   2. Deploy the renamed code (clone the renamed repo) to /home/optaris-defense/OptarisDefense.
#   3. Re-create the systemd units under optaris-defense-* names, disable the old ragnar-* ones.
#   4. Restart the stack; verify web :8000 + ragnar-sensing(:3000) + fan-out(:5005) still work.
#
# NOT touched: OptarisSense (`sensing-server.service`, `/opt/optaris-sense`, :5105/:8080) and the
#   `optaris-edge` hostname — those keep their own names (per the rename scope).
#
# Usage (ON THE PI, once it is back and stable):
#   sudo bash scripts/phase2_migrate_deployment.sh            # migrate
#   sudo bash scripts/phase2_migrate_deployment.sh --rollback # restore from the snapshot
set -euo pipefail

BACKUP=/home/pi/optaris-defense-migration.backup
NEW_HOME=/home/optaris-defense
NEW_DIR="$NEW_HOME/OptarisDefense"
REPO=https://github.com/ossiemarks/optaris-defense.git
BRANCH=main

log(){ echo "[phase2] $*"; }

# Map of old -> new unit names to migrate. Extend once verified against `systemctl list-units`.
declare -A UNIT_MAP=(
  [ragnar.service]=optaris-defense.service
  [ragnar-sensing.service]=optaris-defense-sensing.service
  [ragnar-csi-fanout.service]=optaris-defense-csi-fanout.service
  [ragnar-csi-nexmon.service]=optaris-defense-csi-nexmon.service
  [ragnar-csi-intel.service]=optaris-defense-csi-intel.service
)

if [ "${1:-}" = "--rollback" ]; then
  log "ROLLBACK from $BACKUP"
  [ -d "$BACKUP/systemd" ] || { echo "no backup at $BACKUP"; exit 1; }
  for new in "${UNIT_MAP[@]}"; do sudo systemctl disable --now "$new" 2>/dev/null || true; sudo rm -f "/etc/systemd/system/$new"; done
  sudo cp -a "$BACKUP/systemd/." /etc/systemd/system/
  sudo systemctl daemon-reload
  for old in "${!UNIT_MAP[@]}"; do sudo systemctl enable --now "$old" 2>/dev/null || true; done
  log "rolled back — verify services."
  exit 0
fi

# ── 0. Preconditions ─────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
mkdir -p "$BACKUP/systemd"

# ── 1. Snapshot for rollback ─────────────────────────────────────────────────
log "[1/5] snapshot current units + report"
for old in "${!UNIT_MAP[@]}"; do
  fp=$(systemctl show "$old" -p FragmentPath --value 2>/dev/null || true)
  [ -n "$fp" ] && [ -f "$fp" ] && cp -a "$fp" "$BACKUP/systemd/" || log "  ($old not present — skip)"
done
systemctl list-units --all 'ragnar*' 'optaris-defense*' >"$BACKUP/units.before.txt" 2>/dev/null || true

# ── 2. Deploy renamed code ───────────────────────────────────────────────────
log "[2/5] deploy renamed code -> $NEW_DIR"
id optaris-defense >/dev/null 2>&1 || useradd -r -m -d "$NEW_HOME" -s /usr/sbin/nologin optaris-defense
mkdir -p "$NEW_HOME"; chown -R optaris-defense:optaris-defense "$NEW_HOME"
if [ -d "$NEW_DIR/.git" ]; then
  sudo -u optaris-defense git -C "$NEW_DIR" fetch origin && sudo -u optaris-defense git -C "$NEW_DIR" reset --hard "origin/$BRANCH"
else
  sudo -u optaris-defense git clone --branch "$BRANCH" "$REPO" "$NEW_DIR"
fi

# ── 3. Migrate systemd units (rewrite ExecStart paths/names, install under new names) ────
log "[3/5] install optaris-defense-* units (rewriting ragnar -> optaris-defense in unit text + paths)"
for old in "${!UNIT_MAP[@]}"; do
  new="${UNIT_MAP[$old]}"
  fp="$BACKUP/systemd/$old"
  [ -f "$fp" ] || { log "  ($old had no unit file — skip)"; continue; }
  # rewrite: /home/ragnar -> /home/optaris-defense, ragnar-> optaris-defense in Exec/paths, filenames
  sed -e 's#/home/ragnar#/home/optaris-defense#g' \
      -e 's#\bRagnar\b#OptarisDefense#g' \
      -e 's#headlessRagnar\.py#headless_optaris_defense.py#g' \
      -e 's#\bRagnar\.py#optaris_defense.py#g' \
      -e 's#ragnar-#optaris-defense-#g' \
      -e 's#ragnar#optaris_defense#g' \
      "$fp" > "/etc/systemd/system/$new"
  log "  $old -> $new"
done
systemctl daemon-reload

# ── 4. Cut over: stop+disable old, enable+start new ──────────────────────────
log "[4/5] cutover"
for old in "${!UNIT_MAP[@]}"; do systemctl disable --now "$old" 2>/dev/null || true; done
for new in "${UNIT_MAP[@]}"; do systemctl enable --now "$new" 2>/dev/null || log "  ($new failed to start — check journalctl -u $new)"; done

# ── 5. Verify (do NOT touch OptarisSense :5105/:8080 or fan-out :5005 semantics) ─────────
log "[5/5] verify"
sleep 5
echo "  web :8000  -> $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/ 2>/dev/null)"
echo "  sensing :3000 nodes -> $(curl -s -m4 http://127.0.0.1:3000/api/v1/nodes 2>/dev/null | head -c 120)"
echo "  OptarisSense :8080 (untouched) -> $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ 2>/dev/null)"
echo "  fan-out/OptarisSense ports: $(ss -ulnp 2>/dev/null | grep -oE ':(5005|5105)' | sort -u | tr '\n' ' ')"
systemctl list-units 'optaris-defense*' --no-pager
log "done — if anything is wrong, re-run with --rollback. Old /home/ragnar left in place (remove manually once satisfied)."
