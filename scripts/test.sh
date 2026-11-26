#!/bin/zsh
# Runs unit tests, Rime self-test, custom page_size key probe, and daily evaluation in isolated scratch dirs.
set -euo pipefail
cd "${0:A:h}/.."

BIN=build/LumaIME.app/Contents/MacOS/LumaIME
if [[ ! -x "$BIN" ]]; then
  echo "build/LumaIME.app not found; run ./scripts/build.sh first" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "== unit tests & selftest"
LUMA_USER_DIR="$TMP/u1" "$BIN" --test --selftest 2>/dev/null

echo "== custom page_size=5 key probe"
mkdir -p "$TMP/u2"
cat > "$TMP/u2/default.custom.yaml" <<'YAML'
patch:
  schema_list:
    - schema: rime_ice
  menu/page_size: 5
YAML
LUMA_USER_DIR="$TMP/u2" "$BIN" --keys "nihao 1 shijie right space S+H i" 2>/dev/null

echo "== vertical layout key probe"
LUMA_USER_DIR="$TMP/u2" "$BIN" --layout vertical --keys "nihao space" 2>/dev/null

echo "== daily sentence eval"
./scripts/eval_daily.sh
