"""Run the asset-free production-kernel session tests."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="monzamac-session-test-") as tmp:
    exe = Path(tmp) / "sessions"
    subprocess.run([*shlex.split(os.environ.get("CC", "clang")), "-std=gnu11", "-O1", "-g", "-UNDEBUG",
                    "-Wno-format", "-Wl,-dead_strip", "-Iruntime", *shlex.split(os.environ.get("TEST_CFLAGS", "")),
                    "tools/test_kernel_sessions.c", "-o", str(exe)], cwd=ROOT, check=True)
    subprocess.run([str(exe)], cwd=ROOT, timeout=15, check=True)
