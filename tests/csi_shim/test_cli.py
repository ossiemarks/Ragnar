import subprocess, sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def test_cli_rejects_unknown_source():
    p = subprocess.run([sys.executable, "-m", "python.csi_shim", "bogus"],
                       capture_output=True, text=True, cwd=REPO_ROOT)
    assert p.returncode == 2
    assert "nexmon" in (p.stderr + p.stdout)
