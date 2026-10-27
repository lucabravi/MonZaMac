#!/bin/bash
# Source-checkout interface to the same local importer the app bundles.
# usage: tools/extract_game.sh <base.nsp|base.xci> <update.nsp>
# User-owned prod.keys: .keys/prod.keys, or KEYS=<file>. No tool diagnostics/key material are printed.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE=${1:?usage: tools/extract_game.sh <base.nsp|base.xci> <update.nsp>}
UPDATE=${2:?the v2.0.2 update is required}
KEYS=${KEYS:-.keys/prod.keys}
NSTOOL=tools/nstool/bin/nstool
OUT=extracted
[ -x "$NSTOOL" ] || { echo "nstool missing: run tools/build_nstool.sh first"; exit 1; }
if [ -e "$OUT/exefs" ] || [ -e "$OUT/romfs" ] || [ -L "$OUT" ]; then
    echo "$OUT/ already has game files or is a link: move it away first"; exit 1
fi
mkdir -p "$OUT" build
python3 tools/game_extract.py --base "$BASE" --update "$UPDATE" --keys "$KEYS" --output "$OUT" \
    --nstool "$NSTOOL" --build-id b1f12fd919eae86a
clang -O2 -Iruntime -o build/romfs_pack tools/za/romfs_pack.c runtime/romfs_build.c
build/romfs_pack "$OUT/romfs" "$OUT/romfs.bin"
echo "done: $OUT/ is ready. Next: gmake B=build/za202 GEN=generated-202 gen"
