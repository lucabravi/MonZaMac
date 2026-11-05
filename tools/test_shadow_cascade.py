#!/usr/bin/env python3
"""Asset-free cascade filter recognition and native Metal math checks."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="shadow-cascade-") as tmp:
    tmp = Path(tmp)
    exe, source = tmp / "translate", tmp / "test.metal"
    subprocess.run(["clang", "-O1", "-I" + str(ROOT), str(ROOT / "tools/test_shadow_cascade.c"),
                    str(ROOT / "runtime/nvn/maxwell/translate.c"), "-o", str(exe)], check=True)
    env = dict(os.environ)
    env.pop("LARECOMP_SHADOW_CASCADE_FILTER", None)
    subprocess.run([str(exe), str(source)], env=env, check=True)
    if sys.platform == "darwin":
        gpu = tmp / "metal"
        subprocess.run(["clang", "-O1", "-fobjc-arc", "-framework", "Metal", "-framework", "Foundation",
                        str(ROOT / "tools/test_shadow_cascade.m"), "-o", str(gpu)], check=True)
        subprocess.run([str(gpu), str(source)], env=dict(env, MTL_DEBUG_LAYER="1"), check=True)
