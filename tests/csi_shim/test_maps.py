from python.csi_shim import maps


def test_nexmon_ht20_map_matches_reference_bridge():
    assert maps.NEXMON_BCM43455C0_HT20 == frozenset([0, 1, 2, 3, 32, 61, 62, 63])


def test_for_chip_dispatch():
    assert maps.for_chip("nexmon") == maps.NEXMON_BCM43455C0_HT20
    assert maps.for_chip("mt76") == maps.MT7915_VHT80
    assert maps.for_chip("feitcsi") == maps.AX210_HE


def test_unknown_chip_returns_empty():
    assert maps.for_chip("nope") == frozenset()
