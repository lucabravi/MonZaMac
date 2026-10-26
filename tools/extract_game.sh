#!/bin/bash
# Turns your own dump (.nsp) into extracted/: exefs/ (main, main.npdm, rtld, sdk), romfs/ and romfs.bin.
# usage: tools/extract_game.sh <base.nsp> [update.nsp]
# Needs your prod.keys in .keys/ (or KEYS=<file>) and nstool (tools/build_nstool.sh builds it). With an update, its
# patch NCA is applied on top of the base one (nstool --basenca). Nothing here leaves your machine.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE=${1:?usage: tools/extract_game.sh <base.nsp> [update.nsp]}
UPDATE=${2:-}
KEYS=${KEYS:-.keys/prod.keys}
NSTOOL=tools/nstool/bin/nstool
WORK=build/extract-work
OUT=extracted

[ -x "$NSTOOL" ] || { echo "nstool missing: run tools/build_nstool.sh first"; exit 1; }
[ -f "$KEYS" ] || { echo "no keys at $KEYS: dump prod.keys from your own Switch (Lockpick_RCM) into .keys/"; exit 1; }
[ -f "$BASE" ] || { echo "not found: $BASE"; exit 1; }
[ -z "$UPDATE" ] || [ -f "$UPDATE" ] || { echo "not found: $UPDATE"; exit 1; }
if [ -e "$OUT/exefs" ] || [ -e "$OUT/romfs" ]; then echo "$OUT/ already has game files: move it away first"; exit 1; fi

# unpack an .nsp into $2 and print "<program nca> <ticket>" (the Program entry of its .cnmt.xml). It runs in $(...):
# its exit only leaves the subshell, so errors go to stderr and the caller checks the files it printed
unpack() {
    rm -rf "$2"; mkdir -p "$2"
    "$NSTOOL" -k "$KEYS" -x / "$2" "$1" > "$2.log" 2>&1 || { tail -5 "$2.log" >&2; exit 1; }
    local xml tik id
    xml=$(ls "$2"/*.cnmt.xml 2>/dev/null | head -1); tik=$(ls "$2"/*.tik 2>/dev/null | head -1)
    [ -n "$xml" ] && [ -n "$tik" ] || { echo "$1: no .cnmt.xml / .tik inside (is it a full .nsp with its ticket?)" >&2; exit 1; }
    id=$(python3 -I - "$xml" <<'PY'
import sys, xml.etree.ElementTree as E
for c in E.parse(sys.argv[1]).getroot().iter("Content"):
    if c.findtext("Type") == "Program": print(c.findtext("Id")); break
PY
)
    echo "$2/$id.nca $tik $(python3 -I -c "import sys,xml.etree.ElementTree as E;r=E.parse(sys.argv[1]).getroot();print(r.findtext('Version'))" "$xml")"
}

echo "== base: $BASE"
read -r BNCA BTIK BVER <<<"$(unpack "$BASE" "$WORK/base")"
[ -f "$BNCA" ] && [ -f "$BTIK" ] || { echo "unpacking $BASE failed (see $WORK/base.log)" >&2; exit 1; }
ARGS=(-k "$KEYS" --tik "$BTIK")
if [ -n "$UPDATE" ]; then
    echo "== update: $UPDATE"
    read -r UNCA UTIK UVER <<<"$(unpack "$UPDATE" "$WORK/update")"
    [ -f "$UNCA" ] && [ -f "$UTIK" ] || { echo "unpacking $UPDATE failed (see $WORK/update.log)" >&2; exit 1; }
    ARGS=(-k "$KEYS" --tik "$BTIK" --tik "$UTIK" --basenca "$BNCA"); NCA=$UNCA; echo "update version field: $UVER"
else
    NCA=$BNCA; echo "base version field: $BVER (no update given: this is the plain base game)"
fi

echo "== extracting exefs + romfs"
mkdir -p "$OUT"
"$NSTOOL" "${ARGS[@]}" -x /0 "$OUT/exefs" -x /1 "$OUT/romfs" "$NCA" > "$WORK/nca.log" 2>&1 || { tail -8 "$WORK/nca.log"; exit 1; }
for f in main main.npdm rtld sdk; do [ -f "$OUT/exefs/$f" ] || { echo "exefs/$f missing: see $WORK/nca.log"; exit 1; }; done
[ -d "$OUT/romfs/region_common" ] || echo "warning: romfs/region_common missing: wrong or partial dump?"

echo "== packing romfs.bin"
mkdir -p build
clang -O2 -Iruntime -o build/romfs_pack tools/za/romfs_pack.c runtime/romfs_build.c
build/romfs_pack "$OUT/romfs" "$OUT/romfs.bin" 2> "$WORK/pack.log" || { tr '\r' '\n' < "$WORK/pack.log" | tail -3; exit 1; }

rm -rf "$WORK"
echo "done: $OUT/ is ready. Next: gmake B=build/za202 GEN=generated-202 gen"
