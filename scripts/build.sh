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
[[ -f build/luma.pdf ]] || swift scripts/make_icon.swift build/luma.pdf
cp build/luma.pdf $C/Resources/luma.pdf

mkdir -p $C/Resources/Licenses
cp LICENSE $C/Resources/Licenses/LumaIME.LICENSE
cp vendor/librime/licenses/*.LICENSE $C/Resources/Licenses/

cp -L $RIME/lib/librime.1.dylib $C/Frameworks/
cp -R $RIME/lib/rime-plugins $C/Frameworks/

rsync -a --exclude others --exclude build --exclude '*.md' --exclude AGENTS.md vendor/rime-ice/ $C/SharedSupport/

codesign --force --sign - $C/Frameworks/librime.1.dylib $C/Frameworks/rime-plugins/*.dylib
codesign --force --sign - $APP
echo "built $APP"
