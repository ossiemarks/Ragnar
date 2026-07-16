# Ragnar + RuSense on optaris-edge — Deployment Design

**Date:** 2026-07-16
**Target:** `optaris-edge` — Raspberry Pi 5, Ubuntu 24.04.4 LTS (arm64), 7.8 GB RAM, 45 GB free.
Reachable at `optaris-edge.local` / `192.168.8.149` (LAN `192.168.8.0/24`, gateway = GL-MT3000).
**Goal:** Replace the existing OptarisSense sensing stack with Ragnar + its vendored RuSense
engine, and feed it CSI from all four available sources.

> Credentials are **not** stored in this doc. Pi and router logins live in Secrets Manager
> (`optaris/pi/*`, `optaris/router/gl-mt3000-admin`, `optaris/wifi/gl-mt3000-62`). Pi SSH is
> key-based (`~/.ssh/id_ed25519`, passwordless). Router SSH is password (`root@192.168.8.1`).

## Measured current state

- **Ragnar: not installed** (no `~/Ragnar`, no `ragnar.service`).
- **OptarisSense running** — `sensing-server.service`, binary `/usr/local/bin/sensing-server`,
  WorkingDirectory `/opt/optaris-sense`, `CLOUD_ENABLE=true` (cloud currently **offline**).
  Ports: UDP `:5005` (CSI ingest) + `:50051`, HTTP dashboard `:8080`, WebSocket `:8765`.
  It is a RuView derivative — answers the standard RuView `/api/v1/status`, `/api/v1/nodes`,
  `/health`.
- **2× ESP32 nodes live** — `/api/v1/nodes` shows `node_id 2` and `node_id 5`, `active`,
  last-seen ~10 ms, RSSI −35/−37. Plugged into the Pi over USB (power only; they stream CSI
  over WiFi-UDP to `box-IP:5005`). Espressif `303a:1001` on `/dev/ttyACM0`, `/dev/ttyACM2`.
- **Nexmon bridge present** — `nexmon-bridge.service` → `/home/pi/nexmon_csi_start.sh` (root),
  Pi Broadcom radio → `:5005` as node 200 (not currently showing active).
- **Intel AX210 / AX1675 "Killer"** — PCIe `wlp1s0`, currently **DOWN**, no CSI tooling
  (no PicoScenes). This is the "Intel Killer" source.
- **GL-MT3000 router (192.168.8.1)** — OpenWRT SNAPSHOT, MediaTek MT7981 / `mt7915e`/`mt76`.
  **Custom mt76-CSI stack already installed and enabled**: `csi_stats` debugfs node,
  `/etc/init.d/mt76-csi` (boot-enabled `S95`), `/etc/mt76-csi.conf`, `/usr/bin/csi-capture`,
  `/usr/sbin/mt76-csi-daemon` (all in `/overlay/upper`). This is the "custom OpenWRT CSI router".

## Target architecture

Ragnar (web UI `:8000`) + `ragnar-sensing.service` (RuView engine, HTTP `:3000`, WS `:3100`,
UDP CSI ingest `:5005`) on the Pi. All four CSI sources stream to the Pi's `:5005`:

| Source | Location | Transport | CSI toolchain |
|---|---|---|---|
| ESP32 nodes 2 & 5 | USB-powered on Pi | WiFi → UDP `:5005` | native ESP32 CSI (working) |
| Pi Broadcom (node 200) | Pi onboard radio | Nexmon bridge → `:5005` | Nexmon CSI (present) |
| Intel AX210/Killer | Pi PCIe `wlp1s0` | local bridge → `:5005` | **PicoScenes** (to install) |
| GL-MT3000 | router 192.168.8.1 | network bridge → `:5005` | **mt76-CSI** (pre-built) |

### Key design constraints (honest)

- **Heterogeneous CSI widths do not fuse.** ESP32, Nexmon (Broadcom), Intel AX210, and MediaTek
  mt76 emit different subcarrier widths. The RuView engine only runs multistatic **fusion**
  (people-count / pose / position) *within* a same-width node group; mixed-width nodes fall
  back to independent per-node **presence/motion**. The server already runs ESP32 + Nexmon
  side-by-side, so heterogeneous ingest works — but Intel and MediaTek will be independent
  presence/motion nodes, **not** fused with the ESP32 mesh. Best fusion still comes from the
  same-chip ESP32 group.
- **`install_sensing.sh` only auto-disables `ruview-sensing.service`**, not the local
  `sensing-server.service`. The cutover disables that one manually (Phase 0).
- **Reversibility:** Phase 0 snapshots OptarisSense so the whole change rolls back with a
  documented one-command restore.

## Phases

### Phase 0 — Reversible cutover
1. Snapshot to `/home/pi/optaris-sense.backup/`: `sensing-server.service` + `nexmon-bridge.service`
   unit files, `/home/pi/nexmon_csi_start.sh`, and `/opt/optaris-sense` config (incl. cloud
   `site_id`).
2. `systemctl stop --now sensing-server.service` then `systemctl disable sensing-server.service`
   to free `:5005`/`:50051`/`:8080`/`:8765`.
3. **Verify:** `:5005` no longer bound by the old server; snapshot restore path documented.
   **Rollback:** `systemctl enable --now sensing-server.service`.

### Phase 1 — Ragnar + vendored RuSense (documented happy path)
1. Clone Ragnar to `/home/pi/Ragnar`; run `install_ragnar.sh` in a **headless/server** profile,
   non-interactively (feed the profile choice; no display hardware present). Result:
   `ragnar.service`, web UI on `:8000`.
2. Run `scripts/install_sensing.sh` → `ragnar-sensing.service` on `:5005/:3000/:3100`
   (native arm64 glibc binary — no container).
3. Keep the Nexmon bridge (node 200) targeting `:5005`; let the 2 ESP32 nodes reconnect
   automatically (they target `box-IP:5005`).
4. **Verify:** RuSense **Nodes** tab shows nodes 2 & 5 with climbing pps; `/api/v1/health` ok;
   Ragnar dashboard reachable at `http://optaris-edge.local:8000`.
   **Milestone:** satisfies "install Ragnar + RuSense + use the ESP32 nodes."

### Phase 2 — Intel AX210 / Killer as a CSI source (novel)
Uses **FeitCSI** (AX200/AX210 CSI tool + patched iwlwifi) — already mid-build on the Pi at
`/home/pi/feitcsi-build`. See the [CSI ingestion design](2026-07-16-csi-ingestion-normalization-design.md)
for the `feitcsi` reader.
1. Finish building **FeitCSI** + its patched `iwlwifi` driver; bring `wlp1s0` up in CSI/monitor
   mode.
2. Add the **`feitcsi` reader** (in `csi_shim`) that decodes FeitCSI output and emits ADR-018
   frames to `:5005` as node 210.
3. **Verify:** frames arrive on `:5005`; node 210 appears in `/api/v1/nodes`; presence/motion
   tracks a person near the Pi. **Caveat:** independent node, not fused with ESP32.
   **Effort:** highest of the three — finish the FeitCSI/iwlwifi build + the new reader.

### Phase 3 — GL-MT3000 mt76-CSI router (novel, but pre-built)
1. Inspect the existing router stack: `/etc/mt76-csi.conf`, `mt76-csi-daemon` output format and
   destination, `csi-capture` usage. Determine whether it already streams (and in what format).
2. Build/point a **bridge** that reformats the mt76-CSI output into ESP32-format UDP frames to
   the Pi `:5005` with a distinct node id (mirror the `nexmon_csi_start.sh` pattern). Prefer a
   thin adapter on the Pi so the router stays as-is; run on the router only if lighter.
3. **Verify:** frames arrive on `:5005`; new node appears; presence/motion tracks motion in the
   router's coverage. **Caveat:** independent node, not fused with ESP32.

## Out of scope / deferred
- Reinstating OptarisSense cloud telemetry under Ragnar (Ragnar's sensing has no cloud spool).
- Multistatic fusion across heterogeneous chips (engine limitation, not deliverable).
- Training adaptive models per room (post-deploy tuning, separate effort).

## Verification summary
Each phase is independently verifiable via `/api/v1/nodes`, `/api/v1/health`, live `:5005` UDP
frame counts, and the Ragnar web UI. Full rollback to OptarisSense available at any point via the
Phase 0 snapshot.
