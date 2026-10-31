"""Asset-free test of the crash explainer's headline per known cause; accepts CC and TEST_CFLAGS."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CASES = [('svcbreak', 'The game stopped at one of its own checks'),
         ('terminate', "The game ran into an error it couldn't recover from"),
         ('font', "No font for the game's text"), ('gpu', 'The graphics driver crashed'),
         ('game', 'The game crashed'), ('other', 'MonZaMac stopped because of an error')]
with tempfile.TemporaryDirectory(prefix='monzamac-crash-test-') as tmp:
    exe = Path(tmp) / 'test_crash_explain'
    subprocess.run([*shlex.split(os.environ.get('CC', 'clang')), '-std=gnu11', '-O1', '-UNDEBUG', '-Wall', '-Wextra',
                    *shlex.split(os.environ.get('TEST_CFLAGS', '')), 'tools/test_crash_explain.c',
                    'runtime/crash_explain.c', '-o', str(exe)], cwd=ROOT, check=True)
    for case, head in CASES:
        subprocess.run([str(exe), case, head], check=True, timeout=30)
