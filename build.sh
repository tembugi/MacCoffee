#!/bin/bash
# Builds build/MacCoffee.app. Pass --install to copy it to /Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/MacCoffee.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

[ -f Resources/AppIcon.icns ] || xcrun swift Scripts/make-icon.swift Resources

# One app for both Apple silicon and Intel Macs.
for arch in arm64 x86_64; do
    xcrun swiftc -parse-as-library -O -swift-version 5 -target "$arch-apple-macos14.0" \
        Sources/MacCoffee.swift -o "build/MacCoffee-$arch"
done
lipo -create build/MacCoffee-arm64 build/MacCoffee-x86_64 -output "$APP/Contents/MacOS/MacCoffee"
rm build/MacCoffee-arm64 build/MacCoffee-x86_64

cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    # Quitting turns lid-closed mode off, which puts a Mac with a shut lid to sleep.
    if ioreg -r -c IOPMrootDomain -d 1 | grep -q '"AppleClamshellState" = Yes'; then
        echo "Lid is closed: not restarting MacCoffee. Run again with the lid open." >&2
        exit 1
    fi
    pkill -x MacCoffee || true
    while pgrep -x MacCoffee >/dev/null; do sleep 0.2; done
    rm -rf /Applications/MacCoffee.app
    cp -R "$APP" /Applications/
    open /Applications/MacCoffee.app
    echo "Installed and launched /Applications/MacCoffee.app"
fi
