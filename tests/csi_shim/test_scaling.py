from python.csi_shim import scaling


def test_scale_floor_divides_and_clamps():
    out = scaling.scale_to_int8([300, -300, 16, -16], div=16)
    assert list(out) == [18, (-19) & 0xFF, 1, (-1) & 0xFF]


def test_zero_null_subcarriers():
    iq = bytes([9] * 8)  # 4 subcarriers
    out = scaling.zero_null_subcarriers(iq, frozenset([0, 3]))
    assert list(out) == [0, 0, 9, 9, 9, 9, 0, 0]


def test_calibrate_divisor_maps_p99_to_target():
    mags = list(range(1, 101))  # p99 ~= 99
    assert scaling.calibrate_divisor(mags, target=127, pct=99) == 1
    big = [1000] * 100
    assert scaling.calibrate_divisor(big, target=127, pct=99) == round(1000 / 127)


def test_scale_clamps_extremes():
    out = scaling.scale_to_int8([5000, -5000], div=1)
    assert list(out) == [127, (-127) & 0xFF]
