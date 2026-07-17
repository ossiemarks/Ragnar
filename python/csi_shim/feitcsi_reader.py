"""Intel AX210 (FeitCSI) CSI -> ADR-018.

FeitCSI's "measure" output (see src/Csi.cpp::save() / include/Csi.h in the
KuskoSoft/FeitCSI project) is a flat back-to-back sequence of records, each:

  272-byte packed RawHeaderData header, then `csiDataSize` raw bytes of
  little-endian int16 (I, Q) pairs, one pair per (rx-antenna, subcarrier),
  antenna-major (all subcarriers for antenna 0, then all subcarriers for
  antenna 1, ...).

RawHeaderData (include/Csi.h, CSI_HEADER_LENGTH = 272, __attribute__((packed))):
    u32 csiDataSize;                # offset 0
    u32 space4; u32 ftmClock;       # offset 4, 8   (unused here)
    u64 timestamp;                  # offset 12     (0 for measure-to-file path)
    u8  space20[26];                # offset 20
    u8  numRx; u8 numTx;            # offset 46, 47
    u8  space48[4];                 # offset 48
    u32 numSubCarriers;             # offset 52
    u8  space54[4];                 # offset 56
    u32 rssi1; u32 rssi2;           # offset 60, 64 (per-rx-chain, raw magnitude)
    u8  srcMac[6];                  # offset 68
    u8  space75[18];                # offset 74
    u32 rateNflag;                  # offset 92     (encodes format + chan width)
    u32 space96[44];                # offset 96..271

Verified byte-for-byte against tests/csi_shim/fixtures/feit_sample.dat (a real
`feitcsi -i measure -f 2462 -r NOHT -w 20` capture, see
.superpowers/sdd/task-8-report.md and task-9-report.md): every one of the
3696 records in the fixture decodes with numRx=2, numTx=1,
numSubCarriers=52, csiDataSize=416 (=52*4*2), format=LEGACY_OFDM,
channel width=20 -- matching the capture command exactly, and the header
bytes account for the entire 2,542,848-byte file with zero leftover.

Frequency is a capture-session parameter, not part of the per-record
struct, so it isn't decoded from `buf` -- it's supplied by the caller
(defaults to the fixture's known capture channel).
"""
import struct

from . import maps, scaling
from .sink import Adr018Sink

NODE_ID = 210

# Capture channel used for tests/csi_shim/fixtures/feit_sample.dat
# (feitcsi -i measure -f 2462 -r NOHT -w 20); RawHeaderData carries no
# frequency field of its own.
FREQ_MHZ = 2462
NOISE = -92

# Calibrated with scaling.calibrate_divisor() against the real I/Q values in
# feit_sample.dat (500-record sample, target=127, pct=99).
DEFAULT_DIV = 2

_HDR = struct.Struct("<I16x26xBB4xI4xII6x18xI176x")

_MOD_TYPE_POS = 8
_MOD_TYPE_MSK = 0x7 << _MOD_TYPE_POS
_CHAN_WIDTH_POS = 11
_CHAN_WIDTH_MSK = 0x7 << _CHAN_WIDTH_POS


def decode_feit_measurement(buf, freq_mhz=FREQ_MHZ):
    if len(buf) < _HDR.size:
        return None
    csi_data_size, num_rx, num_tx, n_sub, rssi1, rssi2, _rate_nflag = _HDR.unpack_from(buf, 0)
    if n_sub == 0 or num_rx == 0 or csi_data_size == 0 or csi_data_size % 2:
        return None
    if len(buf) < _HDR.size + csi_data_size:
        return None
    n_ant = num_rx * max(num_tx, 1)
    count = csi_data_size // 2
    if count != 2 * n_sub * n_ant:
        return None
    vals = struct.unpack_from("<%dh" % count, buf, _HDR.size)
    chains = [rssi1, rssi2][: max(1, min(num_rx, 2))]
    rssi = -round(sum(chains) / len(chains))
    return {
        "rssi": rssi,
        "freq": freq_mhz,
        "iq": list(vals),
        "n_sub": n_sub,
        "n_ant": n_ant,
    }


def run(source_path="/tmp/feit_sample.dat", div=DEFAULT_DIV, freq_mhz=FREQ_MHZ, sink=None):  # pragma: no cover (I/O loop)
    sink = sink or Adr018Sink()
    null = maps.AX210_HE
    seq = 0
    with open(source_path, "rb") as f:
        while True:
            head = f.read(_HDR.size)
            if len(head) < _HDR.size:
                continue
            csi_data_size = struct.unpack_from("<I", head, 0)[0]
            body = f.read(csi_data_size)
            dec = decode_feit_measurement(head + body, freq_mhz=freq_mhz)
            if dec is None:
                continue
            iq8 = scaling.zero_null_subcarriers(
                scaling.scale_to_int8(dec["iq"], div), null
            )
            sink.send(NODE_ID, dec["n_ant"], dec["n_sub"], dec["freq"], seq,
                      dec["rssi"], NOISE, iq8, ppdu_type=0, flags=0)
            seq += 1
