# csi_shim end-to-end verification runbook

This is the acceptance-gate runbook for the `csi_shim` package (ADR-018 CSI
normalization -> sensing-server UDP ingest on `:5005`). It documents how to
deploy the package to the Pi (`optaris-edge`, `192.168.8.149`), bring up each
CSI source, and what to expect in `/api/v1/nodes` for each one. Read this
before re-running verification, and update it if a deferred/parked source
becomes live.

The live sensing server on this Pi is **OptarisSense's `sensing-server.service`**
(`--source esp32`), REST on `:8080`, UDP ingest on `:5005`. It already serves
native ESP32 nodes independently of `csi_shim` -- do not disturb it while
testing.

## 1. Deploy

```bash
rsync -az -e "ssh -i ~/.ssh/id_ed25519" python/csi_shim/ pi@192.168.8.149:/home/pi/Ragnar/python/csi_shim/
rsync -az -e "ssh -i ~/.ssh/id_ed25519" config/systemd/ pi@192.168.8.149:/home/pi/Ragnar/config/systemd/
rsync -az -e "ssh -i ~/.ssh/id_ed25519" scripts/ pi@192.168.8.149:/home/pi/Ragnar/scripts/
ssh -i ~/.ssh/id_ed25519 pi@192.168.8.149 "cd /home/pi/Ragnar && bash scripts/install_csi_shim.sh"
```

Expected: `Installed.` The installer copies the three `ragnar-csi-*.service`
units to `/etc/systemd/system/` and runs `systemctl daemon-reload`; it does
**not** enable or start anything (enable per source, deliberately, per below).

## 2. Baseline: confirm the native nodes before touching anything

```bash
curl -s http://127.0.0.1:8080/api/v1/nodes | python3 -m json.tool
```

Expected: only the native ESP32 node_ids (observed on this Pi: `1`, `3`, `5`),
all `"status": "active"`.

## 3. Bring up each source

| Source | node_id | Unit | Bring-up | Status this pass |
|---|---|---|---|---|
| ESP32 (native) | 1, 3, 5 | n/a (built into sensing-server) | always on | LIVE (baseline) |
| feitcsi (Intel AX210) | 210 | `ragnar-csi-intel` | see 3a | **LIVE** (verified this session) |
| nexmon (Broadcom bcm43455c0) | 200 | `ragnar-csi-nexmon` | see 3b | DEFERRED |
| mt76 (GL-iNet router) | 176 | `ragnar-csi-mt76` | see 3c | PARKED |

### 3a. feitcsi / Intel AX210 -> node 210 (LIVE)

The patched iwlwifi driver from `scripts/build_feitcsi.sh` must be loaded and
`wlp1s0` present:

```bash
lsmod | grep -E 'iwlmvm|iwlwifi|mac80211|cfg80211|compat'
ip -br link show wlp1s0   # if missing: sudo iw phy phy0 interface add wlp1s0 type managed
sudo ip link set wlp1s0 up
```

**Critical caveat found this session: FeitCSI only flushes its output file
to disk on `SIGINT`** (`kill -INT` / `timeout -s INT`), and it **truncates**
whatever `-o FILE` points at on every invocation -- it does not append. The
`feitcsi_reader.run()` tail loop, on the other hand, opens its input file
*once* and reads forward from byte 0, busy-polling (tight loop, no sleep) at
EOF for more bytes appended to the *same* inode. Those two behaviors don't
compose directly: a single long-running `feitcsi -o /tmp/feit_sample.dat`
process gives the shim nothing until you kill it (SIGINT) to flush, and a
second `feitcsi` invocation against the same path would truncate the file
out from under the shim's open file descriptor.

The working pattern (used to get node 210 live this session): capture short,
bounded bursts to a **scratch file**, then `cat` each burst onto the shim's
target file (`/tmp/feit_sample.dat`, the default `source_path` in
`feitcsi_reader.run()`) so the target only ever grows:

```bash
: > /tmp/feit_sample.dat   # start clean
sudo timeout -s INT 6 feitcsi -i measure -f 2462 -r NOHT -w 20 -o /tmp/feit_burst.dat
cat /tmp/feit_burst.dat >> /tmp/feit_sample.dat
# (repeat the two lines above to keep node 210 "active" rather than "stale")

cd /home/pi/Ragnar && python3 -m python.csi_shim feitcsi   # tails /tmp/feit_sample.dat -> :5005
```

`-f 2462 -r NOHT -w 20` is channel 11 / 20MHz legacy-OFDM -- the capture
params verified against real ambient AP traffic in Task 8/9, and the exact
format `feitcsi_reader.decode_feit_measurement()` expects (52 subcarriers,
2 RX / 1 TX, `LEGACY_OFDM`).

**Known issue (log for follow-up, not fixed this pass):**
`feitcsi_reader.run()`'s tail loop busy-spins one CPU core at ~100% with no
backoff once it catches up to EOF (matches the "run() busy-spins on partial
file read" note from Task 9). On this Pi's marginal cooling/PSU, a shim left
running idle at EOF for several minutes measurably drove SoC temp up (69C ->
85C+) on its own, independent of any active feitcsi capture, and coincided
with a transient SSH/network hiccup (no reboot, no OOM-kill; `hwmon2:
Undervoltage detected!` events in `dmesg` around the same window). Do not
leave the feitcsi shim running unattended on this hardware without a temp
watchdog; a follow-up should add a short `time.sleep()` on empty reads in
`feitcsi_reader.run()`'s tail loop.

The `ragnar-csi-intel.service` unit runs `python3 -m python.csi_shim feitcsi`
directly, which has this same limitation -- it depends on something external
(cron/timer/companion script) continuously feeding `/tmp/feit_sample.dat`.
That companion piece was **not** built this pass (out of scope: this pass
proves the reader/decoder/sink path against real captured data, not a
production-grade continuous-capture daemon for FeitCSI). Do not
`systemctl enable --now ragnar-csi-intel` unattended until that gap is
closed, for the same thermal reason above.

### 3b. nexmon / Broadcom bcm43455c0 -> node 200 (DEFERRED)

```bash
sudo systemctl enable --now ragnar-csi-nexmon
```

**Do not run this yet.** `nexmon_reader.run()` hardcodes
`bind_iface="wlan0"` (see `python/csi_shim/nexmon_reader.py`), but this Pi's
onboard Broadcom radio enumerates as **`wlan1`**, not `wlan0` (confirmed
during Task 8 bring-up, see `.superpowers/sdd/progress.md`,
2026-07-17 POST-PSU-SWAP entry). Starting the unit as shipped will bind to a
non-existent/wrong interface and receive nothing. The core ADR-018
encode/scale/null-map path for nexmon is fully implemented and unit-tested
(`tests/csi_shim/test_nexmon_reader.py`) against the real nexmon_bridge.py
wire format -- what's deferred is only the interface-name wiring for *this*
specific Pi. Fix before enabling: either pass `bind_iface="wlan1"` explicitly
(the CLI doesn't currently expose this -- would need a small `__main__.py`
change or an env-var override, matching the `NEXMON_DIV` pattern already
used for the divisor) or rename the interface at the OS level to `wlan0`.

DIV / null-map (finalized, Task 5): `NEXMON_DIV` env var, default `16`;
null-subcarrier set `maps.NEXMON_BCM43455C0_HT20 = {0,1,2,3,32,61,62,63}`
(DC + guard/null carriers for bcm43455c0 HT20, 64-bin -- verified against
`nexmon_bridge.py`).

### 3c. mt76 / GL-iNet router -> node 176 (PARKED)

```bash
sudo systemctl enable --now ragnar-csi-mt76
```

**Do not run this.** `python/csi_shim/mt76_reader.py` does not exist in this
repo -- the module is parked, not merely deferred, so
`python3 -m python.csi_shim mt76` will fail with `ModuleNotFoundError`
immediately. Root cause (Task 6, see `.superpowers/sdd/task-6-report.md`):
the router's `mt76-csi-daemon` never advanced `csi_stats.data_cnt` past `0`
across five independent test configurations (default, MAC-filtered, explicit
sampling interval, a MAC I fully controlled generating verified heavy
traffic, and a clean idempotent daemon restart), the standalone
`csi-capture` tool segfaults on every invocation, and the daemon leaks ~400MB
and gets OOM-killed roughly every 30 minutes regardless. This is a
firmware/driver-level defect in the router's vendor CSI feature, not
something fixable from this repo. No real mt76 CSI sample has ever been
obtained, so per the task brief's explicit instruction, no fixture or reader
was fabricated. `maps.MT7915_VHT80` (the null-subcarrier set) is present but
carries an *initial, unconfirmed* value pending a real capture -- treat it as
provisional if/when the router firmware is fixed and this work resumes.

`scripts/router_mt76_csi_bringup.sh` (router-side config idempotent bring-up)
is committed and works correctly as far as it goes -- it is not the blocker.

## 4. Verify: node appears in the sensing API + frames on the wire

```bash
curl -s http://127.0.0.1:8080/api/v1/nodes | python3 -m json.tool
sudo timeout 6 tcpdump -ni any udp port 5005 -c 20 2>/dev/null | grep -c UDP
```

Expected once a source is live: an entry for that source's node_id with a
small (and climbing, if you poll again) `last_seen_ms` and
`"status": "active"`, plus a non-zero tcpdump packet count.

## 5. Results from this session (2026-07-17)

**Deploy**: succeeded. `rsync` + `scripts/install_csi_shim.sh` ->
`Installed.` on `optaris-edge` (`192.168.8.149`).

**Baseline** (`curl /api/v1/nodes`, before any csi_shim source started):

```json
{"nodes": [
  {"node_id": 1, "status": "active", "last_seen_ms": 4, ...},
  {"node_id": 5, "status": "active", "last_seen_ms": 14, ...},
  {"node_id": 2, "status": "active", "last_seen_ms": 12, ...}
], "total": 3}
```

**After** (feitcsi live, `curl /api/v1/nodes` immediately after one capture
burst + append, per section 3a):

```json
{"nodes": [
  {"node_id": 1,   "status": "active", "last_seen_ms": 12,  ...},
  {"node_id": 210, "status": "active", "last_seen_ms": 521, "rssi_dbm": -80.0, "motion_level": "present_moving", "person_count": 1},
  {"node_id": 3,   "status": "active", "last_seen_ms": 14,  ...},
  {"node_id": 5,   "status": "active", "last_seen_ms": 43,  ...}
], "total": 4}
```

Node 210 (feitcsi/Intel) went from absent to `"status": "active"` with a
sub-second `last_seen_ms`, decoded from a real `feitcsi -i measure -f 2462
-r NOHT -w 20` capture (148-record and 148-decoded-clean test capture
confirmed byte-for-byte via `decode_feit_measurement()` before the live run;
0 decode failures). `tcpdump -ni any udp port 5005 -c 20` counted `20/20`
UDP packets. The 3 native ESP32 nodes (`1`, `3`, `5`) remained active and
undisturbed throughout -- `sensing-server.service` was never restarted or
reconfigured.

**Not brought live this pass**: nexmon (node 200, DEFERRED --
`wlan0`/`wlan1` bind mismatch) and mt76 (node 176, PARKED -- router firmware
defect). See sections 3b/3c above.

**Thermal**: this Pi has weak cooling and a marginal PSU (documented in
`.superpowers/sdd/progress.md`). During this verification an idle csi_shim
process left busy-spinning at EOF (see 3a) drove SoC temp from ~69C to a
peak of ~86C and coincided with `hwmon2: Undervoltage detected!` events and
a ~2-minute SSH connectivity hiccup (confirmed via `uptime`: no reboot
occurred). All csi_shim/feitcsi processes were stopped and temporary
files/scripts removed at the end of the session; the Pi was left at ~78C,
`sensing-server.service` active, and the 3 ESP32 nodes healthy. Anyone
re-running this verification should watch `vcgencmd measure_temp` /
`get_throttled` and avoid leaving the feitcsi shim running unattended (see
the busy-spin note in 3a).

## 6. Full DIV / null-map reference

| Source | node_id | Default DIV | Null-subcarrier map | Status |
|---|---|---|---|---|
| nexmon | 200 | `NEXMON_DIV` env, default `16` | `NEXMON_BCM43455C0_HT20` (8 carriers, verified vs. nexmon_bridge.py) | DEFERRED |
| mt76 | 176 | n/a (no reader) | `MT7915_VHT80` (14 carriers, provisional/unconfirmed) | PARKED |
| feitcsi | 210 | `DEFAULT_DIV = 2` (calibrated via `scaling.calibrate_divisor()` against real captured I/Q, target=127, pct=99) | `AX210_HE` (empty set -- FeitCSI's firmware already strips DC/guard bins before userspace delivery, verified against 3696 real records with no near-zero pattern) | **LIVE** |
