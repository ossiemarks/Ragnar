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
    assert -100 <= out["rssi"] <= 0


def test_decode_matches_known_capture_params():
    # tests/csi_shim/fixtures/feit_sample.dat was captured with:
    #   feitcsi -i measure -f 2462 -r NOHT -w 20
    # (see .superpowers/sdd/task-8-report.md) -> 52-subcarrier legacy-OFDM,
    # 2 RX chains, 1 TX chain.
    buf = FIX.read_bytes()
    out = feitcsi_reader.decode_feit_measurement(buf)
    assert out["n_sub"] == 52
    assert out["n_ant"] == 2
    assert out["freq"] == 2462


def test_decode_short_buffer_returns_none():
    assert feitcsi_reader.decode_feit_measurement(b"") is None
    assert feitcsi_reader.decode_feit_measurement(b"\x00" * 10) is None


def test_node_id_is_210():
    assert feitcsi_reader.NODE_ID == 210
