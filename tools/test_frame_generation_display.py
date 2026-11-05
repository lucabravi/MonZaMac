#!/usr/bin/env python3
"""Native GPU copy and deterministic display queue/timing checks; no window or game."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="monzamac-fg-display-") as tmp:
    binary = Path(tmp) / "test_frame_generation_display"
    subprocess.run([
        "xcrun", "clang", "-std=gnu11", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
        "-mmacosx-version-min=15.0", str(root / "tools/test_frame_generation_display.m"),
        "-framework", "Foundation", "-framework", "Metal", "-framework", "QuartzCore", "-o", str(binary),
    ], check=True)
    env = dict(os.environ, MTL_DEBUG_LAYER="1", MTL_SHADER_VALIDATION="1")
    subprocess.run([str(binary)], check=True, env=env, timeout=30)
