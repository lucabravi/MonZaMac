"""Asset-free opt-in geometry motion shaders: host contracts and real Metal execution."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="monzamac-fg-geometry-") as tmp:
    flags = [*shlex.split(os.environ.get("CC", "clang")), "-O1", "-g", "-Wall", "-Wextra",
             *shlex.split(os.environ.get("TEST_CFLAGS", ""))]
    source = "runtime/nvn/maxwell/translate.c"
    host = Path(tmp) / "host"
    subprocess.run([*flags, "-std=gnu11", "tools/test_fg_geometry_shaders.c", source, "-lm", "-o", str(host)], cwd=ROOT, check=True)
    subprocess.run([str(host)], cwd=ROOT, check=True)
    if sys.platform == "darwin" and "--host-only" not in sys.argv:
        metal = Path(tmp) / "metal"
        subprocess.run([*flags, "-fobjc-arc", "-framework", "Foundation", "-framework", "Metal",
                        "tools/test_fg_geometry_shaders.m", source, "-lm", "-o", str(metal)], cwd=ROOT, check=True)
        env = dict(os.environ, MTL_DEBUG_LAYER="1", MTL_SHADER_VALIDATION="1")
        subprocess.run([str(metal)], cwd=ROOT, env=env, check=True, timeout=60)

        history = Path(tmp) / "history"
        subprocess.run([*flags, "-fobjc-arc", "-framework", "Foundation", "-framework", "Metal",
                        "tools/test_geometry_motion_history.m", "runtime/nvn/geometry_motion_history.m",
                        "-o", str(history)], cwd=ROOT, check=True)
        subprocess.run([str(history)], cwd=ROOT, env=env, check=True, timeout=30)
