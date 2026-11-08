#!/bin/bash
# Translate a Lumiose subsdk9 (the 1.3.9 build, see runtime/loader.c) to C and compile it into a library for
# LUMIOSE_TEST_LIBRARY. Experimental. Usage: tools/lumiose_build.sh <subsdk9> [outdir, default build/lumiose]
set -e
cd "$(dirname "$0")/.."
MOD=${1:?usage: tools/lumiose_build.sh <subsdk9> [outdir]}
OUT=${2:-build/lumiose}
PY=tools/venv/bin/python
mkdir -p "$OUT/stage" "$OUT/gen" "$OUT/obj"
cp "$MOD" "$OUT/stage/subsdk9"
ln -sf "$PWD/extracted/exefs/main" "$OUT/stage/main"
# Jump table targets of the 1.3.9 build (switch tables the translator cannot see): offset, count, entry size, code base.
ENTRIES=$($PY - "$OUT/stage/subsdk9" <<'PYEOF'
import struct, sys
sys.path.insert(0, 'tools')
from nso import Nso
mod = Nso(sys.argv[1])
if not mod.build_id.startswith('96f2b142853fa151'):
    sys.exit('this script knows the jump tables of the 1.3.9 build only')
tables = [(0x57fdc8, 91, 'h', 0x136c44), (0x194b40, 123, 'h', 0x364cc), (0x212290, 14, 'b', 0xc1d74)]
entries = set()
for off, count, fmt, base in tables:
    entries.update(base + v * 4 for v in struct.unpack_from(f'<{count}{fmt}', mod.image, off))
print(','.join(hex(x) for x in sorted(entries)))
PYEOF
)
LUMIOSE_TEST_ENTRIES_LUMIOSE=$ENTRIES $PY tools/gen.py lumiose "$OUT/stage/subsdk9" 0x7006200000 "$OUT/gen"
FLAGS="-O1 -fno-strict-aliasing -Wno-return-type -Wno-unused-label -fvisibility=hidden -Iruntime -include runtime/lumiose_cpu.h"
ls "$OUT"/gen/*.c tools/lumiose_test_entry.c | xargs -P 8 -I{} sh -c 'clang '"$FLAGS"' -c {} -o '"$OUT"'/obj/$(basename {} .c).o'
# Match the runtime's module/library identity check even for this older bootstrap helper.
BUILD_ID=$($PY -c 'import sys; print(open(sys.argv[1], "rb").read()[0x40:0x60].hex())' "$MOD")
clang $FLAGS "-DLUMIOSE_BUILD_ID=\"$BUILD_ID\"" -c tools/lumiose/identity.c -o "$OUT/obj/identity.o"
clang -dynamiclib -undefined dynamic_lookup -o "$OUT/lumiose.dylib" "$OUT"/obj/*.o
ls -la "$OUT/lumiose.dylib"
