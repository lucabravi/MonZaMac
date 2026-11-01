#!/bin/sh
# Developer step: grow the shader catalog with the recipes play sessions collected (run it again after each session).
# The journal holds hashes and pipeline state only; the catalog needs to know where each shader sits in the game's
# files, which an index of those files gives (built once, slow). Everything stays under ignored paths.
#   tools/shader_catalog_from_journal.sh [game-dir] [data-root]      (defaults: extracted, .)
# Needs the native decoder (tools/shader_decode: cargo build --release) for the archive shaders.
set -eu
cd "$(dirname "$0")/.."
GAME=${1:-extracted}; DATA=${2:-.}
PY=${PYTHON:-python3}; [ -x tools/venv/bin/python ] && PY=tools/venv/bin/python
DECODER=${DECODER:-build/shader-decode/release/monzamac-shader-decode}
INDEX=build/shader-index
JOURNAL=$DATA/cache/shader-recipes/recipes.jsonl
OUT=$DATA/cache/shader-preparation
[ -f "$JOURNAL" ] || { echo "no journal at $JOURNAL: play with 'Collect new shader recipes' on first" >&2; exit 1; }
export PYTHONPATH=tools
if [ ! -f $INDEX/index.json ] || [ -n "${REINDEX:-}" ]; then
    [ -x "$DECODER" ] || { echo "decoder not found ($DECODER): build tools/shader_decode or set DECODER" >&2; exit 1; }
    echo "indexing the game files (once, a few minutes)..."
    $PY tools/za/shader_inputs.py "$GAME" $INDEX --ooz-exe "$DECODER"
fi
mkdir -p "$OUT"
[ -f "$OUT/catalog.json" ] && cp "$OUT/catalog.json" "$OUT/catalog.json.bak"
rm -f build/catalog.tmp.json
# the installed catalog stays in: the game removes the journal rows a catalog already covers
SOURCES="$JOURNAL"; [ -f "$OUT/catalog.json" ] && SOURCES="$OUT/catalog.json $JOURNAL"
$PY tools/za/shader_catalog.py export $SOURCES $INDEX/index.json build/catalog.tmp.json --allow-partial
$PY tools/za/shader_catalog.py check build/catalog.tmp.json
mv build/catalog.tmp.json "$OUT/catalog.json"
echo "installed $OUT/catalog.json: the game prepares it at the next start (Shaders > Prepare known shaders)"
