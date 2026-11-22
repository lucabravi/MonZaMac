#!/bin/sh
# Every test in tools/test_*.py that needs no game files or arguments, with the project's Python (tools/venv: the
# lifter tests need unicorn and lz4, which the system Python lacks). Prints the failing ones and exits 1 if any failed.
# Not here: test_game_quit.py (the game's files and a built binary), test_lift.py (an NSO), test_shader_decoder.py
# (the shader decoder binary: gmake test-shader-catalog runs it), test_lumiose_pictures.py (the game files).
cd "$(dirname "$0")/.." || exit 1
PY=${PY:-tools/venv/bin/python}
[ -x "$PY" ] || { echo "no $PY: set the tools up first (AGENTS.md, Setup) or pass PY=<python with capstone unicorn lz4 zstandard>" >&2; exit 2; }
failed=0 n=0
for t in tools/test_*.py; do
    case "$t" in tools/test_game_quit.py|tools/test_lift.py|tools/test_shader_decoder.py|tools/test_lumiose_pictures.py) continue ;; esac
    n=$((n + 1))
    if ! "$PY" "$t" >/tmp/monzamac-test.$$ 2>&1 </dev/null; then
        failed=$((failed + 1))
        echo "FAIL $t"
        tail -5 /tmp/monzamac-test.$$ | sed 's/^/    /'
    fi
done
rm -f /tmp/monzamac-test.$$
echo "$((n - failed)) of $n tests passed"
[ "$failed" -eq 0 ]
