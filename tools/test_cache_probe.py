"""Asset-free production renderer cache-index test; accepts CC and TEST_CFLAGS."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='monzamac-cache-test-') as tmp:
    exe = Path(tmp) / 'test_cache_probe'
    subprocess.run([*shlex.split(os.environ.get('CC', 'clang')), '-std=c11', '-O2', '-Wall', '-Wextra',
                    *shlex.split(os.environ.get('TEST_CFLAGS', '')), 'tools/test_cache_probe.c', '-o', str(exe)],
                   cwd=ROOT, check=True)
    subprocess.run([str(exe)], check=True, timeout=30)
