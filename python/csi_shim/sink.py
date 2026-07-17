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
