"""Asset-free production IFile regressions: python3 tools/test_file_io.py."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CASES = (
    'short-write', 'interrupted-write', 'partial-failure', 'zero-write',
    'oversized-write', 'missing-write-buffer', 'negative-write-size',
    'negative-write-offset', 'write-offset-overflow', 'flush-error', 'interrupted-flush',
    'read-error', 'interrupted-read', 'missing-read-buffer', 'negative-read-size',
    'negative-read-offset', 'read-offset-overflow', 'bounded-read', 'read-eof', 'getsize-error', 'getsize',
    'close-file', 'close-cloned-file', 'close-directory', 'confine',
)

with tempfile.TemporaryDirectory(prefix='monzamac-file-test-') as tmp:
    exe = Path(tmp) / 'test_file_io'
    flags = ['-std=gnu11', '-O1', '-g', '-Wno-format', '-Iruntime']
    if sys.platform.startswith('linux'):
        # The product targets macOS; this harness needs only its POSIX declarations,
        # not the unused Linux compatibility header referenced by platform.h.
        flags += ['-U__linux__']
    flags += shlex.split(os.environ.get('TEST_CFLAGS', ''))
    subprocess.run([*shlex.split(os.environ.get('CC', 'clang')), *flags,
                    'tools/test_file_io.c', '-o', str(exe)], cwd=ROOT, check=True)
    failed = []
    for case in sys.argv[1:] or CASES:
        run = subprocess.run([str(exe), case], cwd=ROOT, capture_output=True, text=True, timeout=10)
        if run.returncode:
            failed.append(case)
            print(f'FAIL {case} (exit {run.returncode})\n{run.stderr}', end='')
        else:
            print(run.stdout, end='')
    if failed:
        sys.exit(f'{len(failed)} IFile regression(s) failed: {", ".join(failed)}')
