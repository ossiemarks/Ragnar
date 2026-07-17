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
