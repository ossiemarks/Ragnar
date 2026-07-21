# csi_shim CSI Ingestion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Normalize CSI from Nexmon (Broadcom), mt76 (MediaTek GL-MT3000), and FeitCSI (Intel AX210) into ADR-018 frames on UDP `:5005`, so each appears as an independent node in the sensing-server alongside the native ESP32 nodes.

**Architecture:** One shared, pure ADR-018 encoder + scaling/subcarrier-map helpers, consumed by thin per-vendor reader front-ends (`nexmon`, `mt76`, `feitcsi`). Each reader is its own process/systemd unit. Vendor wire formats that are not yet observable (mt76, FeitCSI) are characterized from a captured real sample before their decoder is written and tested against that fixture.

**Tech Stack:** Python 3.12 (stdlib only: `socket`, `struct`, `json`), pytest, systemd (Pi) + procd (router). Reference: `/home/pi/nexmon_bridge.py`, Rust `esp-csi` crate.

## Global Constraints

- Target contract: **ADR-018** — 20-byte LE header (`magic=0xC5110001`, u8 node_id, u8 n_antennas, u16 n_subcarriers, u32 channel_freq_mhz, u32 sequence, i8 rssi_dbm, i8 noise_floor_dbm, u8 ppdu_type, u8 flags) + `n_antennas × n_subcarriers × (I,Q)` **int8** pairs, sent by UDP to `127.0.0.1:5005`.
- Scaling is **fixed-divisor** int→int8 (calibrated once from a sampled distribution), **never per-frame AGC** — frame-to-frame amplitude variation must be preserved.
- node-id scheme: ESP32 firmware `2`,`5` · Nexmon `200` · mt76 `176` · Intel `210`. Do not reuse ids.
- No new third-party Python dependencies — stdlib only.
- Code style / repo rules: no authorship/attribution comments of any kind; Unix line endings.
- Package location: `python/csi_shim/` (repo `python/` tool convention). Tests: `tests/csi_shim/`.
- The sensing-server is unchanged (`--source esp32`, UDP `:5005`); shims are pure producers.

---

### Task 1: ADR-018 frame encoder

**Files:**
- Create: `python/csi_shim/__init__.py`
- Create: `python/csi_shim/adr018.py`
- Test: `tests/csi_shim/test_adr018.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `adr018.MAGIC: int`; `adr018.HEADER_LEN: int = 20`; `adr018.encode_frame(node_id:int, n_antennas:int, n_subcarriers:int, freq_mhz:int, seq:int, rssi:int, noise:int, iq_int8:bytes, ppdu_type:int=0, flags:int=0) -> bytes` where `iq_int8` is already-scaled two's-complement int8 bytes of length `n_antennas*n_subcarriers*2`.

- [ ] **Step 1: Write the failing test**

```python
# tests/csi_shim/test_adr018.py
import struct
from python.csi_shim import adr018


def test_header_layout_and_payload():
    iq = bytes([1, 0xFF] * 64)  # 64 subcarriers, I=1 Q=-1
    frame = adr018.encode_frame(
        node_id=176, n_antennas=1, n_subcarriers=64, freq_mhz=5210,
        seq=7, rssi=-40, noise=-92, iq_int8=iq, ppdu_type=1, flags=2,
    )
    assert len(frame) == adr018.HEADER_LEN + len(iq)
    magic, node, nant, nsub, freq, seq, rssi, noise, ppdu, flags = struct.unpack(
        "<IBBHIIbbBB", frame[:adr018.HEADER_LEN]
    )
    assert magic == 0xC5110001
    assert (node, nant, nsub, freq, seq) == (176, 1, 64, 5210, 7)
    assert (rssi, noise, ppdu, flags) == (-40, -92, 1, 2)
    assert frame[adr018.HEADER_LEN:] == iq


def test_rssi_and_noise_are_clamped():
    frame = adr018.encode_frame(200, 1, 8, 2437, 0, 200, -300, bytes(16))
    _, _, _, _, _, _, rssi, noise, _, _ = struct.unpack("<IBBHIIbbBB", frame[:20])
    assert rssi == 127 and noise == -128
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_adr018.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'python.csi_shim'`

- [ ] **Step 3: Write minimal implementation**

```python
# python/csi_shim/__init__.py
# (empty package marker)
```

```python
# python/csi_shim/adr018.py
"""ADR-018 CSI frame encoder — the single wire-format authority for :5005 ingest."""
import struct

MAGIC = 0xC5110001
HEADER_LEN = 20
_HEADER = struct.Struct("<IBBHIIbbBB")


def _clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def encode_frame(node_id, n_antennas, n_subcarriers, freq_mhz, seq, rssi, noise,
                 iq_int8, ppdu_type=0, flags=0):
    header = _HEADER.pack(
        MAGIC,
        node_id & 0xFF,
        n_antennas & 0xFF,
        n_subcarriers & 0xFFFF,
        freq_mhz & 0xFFFFFFFF,
        seq & 0xFFFFFFFF,
        _clamp(rssi, -128, 127),
        _clamp(noise, -128, 127),
        ppdu_type & 0xFF,
        flags & 0xFF,
    )
    return header + bytes(iq_int8)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_adr018.py -v`
Expected: PASS (2 passed)

- [ ] **Step 5: Commit**

```bash
git add python/csi_shim/__init__.py python/csi_shim/adr018.py tests/csi_shim/test_adr018.py
git commit -m "feat(csi_shim): ADR-018 frame encoder"
```

---

### Task 2: Scaling + null-subcarrier helpers

**Files:**
- Create: `python/csi_shim/scaling.py`
- Test: `tests/csi_shim/test_scaling.py`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `scaling.scale_to_int8(iq_ints:Sequence[int], div:int) -> bytes` — floor-divides each interleaved I/Q int by `div`, clamps to [-127,127], returns two's-complement int8 bytes (length == len(iq_ints)).
  - `scaling.zero_null_subcarriers(iq_int8:bytes, null_set:frozenset[int]) -> bytes` — zeroes both I and Q bytes for each subcarrier index `k` in `null_set`.
  - `scaling.calibrate_divisor(magnitudes:Sequence[int], target:int=127, pct:int=99) -> int` — returns `max(1, round(percentile(pct)/target))`.

- [ ] **Step 1: Write the failing test**

```python
# tests/csi_shim/test_scaling.py
from python.csi_shim import scaling


def test_scale_floor_divides_and_clamps():
    out = scaling.scale_to_int8([300, -300, 16, -16], div=16)
    assert list(out) == [127, (-18) & 0xFF, 1, (-1) & 0xFF]  # 300//16=18->127; -300//16=-19->-18? see note


def test_zero_null_subcarriers():
    iq = bytes([9] * 8)  # 4 subcarriers
    out = scaling.zero_null_subcarriers(iq, frozenset([0, 3]))
    assert list(out) == [0, 0, 9, 9, 9, 9, 0, 0]


def test_calibrate_divisor_maps_p99_to_target():
    mags = list(range(1, 101))  # p99 ~= 99
    assert scaling.calibrate_divisor(mags, target=127, pct=99) == 1
    big = [1000] * 100
    assert scaling.calibrate_divisor(big, target=127, pct=99) == round(1000 / 127)
```

> Note: Python floor-division of negatives rounds toward −∞ (`-300 // 16 == -19`); the clamp lower bound is −127, so `-19` stays `-19`. Fix the first assertion to the real values before running (see Step 3 for exact semantics), then lock it.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_scaling.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'python.csi_shim.scaling'`

- [ ] **Step 3: Write minimal implementation**

```python
# python/csi_shim/scaling.py
"""Fixed-divisor int->int8 scaling and null-subcarrier zeroing (shared by all readers)."""


def scale_to_int8(iq_ints, div):
    if div < 1:
        div = 1
    out = bytearray(len(iq_ints))
    for i, v in enumerate(iq_ints):
        q = v // div
        if q > 127:
            q = 127
        elif q < -127:
            q = -127
        out[i] = q & 0xFF
    return bytes(out)


def zero_null_subcarriers(iq_int8, null_set):
    b = bytearray(iq_int8)
    for k in null_set:
        i = 2 * k
        if i + 1 < len(b):
            b[i] = 0
            b[i + 1] = 0
    return bytes(b)


def calibrate_divisor(magnitudes, target=127, pct=99):
    if not magnitudes:
        return 1
    s = sorted(abs(v) for v in magnitudes)
    idx = min(len(s) - 1, (len(s) * pct) // 100)
    p = s[idx] or 1
    return max(1, round(p / target))
```

Now correct `test_scale_floor_divides_and_clamps` to the true semantics: `300//16=18`→`18`; `-300//16=-19`→`-19`; `16//16=1`; `-16//16=-1`. Update the assertion:

```python
def test_scale_floor_divides_and_clamps():
    out = scaling.scale_to_int8([300, -300, 16, -16], div=16)
    assert list(out) == [18, (-19) & 0xFF, 1, (-1) & 0xFF]


def test_scale_clamps_extremes():
    out = scaling.scale_to_int8([5000, -5000], div=1)
    assert list(out) == [127, (-127) & 0xFF]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_scaling.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Commit**

```bash
git add python/csi_shim/scaling.py tests/csi_shim/test_scaling.py
git commit -m "feat(csi_shim): fixed-divisor int8 scaling + null-subcarrier helpers"
```

---

### Task 3: Per-chip null/pilot subcarrier maps

**Files:**
- Create: `python/csi_shim/maps.py`
- Test: `tests/csi_shim/test_maps.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `maps.NEXMON_BCM43455C0_HT20: frozenset[int]`; `maps.MT7915_VHT80: frozenset[int]`; `maps.AX210_HE: frozenset[int]`; `maps.for_chip(name:str) -> frozenset[int]` (name in `{"nexmon","mt76","feitcsi"}`).

> The Nexmon HT20 map is known (from `nexmon_bridge.py`). The mt76 (VHT80, 256-bin) and AX210 (HE) null/pilot sets are populated from the captured sample in Tasks 7 and 10 respectively; they start as documented placeholders sourced from the 802.11 subcarrier allocation and are corrected against real data.

- [ ] **Step 1: Write the failing test**

```python
# tests/csi_shim/test_maps.py
from python.csi_shim import maps


def test_nexmon_ht20_map_matches_reference_bridge():
    assert maps.NEXMON_BCM43455C0_HT20 == frozenset([0, 1, 2, 3, 32, 61, 62, 63])


def test_for_chip_dispatch():
    assert maps.for_chip("nexmon") == maps.NEXMON_BCM43455C0_HT20
    assert maps.for_chip("mt76") == maps.MT7915_VHT80
    assert maps.for_chip("feitcsi") == maps.AX210_HE


def test_unknown_chip_returns_empty():
    assert maps.for_chip("nope") == frozenset()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_maps.py -v`
Expected: FAIL — `ModuleNotFoundError`

- [ ] **Step 3: Write minimal implementation**

```python
# python/csi_shim/maps.py
"""Per-chip null/guard/pilot subcarrier indices to zero before ingest.

nexmon: verified from nexmon_bridge.py (bcm43455c0 HT20, 64-bin).
mt76 / feitcsi: initial values from the 802.11 VHT80 / HE subcarrier allocation;
corrected against a captured sample during the mt76 (Task 7) and feitcsi (Task 10) tasks.
"""

# 802.11n HT20, 64-bin: DC + guard/null carriers (no temporal signal).
NEXMON_BCM43455C0_HT20 = frozenset([0, 1, 2, 3, 32, 61, 62, 63])

# 802.11ac VHT80, 256-bin: DC (127,128,129) + band-edge guards. Refined in Task 7.
MT7915_VHT80 = frozenset(
    list(range(0, 6)) + [127, 128, 129] + list(range(251, 256))
)

# 802.11ax HE: DC + guards. Refined in Task 10 once FeitCSI width is observed.
AX210_HE = frozenset()

_BY_CHIP = {
    "nexmon": NEXMON_BCM43455C0_HT20,
    "mt76": MT7915_VHT80,
    "feitcsi": AX210_HE,
}


def for_chip(name):
    return _BY_CHIP.get(name, frozenset())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_maps.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Commit**

```bash
git add python/csi_shim/maps.py tests/csi_shim/test_maps.py
git commit -m "feat(csi_shim): per-chip null-subcarrier maps"
```

---

### Task 4: UDP sender + reader base

**Files:**
- Create: `python/csi_shim/sink.py`
- Test: `tests/csi_shim/test_sink.py`

**Interfaces:**
- Consumes: `adr018.encode_frame`.
- Produces: `sink.Adr018Sink(host:str="127.0.0.1", port:int=5005)` with `.send(node_id, n_antennas, n_subcarriers, freq_mhz, seq, rssi, noise, iq_int8, ppdu_type=0, flags=0) -> int` (returns bytes sent) and `.close()`. Uses a single AF_INET/DGRAM socket.

- [ ] **Step 1: Write the failing test**

```python
# tests/csi_shim/test_sink.py
import socket
from python.csi_shim.sink import Adr018Sink


def test_sink_sends_encoded_frame_over_udp():
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.bind(("127.0.0.1", 0))
    port = rx.getsockname()[1]
    s = Adr018Sink("127.0.0.1", port)
    n = s.send(176, 1, 8, 5210, 3, -40, -92, bytes(16))
    s.close()
    data, _ = rx.recvfrom(2048)
    rx.close()
    assert n == len(data) == 20 + 16
    assert data[:4] == b"\x01\x00\x11\xc5"  # 0xC5110001 little-endian
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_sink.py -v`
Expected: FAIL — `ModuleNotFoundError`

- [ ] **Step 3: Write minimal implementation**

```python
# python/csi_shim/sink.py
"""UDP sink that encodes ADR-018 frames and sends them to the sensing-server."""
import socket

from . import adr018


class Adr018Sink:
    def __init__(self, host="127.0.0.1", port=5005):
        self._addr = (host, port)
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def send(self, node_id, n_antennas, n_subcarriers, freq_mhz, seq, rssi, noise,
             iq_int8, ppdu_type=0, flags=0):
        frame = adr018.encode_frame(node_id, n_antennas, n_subcarriers, freq_mhz,
                                    seq, rssi, noise, iq_int8, ppdu_type, flags)
        return self._sock.sendto(frame, self._addr)

    def close(self):
        self._sock.close()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_sink.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add python/csi_shim/sink.py tests/csi_shim/test_sink.py
git commit -m "feat(csi_shim): ADR-018 UDP sink"
```

---

### Task 5: Nexmon reader refactor onto csi_shim

**Files:**
- Create: `python/csi_shim/nexmon_reader.py`
- Test: `tests/csi_shim/test_nexmon_reader.py`

**Interfaces:**
- Consumes: `sink.Adr018Sink`, `scaling.*`, `maps.NEXMON_BCM43455C0_HT20`.
- Produces: `nexmon_reader.decode_nexmon_udp_payload(payload:bytes) -> tuple[int, list[int]] | None` returning `(rssi, iq_ints)` from a nexmon CSI UDP payload (the bytes after the UDP header, starting `0x11 0x11`), or `None` if malformed. `nexmon_reader.NODE_ID=200`, `nexmon_reader.FREQ=2437`, `nexmon_reader.DEFAULT_DIV=16`.

> This decodes the same payload `nexmon_bridge.py` parses: `p[0:2]==b"\x11\x11"`, `rssi=int8(p[2])`, CSI I/Q as little-endian int16 pairs starting at `p[18:]`. This format IS known — full code below.

- [ ] **Step 1: Write the failing test**

```python
# tests/csi_shim/test_nexmon_reader.py
import struct
from python.csi_shim import nexmon_reader


def _make_payload(rssi, iq16):
    head = b"\x11\x11" + struct.pack("b", rssi) + bytes(15)  # 0x1111, rssi at [2], pad to 18
    body = struct.pack("<%dh" % len(iq16), *iq16)
    return head + body


def test_decode_extracts_rssi_and_iq():
    iq16 = [320, -320, 16, -16, 0, 0, 8, 8]  # 4 subcarriers
    out = nexmon_reader.decode_nexmon_udp_payload(_make_payload(-37, iq16))
    assert out is not None
    rssi, iq = out
    assert rssi == -37
    assert iq == iq16


def test_decode_rejects_short_or_wrong_magic():
    assert nexmon_reader.decode_nexmon_udp_payload(b"\x00\x00" + bytes(40)) is None
    assert nexmon_reader.decode_nexmon_udp_payload(b"\x11\x11") is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_nexmon_reader.py -v`
Expected: FAIL — `ModuleNotFoundError`

- [ ] **Step 3: Write minimal implementation**

```python
# python/csi_shim/nexmon_reader.py
"""Nexmon (Broadcom bcm43455c0) CSI -> ADR-018. Raw AF_PACKET sniff on wlan0.

Payload format (post-UDP): b"\\x11\\x11", int8 rssi at offset 2, int16 LE I/Q pairs at offset 18.
"""
import os
import socket
import struct

from . import maps, scaling
from .sink import Adr018Sink

NODE_ID = 200
FREQ = 2437
NOISE = -92
DEFAULT_DIV = int(os.environ.get("NEXMON_DIV", "16"))


def decode_nexmon_udp_payload(p):
    if len(p) < 22 or p[0:2] != b"\x11\x11":
        return None
    rssi = struct.unpack("b", p[2:3])[0]
    csi = p[18:]
    nsub = len(csi) // 4
    if nsub < 8:
        return None
    iq = list(struct.unpack("<%dh" % (nsub * 2), csi[: nsub * 4]))
    return rssi, iq


def run(bind_iface="wlan0", div=DEFAULT_DIV, sink=None):  # pragma: no cover (I/O loop)
    sink = sink or Adr018Sink()
    s = socket.socket(socket.AF_PACKET, socket.SOCK_DGRAM, socket.htons(0x0003))
    s.bind((bind_iface, 0))
    null = maps.NEXMON_BCM43455C0_HT20
    seq = 0
    while True:
        pkt, _ = s.recvfrom(4096)
        if len(pkt) < 30 or pkt[9] != 17:
            continue
        ihl = (pkt[0] & 0x0F) * 4
        udp = pkt[ihl:]
        if len(udp) < 8 or struct.unpack("!H", udp[2:4])[0] != 5500:
            continue
        dec = decode_nexmon_udp_payload(udp[8:])
        if dec is None:
            continue
        rssi, iq = dec
        nsub = len(iq) // 2
        iq8 = scaling.zero_null_subcarriers(scaling.scale_to_int8(iq, div), null)
        sink.send(NODE_ID, 1, nsub, FREQ, seq, rssi, NOISE, iq8)
        seq += 1
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_nexmon_reader.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add python/csi_shim/nexmon_reader.py tests/csi_shim/test_nexmon_reader.py
git commit -m "feat(csi_shim): nexmon reader on shared encoder (node 200)"
```

---

### Task 6: mt76 router toolchain bring-up

**Files:**
- Create: `scripts/router_mt76_csi_bringup.sh`

**Interfaces:**
- Consumes: SSH access to `root@192.168.8.1` (GL-MT3000).
- Produces: a running `mt76-csi` daemon on the router streaming CSI UDP to the Pi at `192.168.8.149:5500`; a captured sample at `/tmp/csi_sample.bin` on the Pi for Task 7.

> This is an ops task (no unit test); its deliverable is verified by observing frames arrive on the Pi. The script is idempotent and prints each check.

- [ ] **Step 1: Write the bring-up script**

```bash
# scripts/router_mt76_csi_bringup.sh
#!/usr/bin/env bash
# Bring the GL-MT3000 mt76-csi daemon live and pointed at the Pi.
# Usage: PI_IP=192.168.8.149 ROUTER=192.168.8.1 ./scripts/router_mt76_csi_bringup.sh
set -euo pipefail
ROUTER="${ROUTER:-192.168.8.1}"
PI_IP="${PI_IP:-192.168.8.149}"
PW="${ROUTER_PW:?set ROUTER_PW}"
rsh() { sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$ROUTER" "$@"; }

echo "[1/5] repoint udp.host -> $PI_IP in /etc/mt76-csi.conf"
rsh "sed -i 's/^host *=.*/host    = $PI_IP/' /etc/mt76-csi.conf && grep -A1 '\\[udp\\]' /etc/mt76-csi.conf"

echo "[2/5] ensure CSI-capable vif exists on the configured interface (ra0)"
rsh "iw dev | grep -q ra0 && echo 'ra0 present' || echo 'WARN: ra0 missing — check [csi] interface in conf'"

echo "[3/5] enable + (re)start mt76-csi"
rsh "/etc/init.d/mt76-csi enable; /etc/init.d/mt76-csi restart; sleep 2; ps w | grep -v grep | grep mt76-csi-daemon || echo 'WARN: daemon not in ps'"

echo "[4/5] confirm debugfs csi_stats is advancing"
rsh "cat /sys/kernel/debug/ieee80211/*/mt76/csi_stats 2>/dev/null | head; sleep 1; cat /sys/kernel/debug/ieee80211/*/mt76/csi_stats 2>/dev/null | head"

echo "[5/5] done — run Task 7 capture on the Pi to grab a sample frame"
```

- [ ] **Step 2: Make executable and run it**

```bash
chmod +x scripts/router_mt76_csi_bringup.sh
ROUTER_PW='<from Secrets Manager optaris/router/gl-mt3000-admin>' \
  PI_IP=192.168.8.149 ./scripts/router_mt76_csi_bringup.sh
```
Expected: `ra0 present`, the daemon shown in `ps`, and `csi_stats` counters increasing between the two reads.

- [ ] **Step 3: Capture a real mt76 UDP sample on the Pi**

Run (on the Pi, needs an active WiFi client generating traffic near the router):
```bash
ssh -i ~/.ssh/id_ed25519 pi@optaris-edge.local \
  "timeout 15 python3 - <<'PY'
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('0.0.0.0',5500))
s.settimeout(12); d,a=s.recvfrom(65535)
open('/tmp/csi_sample.bin','wb').write(d)
print('from',a,'len',len(d),'head',d[:16].hex())
PY"
```
Expected: prints the router's source IP, a plausible length, and a hex head. Copy the sample locally:
```bash
scp -i ~/.ssh/id_ed25519 pi@optaris-edge.local:/tmp/csi_sample.bin tests/csi_shim/fixtures/mt76_sample.bin
```

- [ ] **Step 4: Commit the script and fixture**

```bash
mkdir -p tests/csi_shim/fixtures
git add scripts/router_mt76_csi_bringup.sh tests/csi_shim/fixtures/mt76_sample.bin
git commit -m "chore(csi_shim): mt76 router bring-up script + captured sample fixture"
```

---

### Task 7: mt76 reader (decode against captured sample)

**Files:**
- Create: `python/csi_shim/mt76_reader.py`
- Test: `tests/csi_shim/test_mt76_reader.py`
- Modify: `python/csi_shim/maps.py` (correct `MT7915_VHT80` from the observed width)

**Interfaces:**
- Consumes: `tests/csi_shim/fixtures/mt76_sample.bin` (Task 6), `scaling.*`, `maps.MT7915_VHT80`, `sink.Adr018Sink`.
- Produces: `mt76_reader.decode_mt76_payload(payload:bytes) -> dict | None` returning `{"rssi":int, "freq":int, "iq":list[int], "n_sub":int}`. `mt76_reader.NODE_ID=176`.

> **Characterize first.** Inspect `mt76_sample.bin`: `python -c "d=open('tests/csi_shim/fixtures/mt76_sample.bin','rb').read(); print(len(d)); print(d[:64])"`. mt76-csi commonly emits JSON (the `csi-capture` tool writes `/tmp/csi.json`); if the payload starts with `{`, parse JSON (fields typically include a complex CSI array + rssi). If it is binary, decode the observed header. Write `decode_mt76_payload` to match the **actual bytes**, then set the test's `expected_*` from the sample. Below is the JSON-path implementation (the observed common case); replace the body with the binary decoder if the sample is binary.

- [ ] **Step 1: Write the failing test (fixture-driven)**

```python
# tests/csi_shim/test_mt76_reader.py
import pathlib
from python.csi_shim import mt76_reader

FIX = pathlib.Path(__file__).parent / "fixtures" / "mt76_sample.bin"


def test_decode_real_sample_yields_iq_pairs():
    payload = FIX.read_bytes()
    out = mt76_reader.decode_mt76_payload(payload)
    assert out is not None
    assert out["n_sub"] >= 64
    assert len(out["iq"]) == 2 * out["n_sub"]
    assert -128 <= out["rssi"] <= 0
    # I/Q are raw ints (pre-scale); at least one non-zero subcarrier
    assert any(v != 0 for v in out["iq"])
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_mt76_reader.py -v`
Expected: FAIL — `ModuleNotFoundError`

- [ ] **Step 3: Implement decoder to match the captured sample (JSON path shown)**

```python
# python/csi_shim/mt76_reader.py
"""MediaTek mt76 (mt7915, VHT80/256-bin) CSI -> ADR-018. UDP listener on :5500.

Wire format is the mt76-csi-daemon UDP output — characterized from a captured sample
(tests/csi_shim/fixtures/mt76_sample.bin). This module implements the observed layout.
"""
import json
import socket

from . import maps, scaling
from .sink import Adr018Sink

NODE_ID = 176
DEFAULT_DIV = 4  # refined from calibrate_divisor against the sample distribution


def decode_mt76_payload(payload):
    if not payload:
        return None
    # JSON path: mt76-csi emits an object with a complex CSI array + metadata.
    if payload[:1] in (b"{", b"["):
        try:
            obj = json.loads(payload.decode("utf-8", "strict"))
        except (ValueError, UnicodeDecodeError):
            return None
        data = obj.get("csi") or obj.get("data")
        if not data:
            return None
        iq = []
        for pair in data:  # each entry [I, Q]
            iq.append(int(pair[0]))
            iq.append(int(pair[1]))
        n_sub = len(iq) // 2
        rssi = int(obj.get("rssi", -50))
        freq = int(obj.get("freq", obj.get("channel_freq", 5210)))
        return {"rssi": rssi, "freq": freq, "iq": iq, "n_sub": n_sub}
    return None  # replace with binary decoder if the sample is not JSON


def run(port=5500, div=DEFAULT_DIV, allow_ip=None, sink=None):  # pragma: no cover (I/O loop)
    sink = sink or Adr018Sink()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", port))
    null = maps.MT7915_VHT80
    seq = 0
    while True:
        payload, addr = s.recvfrom(65535)
        if allow_ip and addr[0] != allow_ip:
            continue
        dec = decode_mt76_payload(payload)
        if dec is None:
            continue
        iq8 = scaling.zero_null_subcarriers(
            scaling.scale_to_int8(dec["iq"], div), null
        )
        sink.send(NODE_ID, 1, dec["n_sub"], dec["freq"], seq, dec["rssi"], -92, iq8,
                  ppdu_type=1, flags=1)  # HE/VHT80
        seq += 1
```

- [ ] **Step 4: Correct the null-subcarrier map and run tests**

Set `maps.MT7915_VHT80` to the true DC/guard indices for the observed `n_sub` (e.g. for 256-bin: `range(0,6) | {127,128,129} | range(251,256)`; adjust if the sample width differs). Then:

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_mt76_reader.py tests/csi_shim/test_maps.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add python/csi_shim/mt76_reader.py tests/csi_shim/test_mt76_reader.py python/csi_shim/maps.py
git commit -m "feat(csi_shim): mt76 reader decoded against captured sample (node 176)"
```

---

### Task 8: FeitCSI toolchain build + wlp1s0 bring-up

**Files:**
- Create: `scripts/build_feitcsi.sh`

**Interfaces:**
- Consumes: `/home/pi/feitcsi-build/FeitCSI` + `FeitCSI-iwlwifi` (mid-build on the Pi).
- Produces: a working `feitcsi` binary + loaded patched `iwlwifi`; `wlp1s0` up in CSI/monitor mode; a captured sample at `/tmp/feit_sample.dat` on the Pi for Task 9.

> Ops task — verified by capturing a real measurement. Runs on the Pi.

- [ ] **Step 1: Write the build/bring-up script**

```bash
# scripts/build_feitcsi.sh
#!/usr/bin/env bash
# Finish the FeitCSI build, load the patched iwlwifi, bring wlp1s0 into CSI/monitor.
# Run on the Pi. Idempotent where possible.
set -euo pipefail
B=/home/pi/feitcsi-build
echo "[1/6] build FeitCSI app"
cd "$B/FeitCSI"
[ -d build ] || meson setup build
meson compile -C build
test -x build/feitcsi && echo "feitcsi built: $B/FeitCSI/build/feitcsi"
echo "[2/6] build patched iwlwifi (backport)"
cd "$B/FeitCSI-iwlwifi"
make -j"$(nproc)"
echo "[3/6] unload stock iwlwifi, load patched"
sudo modprobe -r iwlmvm iwlwifi 2>/dev/null || true
sudo insmod ./compat/compat.ko 2>/dev/null || true
sudo insmod ./net/wireless/cfg80211.ko 2>/dev/null || true
sudo insmod ./drivers/net/wireless/intel/iwlwifi/iwlwifi.ko 2>/dev/null || true
sudo modprobe iwlmvm 2>/dev/null || true
echo "[4/6] confirm wlp1s0 present"
ip -br link show wlp1s0 || { echo "wlp1s0 missing — check driver load"; exit 1; }
echo "[5/6] bring wlp1s0 up (2.4GHz ch6 for parity with ESP32/nexmon)"
sudo ip link set wlp1s0 up || true
echo "[6/6] done — capture a sample with feitcsi (Task 9)"
```

- [ ] **Step 2: Run it on the Pi**

```bash
scp -i ~/.ssh/id_ed25519 scripts/build_feitcsi.sh pi@optaris-edge.local:/tmp/
ssh -i ~/.ssh/id_ed25519 pi@optaris-edge.local "bash /tmp/build_feitcsi.sh"
```
Expected: `feitcsi built: …/build/feitcsi`, `wlp1s0` shows `UP`. If `meson`/`make` reports a compile error, fix the build per its output before proceeding (do not skip).

- [ ] **Step 3: Capture a real FeitCSI sample**

```bash
ssh -i ~/.ssh/id_ed25519 pi@optaris-edge.local \
  "sudo timeout 15 /home/pi/feitcsi-build/FeitCSI/build/feitcsi -f 2437 -w HT20 -o /tmp/feit_sample.dat || true; ls -l /tmp/feit_sample.dat; xxd /tmp/feit_sample.dat | head"
scp -i ~/.ssh/id_ed25519 pi@optaris-edge.local:/tmp/feit_sample.dat tests/csi_shim/fixtures/feit_sample.dat
```
Expected: a non-empty `.dat` and a hex dump to characterize in Task 9. (Exact `feitcsi` flags per its `--help`; adjust `-o`/`-f`/`-w` to the real CLI.)

- [ ] **Step 4: Commit**

```bash
git add scripts/build_feitcsi.sh tests/csi_shim/fixtures/feit_sample.dat
git commit -m "chore(csi_shim): FeitCSI build/bring-up script + captured sample"
```

---

### Task 9: FeitCSI reader (decode against captured sample)

**Files:**
- Create: `python/csi_shim/feitcsi_reader.py`
- Test: `tests/csi_shim/test_feitcsi_reader.py`
- Modify: `python/csi_shim/maps.py` (`AX210_HE` from observed width)

**Interfaces:**
- Consumes: `tests/csi_shim/fixtures/feit_sample.dat` (Task 8), `scaling.*`, `maps.AX210_HE`, `sink.Adr018Sink`.
- Produces: `feitcsi_reader.decode_feit_measurement(buf:bytes) -> dict | None` returning `{"rssi":int,"freq":int,"iq":list[int],"n_sub":int,"n_ant":int}`. `feitcsi_reader.NODE_ID=210`.

> **Characterize first** from `feit_sample.dat`. FeitCSI writes its own binary measurement format (per-measurement header + complex CSI matrix). Inspect the dump and the FeitCSI file-format docs, then implement the exact struct unpack. The test asserts round-trip properties on the real fixture.

- [ ] **Step 1: Write the failing test (fixture-driven)**

```python
# tests/csi_shim/test_feitcsi_reader.py
import pathlib
from python.csi_shim import feitcsi_reader

FIX = pathlib.Path(__file__).parent / "fixtures" / "feit_sample.dat"


def test_decode_real_feit_measurement():
    buf = FIX.read_bytes()
    out = feitcsi_reader.decode_feit_measurement(buf)
    assert out is not None
    assert out["n_sub"] >= 52
    assert out["n_ant"] >= 1
    assert len(out["iq"]) == 2 * out["n_sub"] * out["n_ant"]
    assert any(v != 0 for v in out["iq"])
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_feitcsi_reader.py -v`
Expected: FAIL — `ModuleNotFoundError`

- [ ] **Step 3: Implement decoder to match the FeitCSI binary layout**

```python
# python/csi_shim/feitcsi_reader.py
"""Intel AX210 (FeitCSI) CSI -> ADR-018.

Reads FeitCSI's binary measurement format (characterized from
tests/csi_shim/fixtures/feit_sample.dat). Fill the struct fields from the observed layout.
"""
import struct

from . import maps, scaling
from .sink import Adr018Sink

NODE_ID = 210
DEFAULT_DIV = 64  # refined via calibrate_divisor against the sample

# Header layout determined from the captured .dat (offsets/sizes verified against feit_sample.dat).
# Example placeholder to be corrected to the real layout during implementation:
_HDR = struct.Struct("<HH bb HH")  # (n_sub, n_ant, rssi, noise, freq_mhz, reserved) — VERIFY


def decode_feit_measurement(buf):
    if len(buf) < _HDR.size:
        return None
    n_sub, n_ant, rssi, noise, freq, _ = _HDR.unpack_from(buf, 0)
    if n_sub == 0 or n_ant == 0:
        return None
    need = _HDR.size + n_sub * n_ant * 2 * 2  # int16 I/Q per (ant,subcarrier)
    if len(buf) < need:
        return None
    vals = struct.unpack_from("<%dh" % (n_sub * n_ant * 2), buf, _HDR.size)
    return {"rssi": rssi, "freq": freq, "iq": list(vals),
            "n_sub": n_sub, "n_ant": n_ant}


def run(source_path="/tmp/feitcsi.dat", div=DEFAULT_DIV, sink=None):  # pragma: no cover (I/O)
    sink = sink or Adr018Sink()
    null = maps.AX210_HE
    seq = 0
    # Tail the FeitCSI live output file; emit one ADR-018 frame per measurement.
    with open(source_path, "rb") as f:
        while True:
            head = f.read(_HDR.size)
            if len(head) < _HDR.size:
                continue
            n_sub, n_ant = struct.unpack_from("<HH", head, 0)[:2]
            body = f.read(n_sub * n_ant * 2 * 2)
            dec = decode_feit_measurement(head + body)
            if dec is None:
                continue
            iq8 = scaling.zero_null_subcarriers(
                scaling.scale_to_int8(dec["iq"], div), null
            )
            sink.send(NODE_ID, dec["n_ant"], dec["n_sub"], dec["freq"], seq,
                      dec["rssi"], -92, iq8, ppdu_type=1, flags=1)
            seq += 1
```

- [ ] **Step 4: Correct `_HDR`, `AX210_HE`, and run tests**

Adjust `_HDR` and `maps.AX210_HE` to the real FeitCSI layout/width observed in the dump; re-run:

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_feitcsi_reader.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add python/csi_shim/feitcsi_reader.py tests/csi_shim/test_feitcsi_reader.py python/csi_shim/maps.py
git commit -m "feat(csi_shim): FeitCSI reader decoded against captured sample (node 210)"
```

---

### Task 10: CLI entrypoint + systemd units + install script

**Files:**
- Create: `python/csi_shim/__main__.py`
- Create: `config/systemd/optaris-defense-csi-nexmon.service`
- Create: `config/systemd/optaris-defense-csi-mt76.service`
- Create: `config/systemd/optaris-defense-csi-intel.service`
- Create: `scripts/install_csi_shim.sh`
- Test: `tests/csi_shim/test_cli.py`

**Interfaces:**
- Consumes: `nexmon_reader.run`, `mt76_reader.run`, `feitcsi_reader.run`.
- Produces: `python -m python.csi_shim <nexmon|mt76|feitcsi>` dispatch; three systemd units; an idempotent installer.

- [ ] **Step 1: Write the failing test**

```python
# tests/csi_shim/test_cli.py
import subprocess, sys


def test_cli_rejects_unknown_source():
    p = subprocess.run([sys.executable, "-m", "python.csi_shim", "bogus"],
                       capture_output=True, text=True, cwd="/Users/osmanmarks/code/OptarisDefense")
    assert p.returncode == 2
    assert "nexmon" in (p.stderr + p.stdout)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_cli.py -v`
Expected: FAIL — no `__main__`, non-2 exit.

- [ ] **Step 3: Implement CLI + units + installer**

```python
# python/csi_shim/__main__.py
"""csi_shim CLI: python -m python.csi_shim <nexmon|mt76|feitcsi>"""
import argparse
import sys

from . import nexmon_reader, mt76_reader, feitcsi_reader


def main(argv=None):
    ap = argparse.ArgumentParser(prog="csi_shim")
    ap.add_argument("source", choices=["nexmon", "mt76", "feitcsi"])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=5005)
    args = ap.parse_args(argv)
    from .sink import Adr018Sink
    sink = Adr018Sink(args.host, args.port)
    {"nexmon": nexmon_reader.run,
     "mt76": mt76_reader.run,
     "feitcsi": feitcsi_reader.run}[args.source](sink=sink)


if __name__ == "__main__":
    sys.exit(main())
```

```ini
# config/systemd/optaris-defense-csi-mt76.service
[Unit]
Description=OptarisDefense CSI shim (mt76 -> ADR-018 :5005 node 176)
After=network-online.target optaris-defense-sensing.service
[Service]
ExecStart=/usr/bin/python3 -m python.csi_shim mt76
WorkingDirectory=/home/pi/OptarisDefense
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
```

```ini
# config/systemd/optaris-defense-csi-nexmon.service
[Unit]
Description=OptarisDefense CSI shim (nexmon -> ADR-018 :5005 node 200)
After=network-online.target optaris-defense-sensing.service
[Service]
ExecStartPre=/home/pi/nexmon_csi_start_setup.sh
ExecStart=/usr/bin/python3 -m python.csi_shim nexmon
WorkingDirectory=/home/pi/OptarisDefense
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
```

```ini
# config/systemd/optaris-defense-csi-intel.service
[Unit]
Description=OptarisDefense CSI shim (feitcsi -> ADR-018 :5005 node 210)
After=network-online.target optaris-defense-sensing.service
[Service]
ExecStart=/usr/bin/python3 -m python.csi_shim feitcsi
WorkingDirectory=/home/pi/OptarisDefense
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
```

```bash
# scripts/install_csi_shim.sh
#!/usr/bin/env bash
# Install csi_shim systemd units on the Pi. Idempotent.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)/config/systemd"
for u in optaris-defense-csi-nexmon optaris-defense-csi-mt76 optaris-defense-csi-intel; do
  sudo install -m0644 "$SRC/$u.service" "/etc/systemd/system/$u.service"
done
sudo systemctl daemon-reload
echo "Installed. Enable per source, e.g.: sudo systemctl enable --now optaris-defense-csi-mt76"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/osmanmarks/code/OptarisDefense && python -m pytest tests/csi_shim/test_cli.py -v && chmod +x scripts/install_csi_shim.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add python/csi_shim/__main__.py config/systemd/optaris-defense-csi-*.service scripts/install_csi_shim.sh tests/csi_shim/test_cli.py
git commit -m "feat(csi_shim): CLI dispatch + systemd units + installer"
```

---

### Task 11: End-to-end verification on the Pi

**Files:**
- Create: `tests/csi_shim/README.md` (verification runbook)

**Interfaces:**
- Consumes: everything above; a live sensing-server on `:5005` and `/api/v1/nodes`.
- Produces: documented evidence all four sources appear as nodes.

> No unit test — this is the acceptance gate. Deploy the package to the Pi, install/enable the units, and confirm nodes 176/200/210 (plus native 2/5) appear.

- [ ] **Step 1: Deploy package + install units on the Pi**

```bash
rsync -az -e "ssh -i ~/.ssh/id_ed25519" python/csi_shim/ pi@optaris-edge.local:/home/pi/OptarisDefense/python/csi_shim/
ssh -i ~/.ssh/id_ed25519 pi@optaris-edge.local "cd /home/pi/OptarisDefense && bash scripts/install_csi_shim.sh"
```
Expected: "Installed."

- [ ] **Step 2: Enable each source and check frames on :5005**

```bash
ssh -i ~/.ssh/id_ed25519 pi@optaris-edge.local \
  "sudo systemctl enable --now optaris-defense-csi-nexmon optaris-defense-csi-mt76 optaris-defense-csi-intel; sleep 5; \
   sudo timeout 6 tcpdump -ni any udp port 5005 -c 20 2>/dev/null | grep -c UDP"
```
Expected: a non-zero packet count.

- [ ] **Step 3: Confirm nodes in the sensing API**

```bash
ssh -i ~/.ssh/id_ed25519 pi@optaris-edge.local \
  "curl -s http://127.0.0.1:8080/api/v1/nodes | python3 -m json.tool"
```
Expected: entries for node_id 2, 5 (ESP32), 200 (nexmon), 176 (mt76), 210 (intel) — those whose toolchains are live. Record which appear.

- [ ] **Step 4: Write the runbook and commit**

Write `tests/csi_shim/README.md` capturing the three commands above, the expected node_ids, and the per-source `DIV`/null-map values finalized during Tasks 5/7/9. Then:

```bash
git add tests/csi_shim/README.md
git commit -m "docs(csi_shim): end-to-end verification runbook"
```

---

## Notes for the executor

- **node_id / DIV / null-map values** for mt76 and feitcsi are finalized against captured samples in Tasks 7 and 9 — do not guess; use the real bytes.
- If a captured sample can't be obtained (toolchain still failing), stop and report — do **not** fabricate a fixture. The core (Tasks 1–5) and nexmon path do not depend on captures and can land independently.
- BFI (`--source bfi`, second server instance) is explicitly out of scope for this plan.
