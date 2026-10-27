"""Native, asset-free setup filesystem test (macOS)."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    exe = Path(tmp) / 'test_setup'
    subprocess.run(['clang', '-O1', '-g', '-Wl,-dead_strip', '-I' + str(root / 'runtime'),
                    '-I/opt/homebrew/opt/sdl3/include', str(root / 'tools/test_game_setup.c'),
                    str(root / 'runtime/paths.c'), str(root / 'runtime/platform/macos.c'),
                    '-L/opt/homebrew/opt/sdl3/lib', '-lSDL3', '-o', str(exe)], check=True)
    env = dict(os.environ, LARECOMP_DATA_ROOT=tmp)
    subprocess.run([str(exe)], env=env, check=True)
