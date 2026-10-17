#!/bin/zsh
# Renders each theme in dark and light mode via the playground and saves docs/images/<theme>-<appearance>.png.
set -euo pipefail
cd "${0:A:h}/.."
BIN=build/LumaIME.app/Contents/MacOS/LumaIME
OUT=docs/images
mkdir -p $OUT
for theme in ${=THEMES:-ink lumen precision}; do
  for look in dark light; do
    log=$(mktemp)
    $BIN --still --theme $theme --appearance $look 2>$log &
    pid=$!
    for _ in {1..80}; do grep -q '^CAPTURE' $log && break; sleep 0.1; done
    rect=$(grep '^CAPTURE' $log | head -1 | cut -d' ' -f2)
    sleep 0.3
    screencapture -x -o -R "$rect" "$OUT/$theme-$look.png"
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    rm -f $log
    echo "$OUT/$theme-$look.png"
  done
done
