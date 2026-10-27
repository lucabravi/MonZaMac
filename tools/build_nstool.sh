#!/bin/bash
# Builds nstool (jakcron/nstool, MIT), used to pull exefs/romfs out of your own game dump (.nsp / .xci).
# Clones it (with its submodules) into tools/nstool/ and builds it there; nothing from it is committed.
# Result: tools/nstool/bin/nstool. Needs git and the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=tools/nstool
REV=cfb826ca6c165fbcd816fd7949df88ef3d72a948
export MACOSX_DEPLOYMENT_TARGET=${MACOS_MIN:-15.0}
cloned=0
if [ ! -d "$DIR/.git" ]; then
    git clone --no-checkout https://github.com/jakcron/nstool "$DIR"
    cloned=1
fi
if [ "$cloned" = 0 ] && [ -n "$(git -C "$DIR" status --porcelain --ignore-submodules)" ]; then
    echo "nstool has local changes; left untouched" >&2; exit 1
fi
if [ "$cloned" = 1 ] || [ "$(git -C "$DIR" rev-parse HEAD 2>/dev/null || true)" != "$REV" ]; then
    git -C "$DIR" fetch origin "$REV"
    git -C "$DIR" checkout --detach "$REV"
fi
git -C "$DIR" submodule update --init --recursive
make -C "$DIR" deps -j"${JOBS:-8}"
make -C "$DIR" -j"${JOBS:-8}"
echo "built $DIR/bin/nstool"
