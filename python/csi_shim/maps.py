"""Per-chip null/guard/pilot subcarrier indices to zero before ingest.

nexmon: verified from nexmon_bridge.py (bcm43455c0 HT20, 64-bin).
mt76 / feitcsi: initial values from the 802.11 VHT80 / HE subcarrier allocation;
corrected against a captured sample during the mt76 (Task 7) and feitcsi (Task 10) tasks.
"""

# 802.11n HT20, 64-bin: DC + guard/null carriers (no temporal signal).
NEXMON_BCM43455C0_HT20 = frozenset([0, 1, 2, 3, 32, 61, 62, 63])

# 802.11ac VHT80, 256-bin: DC (127,128,129) + band-edge guards. Refined in Task 7.
MT7915_VHT80 = frozenset(
    list(range(0, 6)) + [127, 128, 129] + list(range(251, 256))
)

# 802.11ax HE: DC + guards. Refined in Task 10 once FeitCSI width is observed.
AX210_HE = frozenset()

_BY_CHIP = {
    "nexmon": NEXMON_BCM43455C0_HT20,
    "mt76": MT7915_VHT80,
    "feitcsi": AX210_HE,
}


def for_chip(name):
    return _BY_CHIP.get(name, frozenset())
