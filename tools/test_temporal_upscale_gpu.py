#!/usr/bin/env python3
"""Synthetic temporal reconstruction checks; no game files required."""
import os
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="monzamac-temporal-") as tmp:
    binary = Path(tmp) / "temporal_gpu"
    subprocess.run(["xcrun", "clang", "-std=gnu11", "-O2", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                    "-mmacosx-version-min=15.0", "-I", str(root / "runtime/nvn"),
                    str(root / "tools/test_temporal_upscale_gpu.m"), "-framework", "Foundation", "-framework", "Metal",
                    "-framework", "MetalFX", "-o", str(binary)], check=True)
    subprocess.run([str(binary)], env=dict(os.environ, MTL_DEBUG_LAYER="1", MTL_SHADER_VALIDATION="1"), check=True, timeout=90)
