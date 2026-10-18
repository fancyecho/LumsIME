#!/bin/zsh
# Builds build/LumaIME.app with swiftc (no Xcode project needed).
set -euo pipefail
cd "${0:A:h}/.."

RIME=vendor/librime/dist
APP=build/LumaIME.app
C=$APP/Contents

rm -rf $APP
mkdir -p $C/MacOS $C/Frameworks $C/Resources/zh_CN.lproj $C/SharedSupport

# ARCHS="arm64" for a quicker single-arch build while iterating.
slices=()
for arch in ${=ARCHS:-arm64 x86_64}; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 \
    -import-objc-header Support/Bridging.h -I $RIME/include \
    -L $RIME/lib -lrime -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -framework Cocoa -framework InputMethodKit -framework SwiftUI -framework Carbon \
    -module-cache-path build/cache Sources/*.swift -o build/LumaIME-$arch
  slices+=(build/LumaIME-$arch)
done
lipo -create $slices -output $C/MacOS/LumaIME
rm -f $slices

cp Support/Info.plist $C/Info.plist
cp Support/InfoPlist.strings $C/Resources/zh_CN.lproj/
if [[ ! -f build/icons/luma.icns || scripts/make_icon.swift -nt build/icons/luma.icns ]]; then
  swift scripts/make_icon.swift build/icons
  iconutil -c icns build/icons/AppIcon.iconset -o build/icons/luma.icns
fi
cp build/icons/luma.icns build/icons/menu.pdf $C/Resources/

mkdir -p $C/Resources/Licenses
cp LICENSE $C/Resources/Licenses/LumaIME.LICENSE
cp vendor/librime/licenses/*.LICENSE $C/Resources/Licenses/

cp -L $RIME/lib/librime.1.dylib $C/Frameworks/
cp -R $RIME/lib/rime-plugins $C/Frameworks/

rsync -a --exclude others --exclude build --exclude '*.md' --exclude AGENTS.md vendor/rime-ice/ $C/SharedSupport/

# Typo correction: a second prism with typo spellings, its translator and the deciding filter.
python3 scripts/make_typo_schema.py vendor/rime-ice/rime_ice.schema.yaml $C/SharedSupport/luma_typo.schema.yaml
cp Support/rime/lua/luma_typo.lua $C/SharedSupport/lua/
# rime-ice's long-word filter must not pull corrections (comments marked "\1") onto page one.
python3 - $C/SharedSupport/lua/long_word_filter.lua <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'elseif leng <= firstWordLength or cand.text:find("[%a%d]") then'
assert old in s, 'long_word_filter.lua changed upstream; update scripts/build.sh'
open(p, 'w').write(s.replace(old, old[:-5] + ' or cand.comment:sub(1, 1) == "\\1" then'))
PY
printf '\n# Luma\n__patch:\n  - luma_typo.schema:/luma_patch\n' >> $C/SharedSupport/rime_ice.schema.yaml

codesign --force --sign - $C/Frameworks/librime.1.dylib $C/Frameworks/rime-plugins/*.dylib
codesign --force --sign - $APP
echo "built $APP"
