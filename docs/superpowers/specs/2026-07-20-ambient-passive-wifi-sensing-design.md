# Ambient Passive WiFi Sensing — Design

**Date:** 2026-07-20
**Decision log:** [`decisionTree.md`](../../../decisionTree.md) (D1–D4)
**Relationship:** Augments the existing RuSense stack (dedicated ESP32 / AX210-node-210 /
Pi-Nexmon-node-200 nodes on the fan-out `:5005` → OptarisSense `:5105` + Ragnar `:5006`).
This layer is **additive and isolated** — it never touches that pipeline.

## Goal

Use the *other* WiFi devices in the area (devices we don't own — neighbours' phones, TVs,
APs) as a passive sensing source, to add **coverage**, improve **accuracy**, and enable
**exploration**, running alongside the dedicated nodes. Fully-passive purity is not a goal.

## Approach (D4 = Approach 1)

Passive capture feeds its **own** `sensing-server` instance producing an independent
"ambient activity" presence/motion layer, aggregated with the dedicated-node output at the
UI/`mirror` layer. This keeps the fixed-node fusion (people-count/localization) pristine —
positionless, transient ambient sources never pollute it. Alternatives 2 (inject as nodes)
and 3 (hybrid) are recorded in `decisionTree.md` as the evolution target once passive-CSI
matures.

## Technique (D2 = both, phased)

- **Phase 1 — BFI sniffing (breadth):** monitor-mode capture of the beamforming-feedback
  action frames every 802.11ac/ax device sends its AP (VHT/HE compressed beamforming reports;
  unencrypted at the MAC layer, so capturable). Fed to `sensing-server --source bfi`.
- **Phase 2 — Passive CSI harvesting (fidelity):** extract full CSI from overheard frames on
  the busiest channels; normalize strong stable links toward the `csi_shim`/ADR-018 path
  (this is where Approach 3 begins). Deferred to a later spec.

This spec covers **Phase 1 (BFI)**.

## Spectrum coverage (D3)

Multi-radio, each parked on a band/channel, with the dedicated production radios untouched:
- **New USB monitor adapter** parked on the busiest **5 GHz** channel (most AX beamforming).
- **GL-MT3000 in monitor mode** parked on **2.4 GHz** (its CSI build is broken/parked, but
  plain monitor-mode capture works fine).
- **6 GHz** deferred (needs a rare 6E monitor adapter).
- Optional later: one radio channel-hops for a periodic full-spectrum census.

**Hardware:** BFI needs only monitor mode → a dual-band `mt76` USB adapter (e.g. Alfa
AWUS036ACM). Phase 2 passive-CSI will want a CSI-capable chip (ath9k/Atheros CSI Tool, or
Nexmon-compatible).

## Architecture

```
Ambient AX/AC devices ──beamforming feedback──▶ [USB mon adapter (5GHz) ‖ GL-MT3000 mon (2.4GHz)]
                                                          │ rolling monitor pcap
                                                          ▼
                                              [bfi-capture feed]  ──▶  sensing-server --source bfi
                                                                        (HTTP :8081, WS :8766)
                                                                                │
                                                                                ▼
                                                            ambient presence/motion  ──▶ UI / mirror aggregate
UNTOUCHED: dedicated nodes → fan-out :5005 → OptarisSense :5105 + Ragnar :5006
```

### Components (isolated, testable)
1. **Monitor-mode capture** — reuses the existing `wifiwatch-setup-mon.sh` pattern to put each
   adapter into stable RX-only monitor mode on its assigned channel; captures beamforming-
   feedback action frames to a rolling, size-bounded pcap.
2. **BFI capture→feed** — supplies the captured frames to the bfi instance in whatever form
   `--bfi-pcap` requires (see Open Question O1).
3. **Ambient `sensing-server --source bfi`** — a separate 3rd instance on `:8081`/`:8766`
   (distinct from OptarisSense `:8080`/`:8765` and Ragnar). Produces the ambient layer.
4. **Aggregation** — surface ambient + dedicated together (UI overlay, or the engine's
   `mirror` source which is built to combine instances).

## Open question to resolve first (implementation task 1)

**O1 — what does `--bfi-pcap` actually ingest?** The server help says it "replays *decoded*
Beamforming Feedback Information reports from a `.pcap`/`.pcapng`." Determine empirically
whether it accepts a **raw monitor-mode pcap** (server decodes BFI itself) or **pre-decoded
BFI reports** (we must write a decoder that extracts the VHT/HE compressed beamforming report
— φ/ψ angles — from each action frame). This decides whether Phase 1 needs a custom BFI
decoder or is capture-and-feed only. Characterize against a real captured pcap before writing
the feed (same "verify the real format first" discipline used for the CSI readers).

## Error handling
- Monitor-mode reset resilience (the `wifiwatch` pattern — re-assert monitor mode on failure).
- Rolling pcap rotation with a bounded disk cap (do not fill the SD — the Pi is storage- and
  power-constrained).
- Channel-set retries; skip/log malformed frames; the ambient instance restarts on failure
  (systemd `Restart=on-failure`), independent of the production stack.
- Do not run on the AX210 or the production nodes' radios (keep them free).

## Testing
- **Capture check:** confirm the monitor adapter actually captures beamforming-feedback action
  frames in the environment (count VHT/HE compressed-beamforming frames over a window).
- **Ingest check:** feed a real captured pcap to the bfi instance; confirm it produces
  presence/motion output on `:8081`.
- **Walk test:** movement in the ambient-covered area registers on the ambient layer while the
  dedicated-node layer is unaffected.

## Feasibility caveats (honest)
- BFI only appears when devices are actively **beamforming** (AX/AC + MU/SU) — density varies;
  expect coverage gaps, this is opportunistic not guaranteed.
- 6 GHz beamforming capture needs a 6E monitor adapter (deferred).
- Passive monitoring of others' RF metadata carries **privacy/authorization** responsibilities;
  assume own/authorized space.
- The Pi is power/thermally marginal — the ambient instance + capture add sustained load; size
  it modestly and keep it off the AX210.

## Out of scope (this spec)
- Phase 2 passive-CSI harvesting and Approach-3 node injection (own later spec).
- 6 GHz coverage.
- Localizing ambient devices (they're positionless by nature).
