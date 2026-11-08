#!/bin/zsh
# Builds HatorRGB.app (universal: Apple Silicon + Intel).
#   --install   copy it to ~/Applications and launch it
#   --zip       also produce HatorRGB-<version>.zip for a GitHub release
set -euo pipefail
cd "${0:A:h}"

VERSION=1.0.0
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" --product HatorRGB
swift build -c release "${ARCHS[@]}" --product hator
BIN=.build/apple/Products/Release

APP=HatorRGB.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HatorRGB" "$APP/Contents/MacOS/HatorRGB"
cp "$BIN/hator" "$APP/Contents/Resources/hator"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>HatorRGB</string>
    <key>CFBundleDisplayName</key><string>HATOR RGB</string>
    <key>CFBundleIdentifier</key><string>local.hatorrgb</string>
    <key>CFBundleExecutable</key><string>HatorRGB</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>VERSION_PLACEHOLDER</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

sed -i '' "s/VERSION_PLACEHOLDER/$VERSION/" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "Built $PWD/$APP"

if [[ " $* " == *" --zip "* ]]; then
    ditto -c -k --keepParent "$APP" "HatorRGB-$VERSION.zip"
    echo "Packed $PWD/HatorRGB-$VERSION.zip"
fi

if [[ " $* " == *" --install "* ]]; then
    mkdir -p ~/Applications
    pkill -x HatorRGB 2>/dev/null || true
    rm -rf ~/Applications/$APP
    cp -R "$APP" ~/Applications/
    open ~/Applications/$APP
    echo "Installed to ~/Applications/$APP"
fi
