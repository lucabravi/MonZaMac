#!/bin/bash
# Builds nstool (jakcron/nstool, MIT), used to pull exefs/romfs out of your own game dump (.nsp / .xci).
# Clones it (with its submodules) into tools/nstool/ and builds it there; nothing from it is committed.
# Result: tools/nstool/bin/nstool. Needs git and the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
DIR=tools/nstool
REV=cfb826ca6c165fbcd816fd7949df88ef3d72a948
PATCH="$ROOT/tools/nstool-path-safety.patch"
HEADER="$ROOT/tools/nstool_path_safety.hpp"
export MACOSX_DEPLOYMENT_TARGET=${MACOS_MIN:-15.0}
cloned=0
patch_applied=0
if [ ! -d "$DIR/.git" ]; then
    git clone --no-checkout https://github.com/jakcron/nstool "$DIR"
    cloned=1
fi
if [ "$cloned" = 0 ]; then
    status=$(git -C "$DIR" status --porcelain --untracked-files=all --ignore-submodules)
    if [ -n "$status" ]; then
        paths=$(printf '%s\n' "$status" | sed 's/^...//' | LC_ALL=C sort)
        expected=$(printf '%s\n' "src/FsProcess.cpp" "src/MonZaMacPathSafety.hpp" | LC_ALL=C sort)
        if git -C "$DIR" apply --unidiff-zero --reverse --check "$PATCH" &&
           [ "$paths" = "$expected" ] &&
           git -C "$DIR" diff --binary --unified=0 -- src/FsProcess.cpp | cmp -s - "$PATCH" &&
           cmp -s "$HEADER" "$DIR/src/MonZaMacPathSafety.hpp"; then
            patch_applied=1
        else
            echo "nstool has local changes; left untouched" >&2; exit 1
        fi
    fi
fi
if [ "$cloned" = 1 ] || [ "$(git -C "$DIR" rev-parse HEAD 2>/dev/null || true)" != "$REV" ]; then
    if [ "$patch_applied" = 1 ]; then
        git -C "$DIR" apply --unidiff-zero --reverse "$PATCH"
        rm "$DIR/src/MonZaMacPathSafety.hpp"
    fi
    git -C "$DIR" fetch origin "$REV"
    git -C "$DIR" checkout --detach "$REV"
fi
git -C "$DIR" submodule update --init --recursive
if git -C "$DIR" apply --unidiff-zero --reverse --check "$PATCH" >/dev/null 2>&1; then
	:
else
	if ! git -C "$DIR" apply --unidiff-zero --check "$PATCH"; then
		echo "nstool path-safety patch no longer applies to $REV" >&2; exit 1
	fi
	git -C "$DIR" apply --unidiff-zero "$PATCH"
fi
cp "$HEADER" "$DIR/src/MonZaMacPathSafety.hpp"
make -C "$DIR" deps -j"${JOBS:-8}"
make -C "$DIR" -j"${JOBS:-8}"
echo "built $DIR/bin/nstool"
