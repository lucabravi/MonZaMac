#!/bin/bash
# Starts the game and restarts it if it freezes while loading (a known intermittent startup deadlock): during the first
# 120 s the log must keep growing, else the process is killed and started again. Closing a frozen window also starts the next
# try; closing a running game ends the loop.
# usage: tools/play_retry.sh [extra monzamac args]   (run from the project folder)
LOG=${LOG:-/tmp/monzamac-play.log}
for try in $(seq 1 20); do
  ./build/za202/monzamac extracted --play "$@" > "$LOG" 2>&1 &
  pid=$!
  last=0; stale=0
  for i in $(seq 1 40); do                       # 40 x 3 s = 120 s watch
    sleep 3
    n=$(grep -c "^\[metal\] t=" "$LOG")
    if [ "$n" = "$last" ]; then stale=$((stale + 1)); else stale=0; fi
    last=$n
    if ! kill -0 $pid 2>/dev/null; then          # the window was closed
      [ $stale -ge 2 ] && { echo "closed while frozen (try $try): restarting"; continue 2; }  # frozen: next try
      exit 0                                     # closed on purpose
    fi
    if [ $n -gt 0 ] && [ $stale -ge 5 ]; then echo "frozen at load (try $try): restarting"; kill $pid; sleep 2; continue 2; fi
  done
  wait $pid; exit 0
done
