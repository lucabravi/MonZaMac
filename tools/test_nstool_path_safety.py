"""Tiny regression check for filesystem names handled by the bundled nstool."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    exe = Path(tmp) / 'test_nstool_path_safety'
    subprocess.run(['clang++', '-std=c++17', '-I' + str(root / 'tools'),
                    str(root / 'tools/test_nstool_path_safety.cpp'), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print('PASS nstool rejects traversal, separators and empty RomFS names')
