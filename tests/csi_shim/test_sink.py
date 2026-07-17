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
