# SD_CARD.md — optaris-edge Pi recovery + state handoff

**Purpose:** shared state so recovery can continue on another machine (e.g. a Linux laptop).
**Date opened:** 2026-07-20. **Status:** ext4 root REPAIRED & clean — card ejected, ready to reinsert in the Pi and boot.

> No secrets in this file. Pi/router credentials live in Secrets Manager
> (`optaris/pi/*`, `optaris/router/gl-mt3000-admin`, `optaris/wifi/gl-mt3000-62`).

---

## 0. Repair log (what's been done)

**2026-07-20 — Linux laptop, card as `/dev/sdb` (sdb1 vfat `system-boot`, sdb2 ext4 root):**

- Unmounted both partitions (step 2). ✅
- `e2fsck -f -y /dev/sdb2` (step 3): recovered journal; fixed multiply-claimed blocks
  (inodes 1043095/1082264), 4 over-long extent trees, several directory-checksum failures,
  and wrong free-inode/dir counts across groups 16/132/144. **Re-run returned exit 0 = clean.** ✅
- `fsck.vfat -a -w /dev/sdb1` (step 4): removed the dirty bit. Boot-sector/backup byte diff at
  offset 65 is harmless and left untouched. ✅
- Both remounted r/w clean (no "mounting fs with errors", no ro-remount), then `sync` +
  `udisksctl power-off` for safe removal.

**Next (steps 5→): reinsert card in the Pi (on the UPS), boot, then finish the interrupted
Ragnar `apt` install remotely (§3 fallback + §4).** No `badblocks` needed — corruption traced
to brownout hard-resets, not a failing card.

---

## 1. What happened (diagnosis)

- Pi `optaris-edge` (Raspberry Pi 5, Ubuntu 24.04 arm64) stopped rejoining the network after
  repeated crashes.
- **Power is ruled out:** symptom is identical across 4+ power-cycles, cable reseats, 2 PSU
  swaps, and a UPS. The Ethernet PHY links (link light on) but the **router's bridge FDB never
  learns the Pi's MAC** → the Pi transmits **zero** Ethernet frames → `eth0` is not coming up
  at the OS level. Not on WiFi either.
- **Most likely cause:** ext4 **root filesystem corruption** from the repeated brownout
  hard-resets, and/or an **interrupted Ragnar `apt` install** that left `dpkg` half-configured
  and wedged boot/networking. (Earlier in the session the FS was intact; several more hard
  resets happened since.)
- **Fix:** `fsck` the ext4 root on another machine, reboot, then finish the interrupted install
  remotely.

## 2. SD card layout (observed on macOS `diskutil`)

| Partition | Type | Label | Notes |
|---|---|---|---|
| p1 | FAT32 | `system-boot` | ~537 MB Ubuntu boot partition |
| p2 | **ext4** | (root) | ~62 GB — **this is the repair target** |

On the **Linux laptop** the card will appear as `/dev/sdX` (USB reader) or `/dev/mmcblk0`
(built-in reader). Root ext4 = `/dev/sdX2` or `/dev/mmcblk0p2`.

## 3. Recovery procedure (Linux laptop)

```bash
# 1. Insert the SD card. Identify it — match the ~62GB card with a vfat + Linux partition.
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
#   e.g. sdb  57.9G ... ; sdb1 vfat system-boot ; sdb2 ext4 (root)
#   >>> VERIFY the device letter is the SD CARD, not the laptop's own disk. <<<

# 2. Make sure nothing is mounted from it (auto-mounters love to grab it).
sudo umount /dev/sdX1 /dev/sdX2 2>/dev/null || true

# 3. Repair the ext4 root (force full check, auto-fix).
sudo fsck.ext4 -f -y /dev/sdX2
#   exit 0=clean, 1=errors fixed, 2=fixed(reboot), >=4=uncorrected (rerun / seek help)

# 4. (Optional) check the boot partition too.
sudo fsck.vfat -a /dev/sdX1

# 5. Flush + eject, then put the card back in the Pi and boot it (on the UPS).
sync; sudo eject /dev/sdX
```

**If `eth0` still doesn't come up after boot** (interrupted-install fallout), get on the Pi
(now that fsck let it boot) and run:
```bash
sudo dpkg --configure -a
sudo apt-get -f install
sudo systemctl restart systemd-networkd   # or: sudo dhclient eth0
```
(Advanced alternative: `chroot` into `/dev/sdX2` from the laptop and run the same `dpkg`
commands before reboot — only if it won't boot far enough to log in.)

## 4. After the Pi is back on the network

```bash
# reachable? (IP preferred — mDNS 'optaris-edge.local' is flaky here)
ssh -i ~/.ssh/id_ed25519 pi@192.168.8.149   # or .195
# power sanity:
sudo vcgencmd get_throttled   # 0x0 good; 0x50000 = under-voltage occurred (marginal supply)
```

**Production sensing stack should self-heal on boot** (enabled systemd units) — verify:
```bash
systemctl is-active sensing-server.service ragnar-csi-fanout.service   # OptarisSense + fan-out
curl -s http://127.0.0.1:8080/api/v1/nodes   # ESP32 nodes 2/3/5 active?
sudo ss -ulnp | grep -E ':5005|:5105'         # fan-out :5005, OptarisSense :5105
```

**Finish the interrupted Ragnar deployment** (was mid-`apt` when it crashed):
```bash
cd /home/pi/ragnar-app 2>/dev/null || git clone --branch feature/optaris-edge-rusense-deploy \
    https://github.com/ossiemarks/Ragnar.git /home/pi/ragnar-app
sudo dpkg --configure -a && sudo apt-get -f install     # clear the interrupted state first
# then re-run the installer (headless server profile) + sensing on the SEPARATE ports:
sudo ./install_ragnar.sh                                 # ragnar.service + web :8000
sudo SENSING_UDP_PORT=5006 SENSING_HTTP_PORT=3000 SENSING_WS_PORT=3100 ./scripts/install_sensing.sh
```

## 5. Current architecture / port map (do not clobber)

| Component | Ports | Notes |
|---|---|---|
| CSI UDP fan-out (`ragnar-csi-fanout.service`) | UDP **:5005** → dup to :5105 + :5006 | `/home/pi/csi_udp_fanout.py` |
| OptarisSense `sensing-server.service` | UDP **:5105**, HTTP **:8080**, WS :8765 | override in `…/sensing-server.service.d/sentinel-ops.conf` |
| Ragnar `ragnar-sensing.service` (in progress) | UDP **:5006**, HTTP **:3000**, WS :3100 | to be completed (step 4) |
| Ragnar web app (in progress) | HTTP **:8000** | to be completed |
| ESP32 nodes | → fan-out :5005 | ids 2/3/5, native ADR-018 |
| Node 210 (Intel AX210 / FeitCSI) | → fan-out :5005 | run **on-demand** (out-of-tree driver, power/thermal heavy); scripts: `scripts/build_feitcsi.sh`, `scripts/feitcsi_capture_loop.sh` |

## 6. Repo / references

- Repo: **github.com/ossiemarks/Ragnar**, branch `feature/optaris-edge-rusense-deploy`
  (fork of PierreGode/Ragnar = `upstream`).
- Design/plans: `docs/superpowers/specs/` and `docs/superpowers/plans/`; decisions in
  `decisionTree.md`.
- `csi_shim` package: `python/csi_shim/` (ADR-018 encoder + nexmon/feitcsi readers); tests in
  `tests/csi_shim/` (17 passing on Python 3.12+).
- Router: GL-MT3000 `192.168.8.1`, SSID `GL-MT3000-062`; its `mt76-csi` daemon is **disabled**
  (was OOM-leaking / dropping the AP).

## 7. Known constraints
- Pi power is **marginal under load** — a heavy `apt` install can brown it out mid-run (that's
  what interrupted the Ragnar install). Prefer the UPS + a certified 5 A supply; consider
  removing the AX210 during heavy installs to cut PCIe draw.
- macOS **cannot** `fsck` ext4 without `e2fsprogs` (`fsck.ext4` on the raw device) — hence the
  Linux laptop. Docker Desktop on macOS can't reach the physical SD card either.
