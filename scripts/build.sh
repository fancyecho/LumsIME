#!/bin/zsh
# Builds build/LumaIME.app with swiftc (no Xcode project needed).
set -euo pipefail
cd "${0:A:h}/.."

RIME=vendor/librime/dist
APP=build/LumaIME.app
C=$APP/Contents

rm -rf $APP
mkdir -p $C/MacOS $C/Frameworks $C/Resources/zh_CN.lproj $C/Resources/zh-Hans.lproj $C/Resources/en.lproj $C/SharedSupport

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
cp Support/InfoPlist.strings $C/Resources/zh-Hans.lproj/
cp Support/zh-Hans.lproj/Localizable.strings $C/Resources/zh-Hans.lproj/
cp Support/en.lproj/Localizable.strings $C/Resources/en.lproj/
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

# Pre-extract unique pinyin syllables (~410 entries, ~2 KB) so runtime never scans 8105.dict.yaml.
python3 - $C/SharedSupport/cn_dicts/8105.dict.yaml $C/SharedSupport/syllables.txt <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
syls = set()
with open(src, encoding='utf-8') as f:
    for line in f:
        if line.startswith('#'):
            continue
        parts = line.rstrip('\n').split('\t')
        if len(parts) >= 2 and parts[1]:
            syls.add(parts[1])
with open(dst, 'w', encoding='utf-8') as out:
    out.write('\n'.join(sorted(syls)) + '\n')
PY

# Typo correction: a second prism with typo spellings, its translator and the deciding filter.
python3 scripts/make_typo_schema.py vendor/rime-ice/rime_ice.schema.yaml $C/SharedSupport/luma_typo.schema.yaml
cp Support/rime/lua/luma_typo.lua Support/rime/lua/luma_kind.lua Support/rime/lua/luma_fix.lua $C/SharedSupport/lua/
cp Support/rime/luma.yaml Support/rime/luma_chat.dict.yaml $C/SharedSupport/
# rime-ice's long-word filter must not pull corrections (comments marked "\1") onto page one.
python3 - $C/SharedSupport/lua/long_word_filter.lua <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'elseif leng <= firstWordLength or cand.text:find("[%a%d]") then'
assert old in s, 'long_word_filter.lua changed upstream; update scripts/build.sh'
open(p, 'w').write(s.replace(old, old[:-5] + ' or cand.comment:sub(1, 1) == "\\1" then'))
PY
# An explicit __patch turns off Rime's automatic rime_ice.custom.yaml patch, so list it last.
printf '\n# Luma\n__patch:\n  - luma_typo.schema:/luma_patch\n  - luma:/patch\n  - rime_ice.custom:/patch?\n' >> $C/SharedSupport/rime_ice.schema.yaml
# Chat phrases first: for a word in several tables rime keeps the first table's weight.
python3 - $C/SharedSupport/rime_ice.dict.yaml <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'import_tables:\n  - cn_dicts/8105'
assert old in s, 'rime_ice.dict.yaml changed upstream; update scripts/build.sh'
open(p, 'w').write(s.replace(old, 'import_tables:\n  - luma_chat\n  - cn_dicts/8105'))
PY

# Sign in a scratch folder: files unpacked from an archive carry quarantine/provenance
# attributes, and inside an iCloud-managed folder (such as ~/Documents) the system keeps adding
# Finder info to the bundle; codesign rejects both as "detritus". install.sh and package.sh copy
# the bundle out with --norsrc --noextattr, so what gets installed or shipped stays valid.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc --noextattr $APP $STAGE/LumaIME.app
codesign --force --sign - $STAGE/LumaIME.app/Contents/Frameworks/librime.1.dylib \
  $STAGE/LumaIME.app/Contents/Frameworks/rime-plugins/*.dylib
codesign --force --sign - $STAGE/LumaIME.app
codesign --verify --deep --strict $STAGE/LumaIME.app
rm -rf $APP
ditto --norsrc --noextattr $STAGE/LumaIME.app $APP
echo "built $APP"
