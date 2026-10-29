#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
clang -O2 -Wl,-dead_strip tools/test_za_npc_capacity.c runtime/hle/za_mods.c -o "$test_dir/test"
for mode in unknown disabled enabled; do
    "$test_dir/test" "$mode"
done
printf 'NPC capacity: version, opt-out, initialization, guards and writes passed\n'
