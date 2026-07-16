# CSI Ingestion & Normalization (`csi_shim`) — Design

**Date:** 2026-07-16
**Context:** Refines Phases 2–3 of the
[optaris-edge deployment design](2026-07-16-ragnar-rusense-optaris-edge-design.md). Defines how
CSI from four heterogeneous sources is normalized into the single format the RuView
sensing-server ingests, plus a later BFI path.

## Goal

Every CSI source converges on **one interface — the ADR-018 frame** (`0xC5110001` header + int8
I/Q, UDP `:5005`), so the sensing-server runs unchanged in `--source esp32` and each source
appears as an independent node. A later, parallel BFI instance adds opportunistic capture.

## Target contract: ADR-018 frame

20-byte little-endian header + `n_antennas × n_subcarriers × (I, Q)` int8 pairs, UDP to `:5005`:

| Offset | Type | Field |
|-------:|------|-------|
| 0  | u32 | magic = `0xC5110001` |
| 4  | u8  | node_id |
| 5  | u8  | n_antennas |
| 6  | u16 | n_subcarriers |
| 8  | u32 | channel_freq_mhz |
| 12 | u32 | sequence |
| 16 | i8  | rssi_dbm |
| 17 | i8  | noise_floor_dbm |
| 18 | u8  | ppdu_type (0 = HT/legacy, 1–3 = HE) |
| 19 | u8  | flags (bw40, STBC, LDPC, 802.15.4 sync) |
| 20+ | i8 pairs | I/Q payload |

Reference implementations already on the Pi: `nexmon_bridge.py` (canonical converter) and the Rust
`esp-csi` crate / `wifi-densepose-hardware` (parser). The sensing-server `--source` accepts
`auto, wifi, esp32, simulate, mirror, bfi`.

## Source inventory (measured)

| Source | Native output | node_id | Status |
|---|---|---|---|
| ESP32 ×2 | ADR-018 native → `:5005` | 2, 5 (firmware) | live |
| Pi Broadcom (`wlan0`) | Nexmon, raw AF_PACKET (src 10.10.10.10 → UDP 5500) | 200 | adapter exists |
| GL-MT3000 (`ra0`) | mt76-csi-daemon → UDP `192.168.8.100:5500` (80 MHz) | 176 | installed; **not running**, host is wrong (`.100`, Pi is `.149`) |
| Intel AX210 (`wlp1s0`) | FeitCSI (live/file) | 210 | **not built** (patched iwlwifi mid-compile) |

## Architecture

One shared encoder + thin per-vendor readers. Each reader is a single-purpose, independently
testable unit: input = one vendor's CSI, output = ADR-018 frames to `:5005`.

```
ESP32 ─────native ADR-018──────────────────────▶ :5005 ┐
Pi Broadcom ─Nexmon(raw wlan0)→ nexmon reader ──▶ :5005 ├─▶ sensing-server(esp32) ─▶ Ragnar :8000
GL-MT3000 ──mt76 UDP:5500 → mt76 reader ────────▶ :5005 ┤
Intel AX210 ─FeitCSI → feitcsi reader ──────────▶ :5005 ┘
(later) monitor radio ─BFI pcap→ sensing-server#2 (--source bfi) ─▶ aggregate
```

### Components

- **`adr018`** — the single source of truth for the wire format. Encodes the header + int8 I/Q.
  Owns the shared **fixed-divisor int→int8 scaler** (calibrated from a sampled amplitude
  distribution; preserves frame-to-frame variation, clips outliers — never per-frame AGC) and the
  **per-chip null/pilot-subcarrier zeroing** helper.
- **`nexmon` reader** — refactor `nexmon_bridge.py` onto `adr018`. Raw AF_PACKET sniff on `wlan0`,
  node 200. Behaviour preserved (DIV, bcm43455c0 null-SC map).
- **`mt76` reader** — UDP listener bound `0.0.0.0:5500`, source-IP-filtered to the router. Decodes
  mt7915 CSI (256-bin @ 80 MHz), scales to int8, applies the mt7915 null/pilot map, sets
  HE/VHT80 ppdu + flags, node 176.
- **`feitcsi` reader** — reads FeitCSI live/file output for the AX210, decodes, scales, applies the
  Intel null/pilot map, sets HE ppdu, node 210.
- **ESP32** — native ADR-018; no shim.

### Port/transport separation

No `:5500` clash: Nexmon uses a raw AF_PACKET sniff (no UDP bind); the `mt76` reader owns the
`:5500` UDP bind; FeitCSI is file/live (no port). Each reader runs as its own systemd unit
(`ragnar-csi-nexmon.service`, `ragnar-csi-mt76.service`, `ragnar-csi-intel.service`) sharing the
`csi_shim` library.

### node-id scheme

ESP32 firmware ids (2, 5) · Nexmon 200 · mt76 176 · Intel 210. Distinct ranges so a source is
identifiable in `/api/v1/nodes`. The router's `zones` (Living Room/Bedroom/Kitchen) map to the
single mt76 node initially; per-zone node split is out of scope for this pass.

## Fusion limitation (inherent)

The four widths (ESP32, Broadcom 64-bin, mt76 256-bin@80 MHz, Intel HE) do not cross-fuse: the
engine runs multistatic fusion only within a same-width group. All sources still contribute
independent presence/motion. Forcing a common width by downsampling is lossy and out of scope;
nodes stay independent by default.

## Error handling

- Readers respawn on source loss (systemd `Restart=on-failure`), skip malformed frames, and clamp
  out-of-range I/Q before int8 encoding.
- `mt76` reader filters `:5500` by router source IP to reject stray traffic.
- A failed/absent FeitCSI build means only the Intel node is missing; the server and all other
  nodes are unaffected (graceful degradation).
- The server marks a node offline when its frames stop (existing behaviour) — no shim-side timeout
  needed.

## Testing

- **Unit:** feed the `adr018` encoder a known subcarrier array → assert exact header + int8 bytes.
  Feed each reader a captured real vendor frame → assert the decoded/re-encoded ADR-018 output.
- **Integration:** replay a recorded vendor UDP capture at `:5500` → confirm the node appears in
  `/api/v1/nodes` with climbing pps.
- **E2E:** move in front of each radio → that node's presence/motion reacts in the Ragnar UI.

## Packaging & location

`csi_shim/` Python package in the Ragnar repo (matches `nexmon_bridge.py`; the Rust `esp-csi`
crate remains the reference parser), deployed to the Pi with Ragnar. Per-source systemd units,
one shared library.

## Prerequisites / dependencies (blocking work, honest)

- **mt76:** finish the router side — repoint `/etc/mt76-csi.conf` `udp.host` to the Pi (`.149`),
  create the CSI monitor vif so `csi-capture` finds the device, and start `mt76-csi` (currently
  the daemon is not running; `csi-capture` reports "No such device").
- **Intel:** finish building FeitCSI + the patched iwlwifi driver before the `feitcsi` reader can
  be validated against real frames.

## Out of scope
- BFI second instance (planned as a parallel follow-up; not built this pass).
- Cross-vendor fused width normalization.
- Per-zone node splitting on the router.
