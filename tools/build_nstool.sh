#!/bin/bash
# Builds nstool (jakcron/nstool, MIT), used to pull exefs/romfs out of your own game dump (.nsp / .xci).
# Clones it (with its submodules) into tools/nstool/ and builds it there; nothing from it is committed.
# Result: tools/nstool/bin/nstool. Needs git and the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=tools/nstool
if [ ! -d "$DIR/.git" ]; then
    git clone --recurse-submodules https://github.com/jakcron/nstool "$DIR"
else
    git -C "$DIR" submodule update --init --recursive
fi
make -C "$DIR" deps -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
make -C "$DIR" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
echo "built $DIR/bin/nstool"
