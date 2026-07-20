#!/usr/bin/env python3
# UDP CSI fan-out: receive on :5005, duplicate each datagram to OptarisSense + Ragnar sensing.
import socket, os
LISTEN = ("0.0.0.0", int(os.environ.get("FANOUT_LISTEN_PORT", "5005")))
TARGETS = [("127.0.0.1", int(p)) for p in os.environ.get("FANOUT_TARGETS", "5105,5006").split(",")]
rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
rx.bind(LISTEN)
tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
print("csi-fanout %s -> %s" % (LISTEN, TARGETS), flush=True)
while True:
    data, _ = rx.recvfrom(65535)
    for t in TARGETS:
        try: tx.sendto(data, t)
        except OSError: pass
