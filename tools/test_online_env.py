"""Asset-free test of the online environment guard: debug variables go online, the supported ones stay; accepts CC and
TEST_CFLAGS. The kept list must also hold every variable docs/environment.md supports."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'runtime/online_env.c').read_text()
kept = set(re.findall(r'"(LARECOMP_[A-Z0-9_]+)"', source[source.index('kept[]'):source.index('};', source.index('kept[]'))]))
documented = set(re.findall(r'`(LARECOMP_[A-Z0-9_]+)', (ROOT / 'docs/environment.md').read_text()))
missing = documented - kept
assert not missing, f'supported variables that online play would switch off: {sorted(missing)}'
with tempfile.TemporaryDirectory(prefix='monzamac-online-env-test-') as tmp:
    exe = Path(tmp) / 'test_online_env'
    subprocess.run([*shlex.split(os.environ.get('CC', 'clang')), '-std=gnu11', '-O1', '-UNDEBUG', '-Wall', '-Wextra',
                    *shlex.split(os.environ.get('TEST_CFLAGS', '')), 'tools/test_online_env.c', 'runtime/online_env.c',
                    '-o', str(exe)], cwd=ROOT, check=True)
    subprocess.run([str(exe)], check=True, timeout=30)
print('ok: online play keeps', len(kept), 'variables and the supported ones are all among them')
