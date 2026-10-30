#!/bin/sh
# Fuzz test for runtime/nvn/maxwell/translate.c (see tools/test_translate.c):
#   hand-written operand-layout cases (test_translate cases), then MSL output byte-identical to a reference translator
#   (REF, default HEAD: the working tree's MSL changes; the MSL-only translator before the GLSL backend was 652e234,
#   not in this repository's history), and every GLSL translation compiles (shaderc, Vulkan 1.3) and validates
#   (SPIRV-Tools).
# usage: tools/test_translate.sh [count] [jobs] [mode msl|glsl|both]
# Needs clang + shaderc + SPIRV-Tools (Windows: MSYS2 ucrt64; macOS: brew install shaderc spirv-tools, or
# GLSL=0 for the MSL comparison only).
set -e
cd "$(dirname "$0")/.."
COUNT=${1:-20000}
JOBS=${2:-8}
MODE=${3:-both}
REF=${REF:-HEAD}
OUT=build/test_translate
mkdir -p "$OUT/old" "$OUT/dump"
git show "$REF:runtime/nvn/maxwell/translate.c" > "$OUT/old/translate.c"
git show "$REF:runtime/nvn/maxwell/shader.h" > "$OUT/old/shader.h"
CC=${CC:-clang}
RENAME="-Dmaxwell_translate=old_maxwell_translate -Dmaxwell_free=old_maxwell_free
 -Dmaxwell_translate_with_constants=old_maxwell_translate_with_constants
 -Dmaxwell_disassemble=old_maxwell_disassemble -Dmaxwell_gmem_base=old_maxwell_gmem_base
 -Dmaxwell_gmem_size=old_maxwell_gmem_size -Dmaxwell_dbg_code=old_maxwell_dbg_code -Dmaxwell_dbg_pc=old_maxwell_dbg_pc
 -Dmaxwell_dbg_reg=old_maxwell_dbg_reg -Dmaxwell_dbg_vs=old_maxwell_dbg_vs -Dmaxwell_empty_fragment=old_maxwell_empty_fragment"
PRE=""
case "$(uname -s)" in MINGW*|MSYS*) PRE="-include malloc.h";; esac
$CC -O2 -w $PRE $RENAME -c "$OUT/old/translate.c" -o "$OUT/old.o"
$CC -O2 -Wall -c runtime/nvn/maxwell/translate.c -o "$OUT/new.o"
if [ "${GLSL:-1}" = 1 ]; then
  $CC -O2 -Wall -DWITH_GLSL tools/test_translate.c "$OUT/new.o" "$OUT/old.o" -o "$OUT/test_translate" \
    -lshaderc_shared -lSPIRV-Tools-shared
else
  $CC -O2 -Wall tools/test_translate.c "$OUT/new.o" "$OUT/old.o" -o "$OUT/test_translate"
fi
"$OUT/test_translate" cases
rm -f "$OUT"/dump/*
PER=$(( (COUNT + JOBS - 1) / JOBS ))
i=0
pids=""
while [ $i -lt "$JOBS" ]; do
  "$OUT/test_translate" runtime/nvn/maxwell/translate.c "$PER" $((i * 7919 + ${SEED:-1})) "$MODE" "$OUT/dump" > "$OUT/log_$i.txt" 2>&1 &
  pids="$pids $!"
  i=$((i + 1))
done
status=0
for pid in $pids; do
  wait "$pid" || status=1
done
i=0
while [ $i -lt "$JOBS" ]; do
  cat "$OUT/log_$i.txt"
  i=$((i + 1))
done
exit "$status"
