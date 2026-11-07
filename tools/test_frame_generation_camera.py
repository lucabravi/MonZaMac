#!/usr/bin/env python3
"""Validate scene camera decoding with synthetic matrices and no GPU/game data."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="frame-generation-camera-") as directory:
    binary = Path(directory) / "camera"
    subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-pedantic", "-I", str(ROOT / "runtime/nvn"),
                    str(ROOT / "tools/test_frame_generation_camera.c"),
                    str(ROOT / "runtime/nvn/frame_generation_camera.c"), "-lm", "-o", str(binary)],
                   check=True)
    subprocess.run([str(binary)], check=True)
