"""Asset-free native preflight check: python3 tools/test_gameimport_preflight.py."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    exe = Path(tmp) / 'test_preflight'
    subprocess.run(['clang', '-std=c11', '-I' + str(root / 'runtime'),
                    str(root / 'tools/test_gameimport_preflight.c'),
                    str(root / 'runtime/gameimport.c'), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
