#!/usr/bin/env python3
"""The wired Xbox pad decoder (runtime/ui/usbpad.h): tools/test_usbpad.c, built and run; no controller needed."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="monzamac-usbpad-") as tmp:
    binary = Path(tmp) / "test_usbpad"
    subprocess.run(["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", str(root / "tools/test_usbpad.c"),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
