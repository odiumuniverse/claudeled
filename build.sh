#!/bin/sh
# Build claudeled.app. The same binary is also the CLI, so the cask symlinks it
# into PATH rather than shipping a second executable.
set -e
cd "$(dirname "$0")"

APP="build/claudeled.app"
VERSION="${VERSION:-0.1.0}"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O claudeled.swift -o "$APP/Contents/MacOS/claudeled"

# Regenerate the icon if it is missing, so a fresh clone builds a complete bundle.
if [ ! -f Resources/claudeled.icns ]; then
    swiftc -O make-icon.swift -o build/make-icon
    ./build/make-icon Resources/claudeled.iconset
    iconutil -c icns Resources/claudeled.iconset -o Resources/claudeled.icns
fi
cp Resources/claudeled.icns "$APP/Contents/Resources/claudeled.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>claudeled</string>
    <key>CFBundleDisplayName</key><string>claudeled</string>
    <key>CFBundleIdentifier</key><string>com.odiumuniverse.claudeled</string>
    <key>CFBundleExecutable</key><string>claudeled</string>
    <key>CFBundleIconFile</key><string>claudeled</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- menu bar only: no Dock icon, no app switcher entry -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: SMAppService ("Start at login") refuses to register an unsigned bundle.
codesign --force --sign - "$APP"

echo "built $APP"
echo "app:  open $APP"
echo "cli:  $APP/Contents/MacOS/claudeled --help"

# `./build.sh release` also produces the archive the cask downloads.
if [ "$1" = "release" ]; then
    cp -R completions "build/completions"
    ( cd build && zip -qr "claudeled-$VERSION.zip" claudeled.app completions )
    echo "release: build/claudeled-$VERSION.zip"
    echo "sha256:  $(shasum -a 256 "build/claudeled-$VERSION.zip" | cut -d' ' -f1)"
fi
