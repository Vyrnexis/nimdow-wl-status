#!/bin/bash
# Process names are truncated to 15 chars ("nimdow-wl-statu"); match on that, not -f.
pkill -x nimdow-wl-statu
nim c -d:release -d:lto -o:bin/nimdow-wl-status src/nimdow_wl_status.nim
./bin/nimdow-wl-status &
