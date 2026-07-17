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

# feitcsi/AX210, 52-subcarrier width (observed capture: legacy-OFDM 20MHz,
# `feitcsi -i measure -f 2462 -r NOHT -w 20`, see task-9-report.md). Verified
# empirically against tests/csi_shim/fixtures/feit_sample.dat (3696 real
# records, all 52 subcarriers, both RX chains): every one of the 52 reported
# subcarrier positions carries nonzero signal in 100% of records, with no
# near-zero/DC pattern anywhere in the array. FeitCSI's firmware/driver
# already strips the DC and guard-band bins before delivering CSI to
# userspace (RawHeaderData.numSubCarriers=52 is the used-tone count, not the
# raw 64-bin FFT width), so there are no null subcarriers left to mask here.
AX210_HE = frozenset()

_BY_CHIP = {
    "nexmon": NEXMON_BCM43455C0_HT20,
    "mt76": MT7915_VHT80,
    "feitcsi": AX210_HE,
}


def for_chip(name):
    return _BY_CHIP.get(name, frozenset())
