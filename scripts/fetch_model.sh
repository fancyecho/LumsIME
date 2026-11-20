#!/bin/zsh
# Downloads the grammar model into vendor/models for the evals (install.sh also copies it into
# ~/Library/Luma, so the app doesn't fetch it again). The app downloads it by itself otherwise.
set -euo pipefail
cd "${0:A:h}/.."
URL=https://github.com/amzxyz/rime-wanxiang-data/releases/download/LTS/wanxiang-lts-zh-hans.gram
SHA=e9ddd501b7d536bc5ea1346f8f900ae49a719a05be349e0a17cb27e717143ca5  # keep in sync with Sources/GrammarModel.swift
OUT=vendor/models/wanxiang-lts-zh-hans.gram
mkdir -p vendor/models
if [[ ! -f $OUT ]]; then
  curl -fL --progress-bar -o $OUT.part $URL
  mv $OUT.part $OUT
fi
echo "$SHA  $OUT" | shasum -a 256 -c -
