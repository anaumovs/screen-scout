#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product ScreenScout
swift build -c release --product ClickTestPad
app_path="$PWD/dist/Screen Scout.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp .build/release/ScreenScout "$app_path/Contents/MacOS/ScreenScout"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
swiftc -framework AppKit Scripts/make-icon.swift -o .build/make-icon
.build/make-icon "$app_path/Contents/Resources" "$PWD/Resources/ScreenScoutIcon.png"
codesign --force --sign - --identifier local.screenscout.app "$app_path"
codesign --verify --deep --strict "$app_path"
pad_path="$PWD/dist/Click Test Pad.app"
mkdir -p "$pad_path/Contents/MacOS"
cp .build/release/ClickTestPad "$pad_path/Contents/MacOS/ClickTestPad"
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
