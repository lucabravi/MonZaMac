#!/bin/bash
# Plays the game and, when it freezes, saves where every thread is stuck (macOS `sample`): the log alone doesn't say.
# A freeze is the fps line ("[metal] t=") stopping for STALL seconds while the window is visible (a covered window
# presents nothing, so it doesn't count); one sample per freeze. Ctrl+C also samples, then ends the game.
# usage: tools/hang_sample.sh [extra monzamac args]   (run from the project folder)
#   EXE (default build/za202/monzamac), STALL (default 20), OUT (default build/hang): play.log, sample-<time>.txt
#   WAIT_DUMP (default 30, 0 off): every that many seconds the log gets what each guest thread waits on, with the last
#   events of the keys they park on (kernel.c LARECOMP_WAIT_DUMP + LARECOMP_KEY_RING): a sample only shows the threads
#   parked in the kernel, this says on what and who last signalled it
cd "$(dirname "$0")/.."
EXE=${EXE:-build/za202/monzamac}
STALL=${STALL:-20}
OUT=${OUT:-build/hang}
mkdir -p "$OUT"
LOG="$OUT/play.log"
WAIT_DUMP=${WAIT_DUMP:-30}
[ "$WAIT_DUMP" != 0 ] && export LARECOMP_WAIT_DUMP=$WAIT_DUMP LARECOMP_KEY_RING=1

take() {  # $1: why
    local f; f="$OUT/sample-$(date +%H%M%S).txt"
    echo "$1: sampling the threads (5 s) -> $f"
    sample "$pid" 5 -file "$f" >/dev/null 2>&1 || echo "  sample failed"
    tail -5 "$LOG" | sed 's/^/  log: /'
}

"$EXE" extracted --play "$@" > "$LOG" 2>&1 &  # (in the background: Ctrl+C reaches only this script)
pid=$!
trap 'take "Ctrl+C"; kill $pid 2>/dev/null; exit 0' INT
echo "playing (pid $pid), log $LOG; a freeze of ${STALL}s is sampled, Ctrl+C samples and quits"
last=0; quiet=0; sampled=0
while kill -0 $pid 2>/dev/null; do
    sleep 3
    n=$(grep -c "^\[metal\] t=" "$LOG")
    hidden=$(grep "^\[metal\] window " "$LOG" | tail -1 | grep -c hidden)
    if [ "$n" != "$last" ] || [ "$hidden" = 1 ]; then quiet=0; sampled=0; else quiet=$((quiet + 3)); fi
    last=$n
    if [ "$n" -gt 0 ] && [ $quiet -ge "$STALL" ] && [ $sampled = 0 ]; then take "no frame for ${quiet}s"; sampled=1; fi
done
wait $pid
