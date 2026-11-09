"""Test synthetic guest HLE hooks with no game/mod data."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="monzamac-hle-hook-") as tmp:
    exe=Path(tmp)/"hooks"
    subprocess.run([*shlex.split(os.environ.get("CC","clang")),"-std=gnu11","-O1","-g","-UNDEBUG",
                    "-Wno-format","-Wl,-dead_strip","-Iruntime",*shlex.split(os.environ.get("TEST_CFLAGS","")),
                    "tools/test_lumiose_hle.c","-o",str(exe)],cwd=ROOT,check=True)
    p=subprocess.run([str(exe)],cwd=ROOT,capture_output=True,text=True,timeout=10)
    if p.returncode:raise SystemExit(p.stdout+p.stderr)
    print(p.stdout,end="")
