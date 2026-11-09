#!/usr/bin/env python3
"""Build and run the online job runner test (also with ASan/UBSan: --sanitize)."""
import subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
flags = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if '--sanitize' in sys.argv else []
with tempfile.TemporaryDirectory() as tmp:
    exe = Path(tmp) / 'test'
    subprocess.run(['clang', '-std=gnu11', '-O1', '-g', *flags, '-Wall', '-Wextra', str(ROOT / 'tools/test_online_prep.c'),
                    str(ROOT / 'runtime/online_prep.c'), '-lpthread', '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
