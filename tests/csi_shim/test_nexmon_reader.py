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
