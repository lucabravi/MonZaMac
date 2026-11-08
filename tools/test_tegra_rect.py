"""Synthetic partial texture upload regression; no game assets."""
from pathlib import Path
import os,shlex,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='monzamac-rect-') as tmp:
 exe=str(Path(tmp)/'rect')
 subprocess.run([*shlex.split(os.environ.get('CC','clang')),'-std=gnu11','-O1','-g','-UNDEBUG',*shlex.split(os.environ.get('TEST_CFLAGS','')),'-Iruntime/nvn','tools/test_tegra_rect.c','runtime/nvn/tegra.c','-o',exe],cwd=root,check=True)
 subprocess.run([exe],cwd=root,check=True,timeout=10)
