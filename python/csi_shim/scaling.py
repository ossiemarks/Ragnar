"""Fixed-divisor int->int8 scaling and null-subcarrier zeroing (shared by all readers)."""


def scale_to_int8(iq_ints, div):
    if div < 1:
        div = 1
    out = bytearray(len(iq_ints))
    for i, v in enumerate(iq_ints):
        q = v // div
        if q > 127:
            q = 127
        elif q < -127:
            q = -127
        out[i] = q & 0xFF
    return bytes(out)


def zero_null_subcarriers(iq_int8, null_set):
    b = bytearray(iq_int8)
    for k in null_set:
        i = 2 * k
        if i + 1 < len(b):
            b[i] = 0
            b[i + 1] = 0
    return bytes(b)


def calibrate_divisor(magnitudes, target=127, pct=99):
    if not magnitudes:
        return 1
    s = sorted(abs(v) for v in magnitudes)
    idx = min(len(s) - 1, (len(s) * pct) // 100)
    p = s[idx] or 1
    return max(1, round(p / target))
