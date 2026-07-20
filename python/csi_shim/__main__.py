"""csi_shim CLI: python -m python.csi_shim <nexmon|feitcsi>"""
import argparse
import sys
import importlib


def main(argv=None):
    ap = argparse.ArgumentParser(prog="csi_shim")
    ap.add_argument("source", choices=["nexmon", "feitcsi"])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=5005)
    args = ap.parse_args(argv)
    from .sink import Adr018Sink
    sink = Adr018Sink(args.host, args.port)
    reader = importlib.import_module(f".{args.source}_reader", __package__)
    reader.run(sink=sink)


if __name__ == "__main__":
    sys.exit(main())
