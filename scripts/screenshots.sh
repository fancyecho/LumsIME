#!/bin/zsh
# Renders the panel in dark and light mode via the playground and saves docs/images/*.png.
set -euo pipefail
cd "${0:A:h}/.."
BIN=build/LumaIME.app/Contents/MacOS/LumaIME
OUT=docs/images
mkdir -p $OUT

# shoot <name> <playground args…>
shoot() {
  local name=$1; shift
  local log=$(mktemp)
  $BIN --still "$@" 2>$log &
  local pid=$!
  for _ in {1..80}; do grep -q '^CAPTURE' $log && break; sleep 0.1; done
  local rect=$(grep '^CAPTURE' $log | head -1 | cut -d' ' -f2)
  sleep 0.3
  screencapture -x -o -R "$rect" "$OUT/$name.png"
  kill $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  rm -f $log
  echo "$OUT/$name.png"
}

for look in dark light; do
  shoot lumen-$look --appearance $look
  shoot toast-$look --appearance $look --toast zh
done
# Typo correction: "mieyoushijian" → 没有时间.
shoot typo-lumen-dark --appearance dark --type mieyoushijian
