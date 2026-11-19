#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for arch in arm64 x86_64; do
    swift build -c release --arch "$arch" --product ScreenScout
    swift build -c release --arch "$arch" --product ClickTestPad
done
universal_binary() {
    lipo -create ".build/arm64-apple-macosx/release/$1" ".build/x86_64-apple-macosx/release/$1" -output "$2"
}
app_path="$PWD/dist/Screen Scout.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
universal_binary ScreenScout "$app_path/Contents/MacOS/ScreenScout"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
swiftc -framework AppKit Scripts/make-icon.swift -o .build/make-icon
.build/make-icon "$app_path/Contents/Resources" "$PWD/Resources/ScreenScoutIcon.png"
codesign --force --sign - --identifier local.screenscout.app "$app_path"
codesign --verify --deep --strict "$app_path"
ditto -c -k --norsrc --noextattr --keepParent "$app_path" "$PWD/dist/Screen-Scout-macOS.zip"
pad_path="$PWD/dist/Click Test Pad.app"
mkdir -p "$pad_path/Contents/MacOS"
universal_binary ClickTestPad "$pad_path/Contents/MacOS/ClickTestPad"
python3 - "$pad_path/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({'CFBundleExecutable':'ClickTestPad','CFBundleIdentifier':'local.screenscout.testpad','CFBundleName':'Click Test Pad','CFBundlePackageType':'APPL','CFBundleVersion':'1','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True},output)
PY
codesign --force --sign - --identifier local.screenscout.testpad "$pad_path"
codesign --verify --deep --strict "$pad_path"
package_path="$PWD/dist/Screen Scout package"
mkdir -p "$package_path"
ditto "$app_path" "$package_path/Screen Scout.app"
ditto "$pad_path" "$package_path/Click Test Pad.app"
cp README.md VERIFICATION.md "$package_path/"
ditto -c -k --sequesterRsrc --keepParent "$package_path" "$PWD/dist/Screen Scout.zip"
printf '\nRunnable app: %s\n' "$app_path"
