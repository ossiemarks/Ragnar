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
