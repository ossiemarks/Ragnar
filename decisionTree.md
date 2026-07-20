# Decision Tree — Passive Ambient WiFi Sensing

A running log of the architectural decisions for using the *other* WiFi devices in the
area (devices we don't own/control) as an additional, passive sensing source that
augments the dedicated RuSense nodes (ESP32, AX210/node 210, Pi Nexmon/node 200).

Status: **brainstorming** (design not yet finalized). Chosen paths marked ✅; alternatives
kept for the record.

---

## D1 — Goal
Augment the existing RuSense system, running *alongside* the dedicated nodes.
- ✅ **Coverage** — sense the wider space without deploying nodes everywhere.
- ✅ **Fidelity/accuracy** — fuse more signal for better people-count / localization.
- ✅ **Research/exploration** — see what's extractable from ambient RF.
- ➖ Fully-passive / zero-footprint — *not* a priority (may coexist with active nodes).

## D2 — Capture technique
- ✅ **Both, phased**: **BFI sniffing** first (breadth — beamforming-feedback frames every
  802.11ac/ax device sends its AP, ingested by `sensing-server --source bfi`), then
  **passive CSI harvesting** (full CSI extracted from overheard frames) for fidelity.
- ↔ Alternative: BFI-only (fastest, coarser). *Rejected — loses fidelity path.*
- ↔ Alternative: passive-CSI-only (richest, most work, per-channel). *Rejected — loses breadth.*

## D3 — Spectrum coverage
- ✅ **Multi-radio, each parked on a band/channel** for maximum simultaneous device coverage.
- ✅ **Add a dedicated USB WiFi monitor adapter** so the production nodes (AX210/node 210,
  Pi Nexmon) keep running untouched (no time-sharing the AX210).
- ↔ Alternative: single busy channel parked (simplest, fewest devices). *Not chosen.*
- ↔ Alternative: channel-hop survey on one radio (census, intermittent per device). *May be
  added as a periodic full-spectrum census on top.*

## D4 — Integration with the sensing engine
Ambient devices are **positionless and transient**, unlike the fixed, position-mapped
dedicated nodes.
- ✅ **Approach 1 — Separate "ambient" instance, aggregate at the top.** Passive capture
  feeds its own `sensing-server` instance(s) producing an independent ambient presence/motion
  layer; combined with the dedicated-node output at the UI / `mirror` layer. Keeps the clean
  fixed-node fusion pristine; purely additive.
- ↔ **Approach 2 — Inject passive sources as ADR-018 nodes into the existing fan-out**
  (`:5005` → OptarisSense + Ragnar). Single unified engine/dashboard, BUT positionless,
  flapping ambient nodes would degrade the fixed-node fusion (people-count/localization)
  unless heavily gated. *Noted; not chosen — risks the accuracy just achieved.*
- ↔ **Approach 3 — Hybrid.** Only the *strong, stable* passive-CSI links get injected as
  real nodes (Approach 2), while broad BFI stays a separate ambient layer (Approach 1).
  *Noted as the evolution target once passive-CSI matures and we learn which ambient links
  are stable enough to trust.*

---

## Open items (still to decide in brainstorming)
- USB adapter model(s) — BFI needs only monitor mode (any adapter); passive-CSI needs a
  CSI-extraction-capable chip (ath9k/Atheros, Nexmon-compatible, or Intel-AX via FeitCSI).
- Channel/band assignment across the available radios (USB adapter + GL-MT3000 monitor mode).
- BFI capture → decode → `--bfi-pcap` feed pipeline, and the ambient instance's ports.
- How the ambient layer is surfaced/aggregated in the UI.
