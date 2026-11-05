"""Asset-free production error-applet/IPC/kernel test: python3 tools/test_am_applet.py."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='monzamac-am-test-') as tmp:
    exe = Path(tmp) / 'test_am_applet'
    subprocess.run([*shlex.split(os.environ.get('CC', 'clang')), '-std=gnu11', '-O1', '-g',
                    '-UNDEBUG', '-Wno-format', '-Wl,-dead_strip', '-Iruntime',
                    *shlex.split(os.environ.get('TEST_CFLAGS', '')), 'tools/test_am_applet.c',
                    '-o', str(exe)], cwd=ROOT, check=True)
    run = subprocess.run([str(exe)], cwd=ROOT, capture_output=True, text=True, timeout=10)
    if run.returncode:
        raise SystemExit(f'{run.stdout}{run.stderr}\nApplet test exited {run.returncode}')
    assert 'application error_number=12345678' in run.stderr, run.stderr
    assert '87654321' not in run.stderr and 'PRIVATE_INPUT_CONTENT' not in run.stderr, run.stderr
    print(run.stdout, end='')
