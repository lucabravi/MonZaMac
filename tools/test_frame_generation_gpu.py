#!/usr/bin/env python3
"""Bounded, game-data-free MetalFX checks (requires macOS 26 + supported GPU)."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="monzamac-fg-") as tmp:
    binary = Path(tmp) / "frame_generation_gpu"
    subprocess.run([
        "xcrun", "clang", "-std=gnu11", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
        "-mmacosx-version-min=15.0", "-I", str(root / "runtime/nvn"),
        str(root / "tools/test_frame_generation_gpu.m"),
        "-framework", "Foundation", "-framework", "Metal", "-framework", "MetalFX",
        "-o", str(binary),
    ], check=True)
    env = dict(os.environ, MTL_DEBUG_LAYER="1", MTL_SHADER_VALIDATION="1")
    subprocess.run([str(binary)], check=True, env=env, timeout=90)
