#!/bin/zsh
# Measures everyday typing: how often the intended text comes first, on tests/daily (clauses of
# chat, work and writing in full pinyin; short ones also as abbreviations).
#   *-dev     used to tune settings (Support/rime/luma.yaml, luma_chat.txt, luma_fix.lua)
#   *-test    the other half, not looked at while tuning
#   fresh-*   written after tuning, never tuned on
#   keep-*    sentences whose 在 / 把 / 以下 are right: luma_fix.lua must leave them alone
# Deploys into build/daily/user, with the grammar model linked in when vendor/models has it
# (scripts/fetch_model.sh), so your own dictionary is untouched. Extra arguments go to --eval,
# e.g. --misses to list what didn't come first.
set -euo pipefail
cd "${0:A:h}/.."
OUT=build/daily
mkdir -p $OUT/user
models=(vendor/models/*.gram(N))
if (( $#models )); then
  for m in $models; do ln -sf $PWD/$m $OUT/user/; done
else
  echo "(no grammar model in vendor/models: measuring without it; scripts/fetch_model.sh gets it)"
fi
LUMA_USER_DIR=$PWD/$OUT/user build/LumaIME.app/Contents/MacOS/LumaIME --eval tests/daily/daily.tsv "$@" 2>/dev/null \
  | grep -v deployed
