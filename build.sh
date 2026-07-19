#!/bin/sh
# Build claudeled.app. The same binary is also the CLI, so installing symlinks it
# into PATH rather than shipping a second executable.
#
#   ./build.sh            build into build/
#   ./build.sh test       run the checks over Core.swift
#   ./build.sh install    build, then install into /Applications and PATH
#   ./build.sh release    build, then zip the bundle for a GitHub release
set -e
cd "$(dirname "$0")"

APP="build/claudeled.app"
VERSION="${VERSION:-0.1.0}"
# Apple silicon Homebrew lives in /opt/homebrew and is already on PATH and fpath there.
if [ -z "$PREFIX" ]; then
    [ -d /opt/homebrew ] && PREFIX=/opt/homebrew || PREFIX=/usr/local
fi

if [ "$1" = "test" ]; then
    mkdir -p build
    swiftc -O Core.swift tests/main.swift -o build/tests
    exec ./build/tests
fi

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O Core.swift main.swift -o "$APP/Contents/MacOS/claudeled"

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

# Ad-hoc signature: SMAppService ("Start at login") refuses to register an unsigned
# bundle. Note that an ad-hoc identity changes with every build, so macOS sees a
# different app each time and the Input Monitoring grant has to be given again.
codesign --force --sign - "$APP"

echo "built $APP"

case "$1" in
install)
    # Replacing a running copy leaves a stale process holding the LEDs.
    pkill -f '/claudeled.app/Contents/MacOS/claudeled' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/claudeled.app
    cp -R "$APP" /Applications/claudeled.app

    mkdir -p "$PREFIX/bin"
    ln -sf /Applications/claudeled.app/Contents/MacOS/claudeled "$PREFIX/bin/claudeled"

    # zsh reads completions from any directory on fpath; this one is standard.
    COMPDIR="$PREFIX/share/zsh/site-functions"
    mkdir -p "$COMPDIR"
    # Remove first: the destination may be a symlink back to this very file.
    rm -f "$COMPDIR/_claudeled"
    cp completions/_claudeled "$COMPDIR/_claudeled"

    # A rebuild changes the ad-hoc signature, so the old grant no longer applies and
    # macOS will not re-ask on its own. Clearing it makes the prompt appear again.
    tccutil reset ListenEvent com.odiumuniverse.claudeled >/dev/null 2>&1 || true

    open /Applications/claudeled.app
    echo "installed: /Applications/claudeled.app"
    echo "cli:       $PREFIX/bin/claudeled"
    echo "grant Input Monitoring when asked; the app restarts itself once you do"
    ;;
release)
    cp -R completions "build/completions"
    ( cd build && zip -qr "claudeled-$VERSION.zip" claudeled.app completions )
    echo "release: build/claudeled-$VERSION.zip"
    echo "sha256:  $(shasum -a 256 "build/claudeled-$VERSION.zip" | cut -d' ' -f1)"
    ;;
*)
    echo "app:  open $APP"
    echo "cli:  $APP/Contents/MacOS/claudeled --help"
    ;;
esac
