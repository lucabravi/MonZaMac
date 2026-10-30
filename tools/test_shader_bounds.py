"""Asset-free shader container boundary tests; use TEST_CFLAGS for sanitizers."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CASES = (
    'fragment-short', 'vertex-short', 'graphics-header-only', 'graphics-schedule-only',
    'compute-empty', 'compute-short-magic', 'compute-schedule-only', 'compute-truncated-header',
    'compute-header-only', 'compute-header-schedule-only', 'vertex-valid', 'fragment-valid',
    'compute-valid', 'compute-header-valid', 'null-input',
)

with tempfile.TemporaryDirectory(prefix='monzamac-shader-bounds-') as tmp:
    exe = Path(tmp) / 'test_shader_bounds'
    subprocess.run([*shlex.split(os.environ.get('CC', 'clang')), '-std=gnu11', '-O1', '-g',
                    *shlex.split(os.environ.get('TEST_CFLAGS', '')), 'tools/test_shader_bounds.c',
                    'runtime/nvn/maxwell/translate.c', '-lm', '-o', str(exe)], cwd=ROOT, check=True)
    failed = []
    for case in sys.argv[1:] or CASES:
        run = subprocess.run([str(exe), case], cwd=ROOT, capture_output=True, text=True, timeout=10)
        if run.returncode:
            failed.append(case)
            print(f'FAIL {case} (exit {run.returncode})\n{run.stderr}', end='')
        else:
            print(run.stdout, end='')
    if failed:
        sys.exit(f'{len(failed)} shader boundary regression(s) failed: {", ".join(failed)}')
