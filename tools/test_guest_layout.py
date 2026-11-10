"""Native check of the guest reservations with macOS 27's address space imitated (runtime/guest_layout.c)."""
import subprocess, tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    exe = Path(tmp) / 'test_guest_layout'
    subprocess.run(['clang', '-O1', '-g', '-Wl,-dead_strip', '-I' + str(root / 'runtime'), str(root / 'tools/test_guest_layout.c'),
                    str(root / 'runtime/guest_layout.c'), str(root / 'runtime/platform/macos.c'), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
