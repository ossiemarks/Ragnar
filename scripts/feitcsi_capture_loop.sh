#!/usr/bin/env bash
# Continuous feitcsi capture loop for node 210 (Intel AX210 / FeitCSI).
#
# FeitCSI only flushes its -o file to disk on SIGINT, and it truncates
# whatever -o FILE points at on every invocation -- it does not append (see
# tests/csi_shim/README.md section 3a). feitcsi_reader.run() opens its
# source file once and tails it forward from a saved byte offset, so a
# single long-running "feitcsi -o FILE" process gives it nothing until
# killed, and a second feitcsi invocation against the same path would
# truncate the file out from under the reader's open fd.
#
# This loop works around that: capture short SIGINT-bounded bursts to a
# scratch file, then append each burst onto the reader's growing target
# file, so the target only ever grows and the reader always sees new
# records without ever losing its place.
#
# Requires the patched iwlwifi driver loaded and wlp1s0 up on the target
# channel (see scripts/build_feitcsi.sh, steps 3-6). Driver/interface
# bring-up is intentionally NOT done by this script -- reloading kernel
# modules on every (re)start of a Restart=on-failure service is unsafe;
# bring the interface up once, out of band, before starting this loop.
set -euo pipefail

TARGET=${FEITCSI_TARGET:-/tmp/feit_sample.dat}
SCRATCH=${FEITCSI_SCRATCH:-/tmp/feit_burst.dat}
BURST_SEC=${FEITCSI_BURST_SEC:-6}
GAP_SEC=${FEITCSI_GAP_SEC:-1}
FREQ_MHZ=${FEITCSI_FREQ_MHZ:-2462}
TEMP_PAUSE_C=84
TEMP_RESUME_C=70

log() { echo "[feitcsi_capture_loop] $*"; }

get_temp_c() {
    vcgencmd measure_temp 2>/dev/null | sed -E "s/temp=([0-9]+).*/\1/"
}

wait_for_cooldown() {
    local t
    t=$(get_temp_c || echo 0)
    if [ -n "$t" ] && [ "$t" -ge "$TEMP_PAUSE_C" ]; then
        log "SoC at ${t}C >= ${TEMP_PAUSE_C}C, pausing capture to cool down..."
        while [ "$t" -gt "$TEMP_RESUME_C" ]; do
            sleep 15
            t=$(get_temp_c || echo 0)
            log "  cooling: ${t}C (resume threshold ${TEMP_RESUME_C}C)"
        done
        log "cooled to ${t}C, resuming"
    fi
}

: > "$TARGET"
log "target=$TARGET burst=${BURST_SEC}s gap=${GAP_SEC}s freq=${FREQ_MHZ}MHz"

while true; do
    wait_for_cooldown
    timeout -s INT "$BURST_SEC" feitcsi -i measure -f "$FREQ_MHZ" -r NOHT -w 20 -o "$SCRATCH" >/dev/null 2>&1 || true
    if [ -s "$SCRATCH" ]; then
        cat "$SCRATCH" >> "$TARGET"
    fi
    sleep "$GAP_SEC"
done
