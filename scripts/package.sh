#!/bin/zsh
# Builds a universal app and zips it for a GitHub release → dist/LumaIME.zip
set -euo pipefail
cd "${0:A:h}/.."
./scripts/build.sh
mkdir -p dist
rm -f dist/LumaIME.zip
ditto -c -k --norsrc --noextattr --keepParent build/LumaIME.app dist/LumaIME.zip
ls -lh dist/LumaIME.zip
shasum -a 256 dist/LumaIME.zip
