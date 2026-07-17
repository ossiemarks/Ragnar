#!/usr/bin/env bash
# Build FeitCSI + its patched iwlwifi backport, load the patched driver, and
# bring wlp1s0 up on the Intel AX210 for CSI capture. Run on the Pi
# (optaris-edge). Idempotent where possible.
#
# Throttling: this Pi has weak cooling and a marginal PSU. Builds default to
# -j2 (override with JOBS=1 for a further-throttled build) and the script
# pauses between build stages if the SoC temperature is at/above 84C.
set -euo pipefail

B=/home/pi/feitcsi-build
JOBS=${JOBS:-2}
TEMP_PAUSE_C=84
TEMP_RESUME_C=70

log() { echo "[build_feitcsi] $*"; }

get_temp_c() {
    # vcgencmd prints "temp=NN.N'C"; extract the integer part.
    sudo vcgencmd measure_temp 2>/dev/null | sed -E "s/temp=([0-9]+).*/\1/"
}

wait_for_cooldown() {
    local t
    t=$(get_temp_c || echo 0)
    if [ -z "$t" ]; then
        return 0
    fi
    if [ "$t" -ge "$TEMP_PAUSE_C" ]; then
        log "SoC at ${t}C >= ${TEMP_PAUSE_C}C, pausing build to cool down..."
        while [ "$t" -gt "$TEMP_RESUME_C" ]; do
            sleep 15
            t=$(get_temp_c || echo 0)
            log "  cooling: ${t}C (resume threshold ${TEMP_RESUME_C}C)"
        done
        log "cooled to ${t}C, resuming"
    fi
}

log "temp check before starting: $(sudo vcgencmd measure_temp 2>/dev/null || echo unknown)"
wait_for_cooldown

log "[1/6] build FeitCSI app (JOBS=$JOBS)"
cd "$B/FeitCSI"
# A previous interrupted build can leave zero-byte .o files behind, which
# make treats as up to date and then fails to link (undefined references).
# Purge any empty object files so they get recompiled.
find obj -name '*.o' -size 0 -print -delete 2>/dev/null || true
rm -f bin/app
make -j"$JOBS"
test -s bin/app && echo "feitcsi built: $B/FeitCSI/bin/app"
sudo make install
command -v feitcsi >/dev/null && echo "feitcsi installed: $(command -v feitcsi)"

wait_for_cooldown

log "[2/6] build patched iwlwifi backport (JOBS=$JOBS)"
cd "$B/FeitCSI-iwlwifi"
MAC80211_C=drivers/net/wireless/intel/iwlwifi/mld/mac80211.c
# Upstream FeitCSI's mld/mac80211.c calls iwl_mld_no_wowlan_suspend()
# unconditionally in iwl_mld_mac80211_stop(), but that function (and the
# struct fields it touches) only compiles under CONFIG_PM_SLEEP, per
# mld/Makefile's `iwlmld-$(CONFIG_PM_SLEEP) += d3.o` and the #ifdef guards
# in mld.h/iface.h. Raspberry Pi kernels ship with CONFIG_SUSPEND and
# CONFIG_HIBERNATION unset (so CONFIG_PM_SLEEP is unset too), which leaves
# this one call site as a dangling undefined symbol at link time. Every
# other call site in the same file (iwl_mld_mac80211_start, iwl_mld_suspend,
# iwl_mld_resume, the wowlan ops registration) already has the
# `#ifdef CONFIG_PM_SLEEP` guard - this patches the one that's missing it,
# to match the established pattern.
if [ -f "$MAC80211_C" ]; then
    python3 - "$MAC80211_C" <<'EOF'
import sys
p = sys.argv[1]
with open(p) as f:
    lines = f.readlines()
target = '\tif (!suspend || iwl_mld_no_wowlan_suspend(mld))\n'
idx = None
for i, l in enumerate(lines):
    if l == target:
        idx = i
        break
if idx is None:
    # Already patched (line only exists unguarded) or upstream changed;
    # nothing to do.
    sys.exit(0)
if idx > 0 and lines[idx - 1] == '#ifdef CONFIG_PM_SLEEP\n':
    # Already guarded on a previous run of this script; idempotent no-op.
    sys.exit(0)
assert lines[idx + 1] == '\t\tiwl_mld_stop_fw(mld);\n', repr(lines[idx + 1])
new_block = (
    '#ifdef CONFIG_PM_SLEEP\n'
    '\tif (!suspend || iwl_mld_no_wowlan_suspend(mld))\n'
    '\t\tiwl_mld_stop_fw(mld);\n'
    '#else\n'
    '\tiwl_mld_stop_fw(mld);\n'
    '#endif /* CONFIG_PM_SLEEP */\n'
)
lines[idx:idx + 2] = [new_block]
with open(p, 'w') as f:
    f.writelines(lines)
print('patched CONFIG_PM_SLEEP guard in ' + p)
EOF
fi
make -j"$JOBS"
find . -name '*.ko' | sort

wait_for_cooldown

log "[3/6] unload stock iwlwifi/iwlmvm and any driver holding cfg80211"
sudo ip link set wlp1s0 down 2>/dev/null || true
sudo modprobe -r iwlmvm iwlwifi 2>/dev/null || true
# The backport's iwlwifi.ko/iwlmvm.ko are linked against this build's own
# cfg80211.ko/mac80211.ko/compat.ko (matching MODVERSIONS symbol CRCs), so
# the stock cfg80211 module must be freed before we can insmod ours. On
# this Pi that means unloading the onboard Broadcom stack (brcmfmac), which
# is otherwise unrelated to the sensing-server / ESP32 CSI pipeline (that
# listens over UDP, not via the local WiFi NIC) and is reloaded further
# down so it ends up in the same state it started in.
sudo modprobe -r brcmfmac_wcc brcmfmac brcmutil cfg80211 2>/dev/null || true

log "[4/6] load patched compat/cfg80211/mac80211/iwlwifi/iwlmvm"
cd "$B/FeitCSI-iwlwifi"
sudo insmod ./compat/compat.ko 2>/dev/null || true
# udev can auto-reload the stock cfg80211 module the instant it's removed;
# retry the swap a couple of times if insmod reports it already exists.
for _ in 1 2 3; do
    if sudo insmod ./net/wireless/cfg80211.ko 2>/dev/null; then
        break
    fi
    sudo rmmod cfg80211 2>/dev/null || true
done
sudo insmod ./net/mac80211/mac80211.ko 2>/dev/null || true
sudo insmod ./drivers/net/wireless/intel/iwlwifi/iwlwifi.ko
sudo insmod ./drivers/net/wireless/intel/iwlwifi/mvm/iwlmvm.ko
lsmod | grep -E 'iwlmvm|iwlwifi|mac80211|cfg80211|compat'

log "[5/6] restore onboard Broadcom radio (unrelated to the swap above)"
sudo modprobe brcmfmac 2>/dev/null || true

log "[6/6] confirm wlp1s0 and bring it up (2.4GHz ch6 for parity with ESP32/nexmon)"
sleep 2
ip -br link show wlp1s0 || { echo "wlp1s0 missing - check driver load"; exit 1; }
sudo ip link set wlp1s0 up
# FeitCSI sets its own frequency/channel width per-run via netlink, so this
# is best-effort parity only and not required for a capture to work.
sudo iw dev wlp1s0 set channel 6 2>/dev/null || true
ip -br link show wlp1s0
log "done - temp now: $(sudo vcgencmd measure_temp 2>/dev/null || echo unknown)"
log "capture a sample with feitcsi, e.g.:"
log "  sudo timeout -s INT 15 feitcsi -i measure -f 2437 -r HT -w 20 -o /tmp/feit_sample.dat -v"
log "(use SIGINT/-s INT, not the default SIGTERM: feitcsi only flushes its output file on SIGINT)"
