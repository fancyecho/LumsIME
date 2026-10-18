#!/bin/zsh
# Measures typo correction: how often a typo's intended word ranks 1st / top 3 / top 7 /
# within three pages, and how often correction changes what correctly typed input shows.
# Deploys into build/typo/user, so your own dictionary is untouched.
set -euo pipefail
cd "${0:A:h}/.."
OUT=build/typo
BIN=build/LumaIME.app/Contents/MacOS/LumaIME
mkdir -p $OUT/user
python3 tests/typo/gen.py vendor/rime-ice/cn_dicts $OUT
cat $OUT/control.tsv $OUT/typos.tsv tests/typo/sentences.tsv > $OUT/all.tsv
export LUMA_USER_DIR=$PWD/$OUT/user

echo "== typo recall (input → intended word)"
$BIN --eval $OUT/all.tsv 2>/dev/null | grep -v deployed

echo "== correctly typed input: changes caused by correction"
$BIN --eval $OUT/hard.tsv --dump --no-typo 2>/dev/null | grep -v deployed > $OUT/off.tsv
$BIN --eval $OUT/hard.tsv --dump 2>/dev/null | grep -v deployed > $OUT/on.tsv
paste $OUT/off.tsv $OUT/on.tsv | python3 -c '
import sys
group = dict(l.rstrip("\n").split("\t")[::2] for l in open(sys.argv[1]))
n, first, top3 = {}, {}, {}
for line in sys.stdin:
    text, off, _, on = line.rstrip("\n").split("\t")
    g = group[text]; n[g] = n.get(g, 0) + 1
    if off.split(" ")[0] != on.split(" ")[0]: first[g] = first.get(g, 0) + 1
    if off != on: top3[g] = top3.get(g, 0) + 1
for g in n:
    print(f"{g:8} first changed {first.get(g, 0):3}/{n[g]}   top 3 changed {top3.get(g, 0):4}/{n[g]}")
' $OUT/hard.tsv
