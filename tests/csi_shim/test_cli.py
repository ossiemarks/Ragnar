import subprocess, sys


def test_cli_rejects_unknown_source():
    p = subprocess.run([sys.executable, "-m", "python.csi_shim", "bogus"],
                       capture_output=True, text=True, cwd="/Users/osmanmarks/code/Ragnar")
    assert p.returncode == 2
    assert "nexmon" in (p.stderr + p.stdout)
