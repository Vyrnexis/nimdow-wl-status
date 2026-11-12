#!/bin/bash
# Rebuild like the nimble / PKGBUILD build (release), then restart the running feeder.
set -e
cd "$(dirname "$(readlink -f "$0")")"
nim c -d:release --hints:off --path:"$(nimble path parsetoml)" -o:bin/nimdow-wl-status src/nimdow_wl_status.nim
# Process names are truncated to 15 chars ("nimdow-wl-statu"); match on that, not -f.
pkill -x nimdow-wl-statu || true
./bin/nimdow-wl-status &
