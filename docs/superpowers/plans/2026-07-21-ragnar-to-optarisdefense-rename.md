# Ragnar → OptarisDefense Rename (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the product `Ragnar` → `OptarisDefense` across the codebase (identifiers, filenames, systemd units, paths, git repo), leaving the excluded names untouched. Repo-only (Phase 1); the live-Pi migration is a separate Phase 2.

**Architecture:** A single, TDD'd codemod (`scripts/rename_codemod.py`) with a pure `transform_content(text)` and `transform_path(path)`, applied once across the in-scope file set, then verified (imports, tests, shrinking grep), then the git repo is renamed.

**Tech Stack:** Python 3.12 (stdlib `re`), pytest, git, `gh`.

## Global Constraints

- **Canonical mapping** (case-sensitive, applied in this order — order matters):
  1. `/home/ragnar` → `/home/optaris-defense`
  2. `ragnar-` → `optaris-defense-` (service prefixes: `ragnar-csi-fanout`, `ragnar-ldapwatch`, …)
  3. `ragnar.service` → `optaris-defense.service`
  4. `from Ragnar ` → `from optaris_defense ` ; `import Ragnar` → `import optaris_defense` (module refs)
  5. `headlessRagnar` → `headless_optaris_defense` (camelCase module)
  6. `Ragnar.py` → `optaris_defense.py` ; `ragnar.py` → `optaris_defense.py` ; `ragnar.ico` → `optaris_defense.ico`
  7. `RAGNAR` → `OPTARIS_DEFENSE`
  8. `Ragnar` → `OptarisDefense` (substring — catches classes, `PagerRagnar`, `RagnarMenu`, display text)
  9. `ragnar` → `optaris_defense` (substring — snake identifiers, `restart_ragnar_service`)
- **Filenames** (`transform_path`): `.service` files → hyphen form (`optaris-defense-*`); all other `*ragnar*` files → snake (`Ragnar.py`→`optaris_defense.py`, `headlessRagnar.py`→`headless_optaris_defense.py`, `install_ragnar.sh`→`install_optaris_defense.sh`, `web/ragnar.ico`→`web/optaris_defense.ico`).
- **Exclusions — never transform these** (file-path filter): `OptarisSense`/`optaris-sense` (they don't contain `ragnar`, so naturally safe), `optaris-edge` (safe), the `.git/` dir, vendored libs `pager_lib/smb/`, `pager_lib/nmb/`, any file mentioning only `Bjorn`, and **this rename spec + plan + `.superpowers/sdd/` ledger** (they cite the old name deliberately).
- Verification gate (after apply): every touched Python module imports; `.venv/bin/python -m pytest tests/csi_shim/ -q` = 17 passed; `grep -rIl ragnar` (excluding the exclusion set) → only intentional leftovers, documented.
- stdlib only. No authorship/attribution comments. Unix (LF). No Co-Authored-By/Claude/Anthropic trailer on commits.
- Work on branch `rename/ragnar-to-optaris-defense` (cut from the current branch HEAD).

---

### Task 1: Build the rename codemod (TDD)

**Files:**
- Create: `scripts/rename_codemod.py`
- Test: `tests/rename/test_rename_codemod.py`

**Interfaces:**
- Produces: `rename_codemod.transform_content(text:str) -> str` and `rename_codemod.transform_path(path:str) -> str` (returns the new path, or the same path if no `ragnar`).

- [ ] **Step 1: Write the failing test (these cases ARE the spec)**

```python
# tests/rename/test_rename_codemod.py
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location(
    "rename_codemod",
    pathlib.Path(__file__).resolve().parents[2] / "scripts" / "rename_codemod.py")
rc = importlib.util.module_from_spec(spec); spec.loader.exec_module(rc)


def test_content_module_vs_class_disambiguation():
    assert rc.transform_content("from Ragnar import Ragnar") == "from optaris_defense import OptarisDefense"
    assert rc.transform_content("import Ragnar") == "import optaris_defense"
    assert rc.transform_content("class Ragnar:") == "class OptarisDefense:"


def test_content_compound_identifiers():
    assert rc.transform_content("class RagnarMenu(Base):") == "class OptarisDefenseMenu(Base):"
    assert rc.transform_content("class PagerRagnar:") == "class PagerOptarisDefense:"
    assert rc.transform_content("def restart_ragnar_service():") == "def restart_optaris_defense_service():"
    assert rc.transform_content("import headlessRagnar") == "import headless_optaris_defense"


def test_content_services_paths_display_constants():
    assert rc.transform_content("/home/ragnar/Ragnar") == "/home/optaris-defense/OptarisDefense"
    assert rc.transform_content("ragnar.service") == "optaris-defense.service"
    assert rc.transform_content("ragnar-csi-fanout.service") == "optaris-defense-csi-fanout.service"
    assert rc.transform_content("Ragnar Cyberviking") == "OptarisDefense Cyberviking"
    assert rc.transform_content("RAGNAR_HOME") == "OPTARIS_DEFENSE_HOME"


def test_content_leaves_exclusions_untouched():
    assert rc.transform_content("OptarisSense sensing-server") == "OptarisSense sensing-server"
    assert rc.transform_content("optaris-edge host, Bjorn project") == "optaris-edge host, Bjorn project"


def test_transform_path():
    assert rc.transform_path("Ragnar.py") == "optaris_defense.py"
    assert rc.transform_path("headlessRagnar.py") == "headless_optaris_defense.py"
    assert rc.transform_path("install_ragnar.sh") == "install_optaris_defense.sh"
    assert rc.transform_path("web/ragnar.ico") == "web/optaris_defense.ico"
    assert rc.transform_path("config/systemd/ragnar-csi-fanout.service") == "config/systemd/optaris-defense-csi-fanout.service"
    assert rc.transform_path("scripts/install_sensing.sh") == "scripts/install_sensing.sh"  # unchanged
```

- [ ] **Step 2: Run it — expect failure**

Run: `cd /Users/osmanmarks/code/Ragnar && .venv/bin/python -m pytest tests/rename/test_rename_codemod.py -v`
Expected: FAIL (module/file not found).

- [ ] **Step 3: Implement the codemod**

```python
# scripts/rename_codemod.py
"""Ragnar -> OptarisDefense rename codemod. Pure transforms; ordered, case-sensitive."""
import re

# Ordered content rules (regex, replacement). Order is significant.
_CONTENT_RULES = [
    (re.compile(r"/home/ragnar"), "/home/optaris-defense"),
    (re.compile(r"ragnar-"), "optaris-defense-"),
    (re.compile(r"ragnar\.service"), "optaris-defense.service"),
    (re.compile(r"\bfrom Ragnar\b"), "from optaris_defense"),
    (re.compile(r"\bimport Ragnar\b"), "import optaris_defense"),
    (re.compile(r"headlessRagnar"), "headless_optaris_defense"),
    (re.compile(r"Ragnar\.py"), "optaris_defense.py"),
    (re.compile(r"ragnar\.py"), "optaris_defense.py"),
    (re.compile(r"ragnar\.ico"), "optaris_defense.ico"),
    (re.compile(r"RAGNAR"), "OPTARIS_DEFENSE"),
    (re.compile(r"Ragnar"), "OptarisDefense"),
    (re.compile(r"ragnar"), "optaris_defense"),
]


def transform_content(text):
    for pat, repl in _CONTENT_RULES:
        text = pat.sub(repl, text)
    return text


def transform_path(path):
    import os
    d, name = os.path.split(path)
    if "ragnar" not in name.lower():
        return path
    if name.endswith(".service"):
        new = name.replace("ragnar-", "optaris-defense-").replace("ragnar.service", "optaris-defense.service").replace("ragnar", "optaris-defense")
    else:
        new = (name.replace("headlessRagnar", "headless_optaris_defense")
                   .replace("Ragnar", "optaris_defense")
                   .replace("ragnar", "optaris_defense"))
    return os.path.join(d, new) if d else new
```

- [ ] **Step 4: Run tests — expect pass**

Run: `cd /Users/osmanmarks/code/Ragnar && .venv/bin/python -m pytest tests/rename/test_rename_codemod.py -v`
Expected: PASS (6 passed). If any tricky case fails, adjust rule ORDER (not add blind replaces) until green — the tests are the contract.

- [ ] **Step 5: Commit**

```bash
git add scripts/rename_codemod.py tests/rename/test_rename_codemod.py
git commit -m "feat(rename): TDD'd Ragnar->OptarisDefense codemod (transform_content/path)"
```

---

### Task 2: Apply the codemod + verify the whole tree

**Files:** all in-scope files (content rewrite + `git mv` renames).

- [ ] **Step 1: Cut the branch + record baseline**

```bash
git checkout -b rename/ragnar-to-optaris-defense
grep -rIl ragnar . 2>/dev/null | grep -vE '^\./\.git/' | wc -l    # baseline file count
.venv/bin/python -m pytest tests/csi_shim/ -q                      # baseline: 17 passed
```

- [ ] **Step 2: Write + run the apply driver**

```python
# scripts/rename_apply.py  (temporary driver; deleted in Step 5)
import subprocess, pathlib
from rename_codemod import transform_content, transform_path  # run from scripts/ or add to path

EXCLUDE_DIRS = {".git", "pager_lib/smb", "pager_lib/nmb", ".venv", ".superpowers"}
EXCLUDE_FILES = {
    "docs/superpowers/specs/2026-07-21-ragnar-to-optarisdefense-rename-design.md",
    "docs/superpowers/plans/2026-07-21-ragnar-to-optarisdefense-rename.md",
}
TEXT_EXT = {".py",".sh",".js",".json",".html",".css",".md",".service",".txt",".cfg",".ico",".conf"}

root = pathlib.Path(".")
files = [p for p in root.rglob("*") if p.is_file()]
for p in files:
    rel = str(p).lstrip("./")
    if any(rel.startswith(d) for d in EXCLUDE_DIRS) or rel in EXCLUDE_FILES:
        continue
    # 1) content rewrite for text files
    if p.suffix in TEXT_EXT and p.suffix != ".ico":
        try:
            orig = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        new = transform_content(orig)
        if new != orig:
            p.write_text(new, encoding="utf-8")
    # 2) filename rename
    newrel = transform_path(rel)
    if newrel != rel:
        subprocess.run(["git", "mv", rel, newrel], check=True)
print("apply done")
```

Run:
```bash
cd /Users/osmanmarks/code/Ragnar && PYTHONPATH=scripts .venv/bin/python scripts/rename_apply.py
```

- [ ] **Step 3: Verify — imports, tests, shrinking grep**

```bash
# every csi_shim test still green (imports + behavior):
.venv/bin/python -m pytest tests/csi_shim/ tests/rename/ -q          # expect 23 passed
# no dangling 'from Ragnar' / 'import Ragnar' / *Ragnar*.py left:
grep -rIn "import Ragnar\|from Ragnar\|Ragnar\.py" . | grep -vE '\.git/|/specs/2026-07-21|/plans/2026-07-21' || echo "no dangling module refs"
# remaining 'ragnar' occurrences — must be ONLY exclusions (Bjorn / OptarisSense-adjacent / vendored / the 2 rename docs):
grep -rIl ragnar . | grep -vE '^\./\.git/|pager_lib/(smb|nmb)/|2026-07-21-ragnar|\.superpowers/'
# spot-check the web entrypoint still parses:
.venv/bin/python -m py_compile optaris_defense.py headless_optaris_defense.py 2>&1 | head
```
Expected: 23 passed; "no dangling module refs"; the final grep lists ONLY the documented exclusions; py_compile clean. Investigate & fix any dangling ref (usually a rule-order gap — fix in `rename_codemod.py`, re-run Task 1 tests, re-apply).

- [ ] **Step 4: Manual sweep for missed structural bits**

```bash
grep -rInE 'Ragnar|RAGNAR' . | grep -vE '\.git/|2026-07-21-ragnar|OptarisSense' | head -40   # eyeball any leftover PascalCase
find . -iname '*ragnar*' -not -path './.git/*' | grep -vE '2026-07-21'   # any file not renamed?
```
Fix anything the codemod missed (add a targeted rule + re-run Task 1 tests). Expected: both empty (aside from the rename docs).

- [ ] **Step 5: Remove the driver, commit**

```bash
rm scripts/rename_apply.py
git add -A
git commit -m "refactor: rename Ragnar -> OptarisDefense across the codebase (codemod-applied)"
```

---

### Task 3: Rename the git repository

- [ ] **Step 1: Rename on GitHub + update origin**

```bash
gh repo rename optaris-defense --repo ossiemarks/Ragnar --yes
git remote set-url origin git@github.com:ossiemarks/optaris-defense.git
git remote -v    # confirm origin -> ossiemarks/optaris-defense
```

- [ ] **Step 2: Push the rename branch**

```bash
git push -u origin rename/ragnar-to-optaris-defense
gh api repos/ossiemarks/optaris-defense/branches/rename/ragnar-to-optaris-defense --jq '.name'   # confirm
```

- [ ] **Step 3: Record completion**

Note in `.superpowers/sdd/progress.md`: repo renamed, branch pushed, grep-ragnar down to documented exclusions. (No code changes here — nothing to test.)

---

## Notes for the executor
- The codemod's **rule order is load-bearing** — module rules (4–6) MUST run before the generic PascalCase/snake rules (8–9). If a tricky case regresses, fix the order, re-green Task 1, re-apply.
- If Task 2's grep leaves an unexpected `ragnar` hit, DO NOT hand-edit blindly — add/adjust a codemod rule + test so the transform stays reproducible.
- **Do NOT deploy this branch to the live Pi** — Phase 2 (separate) migrates the running box; Phase 1 is repo-only.
- `main` still has the old names; this branch diverges from upstream by design.
