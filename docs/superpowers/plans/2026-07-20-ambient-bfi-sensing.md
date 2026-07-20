# Ambient BFI Sensing (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Passively sniff beamforming-feedback (BFI) from ambient 802.11ac/ax devices with a dedicated USB monitor adapter (+ GL-MT3000 monitor mode), feed it to a separate `sensing-server --source bfi` instance, and surface an independent "ambient activity" layer — without touching the production dedicated-node pipeline.

**Architecture:** Isolated additive layer (Approach 1 in `decisionTree.md`). Monitor-mode capture → bfi instance on `:8081`/`:8766` → ambient presence/motion. Production stack (fan-out `:5005` → OptarisSense `:5105` + Ragnar `:5006`) is untouched.

**Tech Stack:** Linux monitor mode (`iw`/`airmon`-style, reuse `wifiwatch-setup-mon.sh`), `tcpdump`/`tshark` capture, the vendored `sensing-server` (`--source bfi --bfi-pcap`), systemd, Python 3.12 (stdlib) only if a BFI decoder proves necessary (gated by Task 1).

## Global Constraints

- **This layer must not touch the production pipeline:** do not bind `:5005`/`:5105`/`:5006`/`:8080`/`:8765`/`:3000`; do not use the AX210 (`wlp1s0`) or the dedicated nodes' radios. Ambient instance ports: HTTP `:8081`, WS `:8766`.
- Reuse the existing `wifiwatch-setup-mon.sh` monitor-mode pattern; do not reinvent monitor setup.
- Rolling pcap must be **size-bounded** (the Pi is storage/power constrained — never fill the SD).
- stdlib-only Python if a decoder is needed; no new third-party Python deps.
- No authorship/attribution comments of any kind; Unix (LF) line endings.
- Commit messages: **no** Co-Authored-By / Claude / Anthropic / authorship trailer.
- Pi access: `ssh -i ~/.ssh/id_ed25519 pi@192.168.8.149` (IP, mDNS flaky). The Pi is power/thermally marginal and has been unstable — verify reachability and re-run on reboot.

## Prerequisites (must hold before Task 1)

- [ ] **USB monitor adapter present** on the Pi (a dual-band `mt76` adapter, e.g. Alfa AWUS036ACM). Confirm: `iw dev` lists it and `iw phy` shows `monitor` in supported interface modes. **This is user-acquired hardware — the plan cannot proceed without it.**
- [ ] **Pi stable** (power sorted; not mid-reboot). The Ragnar deployment (separate work) should have settled.

---

### Task 1: O1 — characterize what `--bfi-pcap` ingests (GATING)

Decides whether a custom BFI decoder (Task 3) is needed or the pipeline is capture-and-feed only. No new code yet — this is empirical discovery producing a documented answer + a captured fixture.

**Files:**
- Create: `tests/ambient/fixtures/bfi_monitor_sample.pcap` (a real capture)
- Create: `docs/ambient-bfi-o1-findings.md` (the answer)

- [ ] **Step 1: Capture a real monitor pcap containing beamforming feedback**

On the Pi, put the USB adapter into monitor mode on a busy channel and capture VHT/HE compressed-beamforming action frames:
```bash
# adapter=wlanX (the USB one). Reuse the repo's monitor setup:
sudo ./wifiwatch-setup-mon.sh <wlanX> US
# capture action frames (mgmt subtype Action) for ~60s on a busy 5GHz channel:
sudo iw dev <wlanX> set channel 36
sudo timeout 60 tcpdump -i <wlanX> -w /tmp/bfi.pcap 'type mgt subtype action' -c 2000
# how many look like VHT/HE beamforming reports?
tshark -r /tmp/bfi.pcap -Y 'wlan.vht.action == 0 || wlan.he_action' 2>/dev/null | wc -l
```
Expected: a non-zero count of beamforming-report frames. Copy to the fixture:
```bash
scp -i ~/.ssh/id_ed25519 pi@192.168.8.149:/tmp/bfi.pcap tests/ambient/fixtures/bfi_monitor_sample.pcap
```
If the count is ~0, the environment has too little beamforming traffic — **stop and report** (record what channels/bands were tried); the whole approach depends on ambient beamforming existing.

- [ ] **Step 2: Feed the raw monitor pcap to the bfi instance and observe**

```bash
# on the Pi, run the vendored sensing-server in bfi mode against the RAW pcap, on ambient ports:
/usr/local/bin/sensing-server --source bfi --bfi-pcap /tmp/bfi.pcap \
  --http-port 8081 --ws-port 8766 --bind-addr 127.0.0.1 &
sleep 5
curl -s http://127.0.0.1:8081/api/v1/health; echo
curl -s http://127.0.0.1:8081/api/v1/nodes; echo
# check logs for "decoded N BFI reports" vs "no reports / parse error"
```
- [ ] **Step 3: Record the answer in `docs/ambient-bfi-o1-findings.md`**

Document one of two outcomes, with the evidence (log lines, health/nodes output):
- **(A) Raw pcap accepted** — the server decodes BFI itself from a standard monitor pcap → Task 3 is SKIPPED; the pipeline is capture-and-feed.
- **(B) Pre-decoded reports required** — the server needs BFI already extracted → Task 3 (a decoder) is REQUIRED; record the exact input format it expects (field layout, per-report structure) from its source/logs.

- [ ] **Step 4: Commit the fixture + findings**

```bash
mkdir -p tests/ambient/fixtures
git add tests/ambient/fixtures/bfi_monitor_sample.pcap docs/ambient-bfi-o1-findings.md
git commit -m "ambient: O1 findings — bfi-pcap input format + captured monitor fixture"
```

---

### Task 2: Monitor-mode capture service (rolling, bounded)

A systemd-managed capture that keeps a monitor adapter parked on a channel and maintains a rolling, size-bounded pcap for the bfi instance to consume. Ops task; verified by observing frames accumulate.

**Files:**
- Create: `scripts/ambient/ambient_monitor_capture.sh`
- Create: `config/systemd/ragnar-ambient-capture@.service` (templated per-adapter)

- [ ] **Step 1: Write the capture script**

```bash
# scripts/ambient/ambient_monitor_capture.sh
#!/usr/bin/env bash
# Park an adapter in monitor mode on a channel and roll a size-bounded pcap of action frames.
# Usage: IFACE=wlan1 CHANNEL=36 OUTDIR=/var/lib/ragnar/ambient MAXFILES=4 MAXSIZE=64 ./ambient_monitor_capture.sh
set -euo pipefail
IFACE="${IFACE:?set IFACE}"; CHANNEL="${CHANNEL:?set CHANNEL}"
OUTDIR="${OUTDIR:-/var/lib/ragnar/ambient}"; MAXFILES="${MAXFILES:-4}"; MAXSIZE="${MAXSIZE:-64}"  # MB per file
mkdir -p "$OUTDIR"
# ensure monitor mode via the repo's existing helper (idempotent)
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
if ! iw dev "$IFACE" info 2>/dev/null | grep -q 'type monitor'; then
  sudo "$SCRIPT_DIR/wifiwatch-setup-mon.sh" "$IFACE" US || true
fi
sudo iw dev "$IFACE" set channel "$CHANNEL"
# rolling capture: MAXFILES files of MAXSIZE MB, action frames only (beamforming feedback lives here)
exec sudo tcpdump -i "$IFACE" -w "$OUTDIR/bfi-%Y%m%d-%H%M%S.pcap" \
  -C "$MAXSIZE" -W "$MAXFILES" -Z root 'type mgt subtype action'
```

- [ ] **Step 2: Write the templated systemd unit**

```ini
# config/systemd/ragnar-ambient-capture@.service   (instance = IFACE:CHANNEL, e.g. wlan1:36)
[Unit]
Description=Ragnar ambient BFI monitor capture (%i)
After=network-online.target
[Service]
Environment=OUTDIR=/var/lib/ragnar/ambient
ExecStart=/bin/sh -c 'IFACE=$(echo %i | cut -d: -f1) CHANNEL=$(echo %i | cut -d: -f2) /home/pi/ragnar-app/scripts/ambient/ambient_monitor_capture.sh'
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Deploy + start on the Pi and verify frames accumulate**

```bash
rsync -az -e "ssh -i ~/.ssh/id_ed25519" scripts/ambient/ pi@192.168.8.149:/home/pi/ragnar-app/scripts/ambient/
ssh -i ~/.ssh/id_ed25519 pi@192.168.8.149 "sudo install -m0644 /home/pi/ragnar-app/config/systemd/ragnar-ambient-capture@.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl start 'ragnar-ambient-capture@wlan1:36'; sleep 20; ls -la /var/lib/ragnar/ambient/; sudo tcpdump -r \$(ls -t /var/lib/ragnar/ambient/*.pcap | head -1) 2>/dev/null | wc -l"
```
Expected: a growing pcap with a non-zero frame count, capped at `MAXFILES`×`MAXSIZE` MB.

- [ ] **Step 4: Commit**

```bash
git add scripts/ambient/ambient_monitor_capture.sh config/systemd/ragnar-ambient-capture@.service
git commit -m "ambient: rolling bounded monitor-capture service for BFI"
```

---

### Task 3: BFI decoder — CONDITIONAL on Task 1 outcome (B)

**Only if Task 1 concluded (B) pre-decoded reports required.** If Task 1 concluded (A), SKIP this task entirely and note the skip in the ledger.

Decode the VHT/HE compressed beamforming report (φ/ψ angles + metadata) from each captured action frame into the exact structure the bfi instance requires (recorded in `docs/ambient-bfi-o1-findings.md`). Capture-driven TDD against the Task 1 fixture.

**Files:**
- Create: `python/ambient_bfi/__init__.py`, `python/ambient_bfi/bfi_parser.py`
- Test: `tests/ambient/test_bfi_parser.py`

**Interfaces:**
- Produces: `bfi_parser.parse_beamforming_report(frame_bytes: bytes) -> dict | None` returning the fields O1 says the server needs (e.g. `{"src","bssid","nc","nr","angles":[...]}`); exact keys per O1 findings.

- [ ] **Step 1: Write the fixture-driven failing test** — read a frame out of `bfi_monitor_sample.pcap`, assert `parse_beamforming_report` returns the expected non-empty structure (fields/counts pinned from the O1 findings doc). *(Fill the exact asserted values from the real fixture — do not fabricate.)*
- [ ] **Step 2: Run it — expect ModuleNotFoundError.**
- [ ] **Step 3: Implement `parse_beamforming_report`** against the real 802.11 VHT/HE compressed-beamforming-report layout observed in the fixture (match the structure documented in O1 findings; use `struct`/bitfield parsing).
- [ ] **Step 4: Run tests — expect pass.**
- [ ] **Step 5:** Write a small `feed.py` that turns parsed reports into the bfi instance's `--bfi-pcap`/stream input, then commit (`ambient: BFI report decoder + feed (per O1 format)`).

---

### Task 4: Ambient `sensing-server --source bfi` instance + wiring

Run the bfi instance on ambient ports, consuming the capture (raw pcap if O1=A, or the decoder's output if O1=B), as a systemd service independent of the production stack.

**Files:**
- Create: `config/systemd/ragnar-ambient-sensing.service`
- Create: `scripts/ambient/install_ambient.sh`

- [ ] **Step 1: Write the ambient sensing unit**

```ini
# config/systemd/ragnar-ambient-sensing.service
[Unit]
Description=Ragnar ambient BFI sensing-server (:8081)
After=network-online.target ragnar-ambient-capture@wlan1:36.service
[Service]
# BFI_INPUT is the rolling pcap dir/file (O1=A) or the decoder feed (O1=B). Set at install.
ExecStart=/usr/local/bin/sensing-server --source bfi --bfi-pcap ${BFI_INPUT} --http-port 8081 --ws-port 8766 --bind-addr 127.0.0.1
Environment=BFI_INPUT=/var/lib/ragnar/ambient/latest.pcap
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Write the installer** (`scripts/ambient/install_ambient.sh`) — idempotently install both units, enable the capture instance(s) (USB adapter channel + GL-MT3000 monitor on 2.4 GHz), and the sensing unit; print how to start/stop. (Adjust `BFI_INPUT` per O1 outcome.)
- [ ] **Step 3: Deploy + start; verify the ambient instance is healthy on :8081 and NOT touching production ports**

```bash
ssh -i ~/.ssh/id_ed25519 pi@192.168.8.149 "sudo bash /home/pi/ragnar-app/scripts/ambient/install_ambient.sh && sleep 6; curl -s http://127.0.0.1:8081/api/v1/health; echo; sudo ss -ulnp | grep -E ':8081|:5005|:5105' | sed 's/users.*//'"
```
Expected: `:8081` healthy; `:5005/:5105` still owned by the production fan-out/OptarisSense (untouched).

- [ ] **Step 4: Commit** (`ambient: bfi sensing instance unit + installer`).

---

### Task 5: End-to-end verification (walk test) + runbook

**Files:**
- Create: `tests/ambient/README.md`

- [ ] **Step 1:** With capture + ambient instance running, confirm the ambient layer reacts to real activity: query `http://127.0.0.1:8081/api/v1/*` (presence/motion) while someone moves through the ambient-covered area; capture before/after.
- [ ] **Step 2:** Confirm the **production stack is unaffected** — OptarisSense `:8080` nodes still active, Ragnar `:3000` still active, fan-out `:5005` intact.
- [ ] **Step 3:** Write `tests/ambient/README.md` — the capture/ingest/verify commands, expected outputs, the per-radio channel assignment, and the O1 outcome (A or B). Commit (`docs(ambient): verification runbook`).

---

## Notes for the executor
- **Task 1 gates Task 3.** Do not build a decoder until O1 proves it's needed; if O1=A, skip Task 3 and wire the raw pcap straight through.
- **Do not fabricate** a pcap fixture or a decoder that only passes a trivial test — if the environment has no ambient beamforming, or the format can't be determined, STOP and report.
- **Hardware/stability gate:** requires the USB monitor adapter and a stable Pi; if either is missing, this plan cannot execute — report the blocker.
- Passive-CSI (Phase 2) and Approach-3 node injection are explicitly out of scope (separate spec).
