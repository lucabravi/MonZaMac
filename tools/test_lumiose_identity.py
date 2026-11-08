"""Test native library/module identity matching with synthetic metadata."""
from pathlib import Path
import os,shlex,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
cc=shlex.split(os.environ.get('CC','clang'))
extra=shlex.split(os.environ.get('TEST_CFLAGS',''))
with tempfile.TemporaryDirectory(prefix='monzamac-identity-') as tmp:
    exe=Path(tmp)/'identity';lib=Path(tmp)/'identity.dylib'
    subprocess.run([*cc,'-dynamiclib','-Iruntime','-DLUMIOSE_BUILD_ID="'+'11'*32+'"',
                    'tools/lumiose/identity.c','-o',str(lib)],cwd=root,check=True)
    subprocess.run([*cc,'-std=gnu11','-O1','-g','-UNDEBUG','-Wno-format','-Wl,-dead_strip',
                    '-Iruntime',*extra,'tools/test_lumiose_identity.c','-o',str(exe)],cwd=root,check=True)
    subprocess.run([str(exe),str(lib)],cwd=root,check=True,timeout=10)
