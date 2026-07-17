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
