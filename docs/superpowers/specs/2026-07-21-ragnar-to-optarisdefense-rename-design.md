# Ragnar → OptarisDefense Full Rename — Design

**Date:** 2026-07-21
**Goal:** Rebrand the whole product from **Ragnar** to **OptarisDefense** across the codebase —
identifiers, filenames, systemd services, paths, and the git repo — leaving the separate
`OptarisSense` sensing engine and other exclusions untouched.

## Naming convention (the canonical mapping)

`optaris-defense` (hyphenated) is invalid as a Python identifier or module name, so the rename is
a **per-context** transform, not a single string replace:

| Context | `Ragnar` / `ragnar` becomes | Example |
|---|---|---|
| Display / UI / docs / comments | `OptarisDefense` / `optaris-defense` | "Ragnar Cyberviking" → "OptarisDefense Cyberviking" |
| Python classes (PascalCase) | `OptarisDefense…` | `class RagnarMenu` → `class OptarisDefenseMenu`; `PagerRagnar` → `PagerOptarisDefense` |
| Python modules / functions / vars (snake) | `optaris_defense` | `restart_ragnar_service` → `restart_optaris_defense_service` |
| Filenames / dirs (snake, importable) | `optaris_defense` | `Ragnar.py` → `optaris_defense.py`; `headlessRagnar.py` → `headless_optaris_defense.py` |
| systemd services / paths / hostnames / CLI (hyphen) | `optaris-defense` | `ragnar.service` → `optaris-defense.service`; `/home/ragnar` → `/home/optaris-defense`; `ragnar-csi-fanout` → `optaris-defense-csi-fanout` |
| git repo | `optaris-defense` | `ossiemarks/Ragnar` → `ossiemarks/optaris-defense` |

## Scope

**In scope:** every case-variant of **`Ragnar`** (≈2,941 occurrences across ≈188 files), plus the
`*ragnar*` filenames/dirs, the `ragnar*.service` units, `/home/ragnar` paths, and the git repo
name.

**Explicitly out of scope (leave untouched):**
- `OptarisSense` / `optaris-sense` — the RuView-derived sensing engine (a separate product).
- `optaris-edge` — the Pi hostname.
- Vendored third-party libraries: `pager_lib/smb`, `pager_lib/nmb` (external SMB/NetBIOS).
- `Bjorn` references — Ragnar is "Father of Bjorn", a *different* project.
- **This rename spec + its implementation plan** and the SDD progress ledger — they reference the
  old name `Ragnar` deliberately (documenting the migration); the doc-rename stage must skip them.
- Historical design docs / specs whose `Ragnar` mentions are historical record (rename only where
  it's the live product name, not where it's citing prior state) — executor judgment, err toward
  leaving prior-dated specs as written.

**Consequence accepted:** this fully diverges the fork from upstream `PierreGode/Ragnar` — no more
clean merges.

## Execution — staged, each stage independently verified

Moving ~2,900 refs safely means staging by risk and verifying between stages:

1. **Text / branding** — display strings, comments, docs, and other non-identifier occurrences.
2. **Code identifiers** — classes / functions / vars, WITH matching import updates so nothing
   breaks. After: every module imports (`python -c "import <mod>"`), the `csi_shim` test suite is
   green (17/17).
3. **File / dir renames** — `git mv` the `*ragnar*` files to their `optaris_defense` forms, then
   fix every `import`/path reference to them.
4. **Services / paths / CLI** — the `.service` unit files, `/home/ragnar` paths, install/update
   scripts, and the `ragnar-csi-*` units (fanout/nexmon/intel/sensing).
5. **Git repo** — rename `ossiemarks/Ragnar` → `ossiemarks/optaris-defense` (`gh`), update the
   local `origin` remote.

### Verification gate (run after each stage)
- `python -c "import …"` succeeds for every touched module (no broken imports).
- `csi_shim` tests: `.venv/bin/python -m pytest tests/csi_shim/ -q` → 17 passed.
- `grep -riI "ragnar" .` (excluding `.git`, vendored libs, `Bjorn`) shrinks toward zero — any
  remaining hit is an intentional exclusion, documented.
- Smoke-run the web app entrypoint to confirm it still starts.

## Phasing

- **Phase 1 (this spec/plan): the codebase rename** on a dedicated branch
  (`rename/ragnar-to-optaris-defense`). Repo-only; does not touch the running Pi.
- **Phase 2 (separate, deferred): live-deployment migration.** When the Pi is back and stable,
  migrate the running box: rename `ragnar.service`/`ragnar-csi-*` units, move `/home/ragnar` →
  `/home/optaris-defense`, migrate the system user, and update cross-references (OptarisSense
  override, fan-out). Delivered as a migration script; not attempted while the Pi is offline.

## Risks
- **Regex over-reach:** blind replace could hit substrings (e.g. inside `OptarisSense`, `Bjorn`,
  vendored code) — mitigated by context-shaped patterns + the exclusion list + the shrinking-grep
  gate.
- **Broken imports / dangling filename refs:** mitigated by doing identifier + import updates
  together (stage 2) and file renames + reference fixes together (stage 3), with an import check
  after each.
- **Fork divergence:** accepted (no upstream merges).
- **Live deployment drift:** the running Pi keeps `ragnar` names until Phase 2 — the Phase-1
  repo rename must not be deployed piecemeal onto the current box.

## Out of scope
- Phase 2 live-Pi migration (own effort).
- Renaming the excluded names (`OptarisSense`, `optaris-edge`, vendored libs, `Bjorn`).
- Renaming the local working directory `/Users/osmanmarks/code/Ragnar` (cosmetic; optional later).
