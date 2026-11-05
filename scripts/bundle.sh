#!/bin/bash
# Builds build/Tacho.app (universal, ad-hoc signed) and its zip and dmg, then prints their SHA-256.
# Usage: scripts/bundle.sh <version>
set -euo pipefail

if [ $# -ne 1 ] || [ -z "$1" ]; then
    echo "usage: scripts/bundle.sh <version>" >&2
    exit 64
fi
version=$1
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64 --product Tacho

# Where a universal build lands depends on the build system: .build/apple/Products/Release with xcode, .build/out/Products/Release
# with swiftbuild. SwiftPM knows which, given the same flags.
products=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
app=build/Tacho.app
zip=build/Tacho-$version.zip
dmg=build/Tacho-$version.dmg

# Tacho_TachoKit.bundle holds prices.json and Tacho_Tacho.bundle the strings: without either, Bundle.module stops the app.
for required in "$products" "$products/Tacho" "$products/Tacho_TachoKit.bundle" "$products/Tacho_Tacho.bundle"; do
    if [ ! -e "$required" ]; then
        echo "error: $required is missing" >&2
        exit 1
    fi
done

rm -rf "$app"
rm -f "$zip"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$products/Tacho" "$app/Contents/MacOS/Tacho"
cp -R "$products"/*.bundle "$app/Contents/Resources/"
cp packaging/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp THIRD-PARTY-NOTICES.md "$app/Contents/Resources/THIRD-PARTY-NOTICES.md"
cp packaging/Info.plist "$app/Contents/Info.plist"
# plutil, not sed: any version string stays a valid plist value.
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"

codesign --force --deep --sign - "$app"
# --norsrc: extended attributes would go in as ._ files, which plain unzip leaves inside the bundle, breaking its signature.
ditto -c -k --norsrc --keepParent "$app" "$zip"
# hdiutil can fail with "Resource busy" though nothing holds the image a moment later, here and on CI runners.
attempts=5
attempt=1
until hdiutil create -volname Tacho -srcfolder "$app" -ov -format UDZO "$dmg"; do
    status=$?
    if [ "$attempt" -ge "$attempts" ]; then
        echo "error: hdiutil failed $attempts times" >&2
        exit "$status"
    fi
    echo "hdiutil failed, trying again in $attempt s" >&2
    sleep "$attempt"
    attempt=$((attempt + 1))
done
shasum -a 256 "$zip" "$dmg"
