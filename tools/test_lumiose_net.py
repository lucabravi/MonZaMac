"""Synthetic offline socket ABI test; no game/mod data or external traffic."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="monzamac-net-") as tmp:
    exe = Path(tmp) / "net"
    subprocess.run([*shlex.split(os.environ.get("CC", "clang")), "-std=gnu11", "-O1", "-g",
                    "-UNDEBUG", "-Iruntime", *shlex.split(os.environ.get("TEST_CFLAGS", "")),
                    "tools/test_lumiose_net.c", "-o", str(exe)], cwd=ROOT, check=True)
    for mode in ["offline", "disabled", "loopback"]:
        subprocess.run([str(exe), mode], cwd=ROOT, check=True, timeout=10)
