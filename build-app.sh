#!/bin/zsh
# Builds HatorRGB.app (menu bar app). Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail
cd "${0:A:h}"

swift build -c release --product HatorRGB
swift build -c release --product hator

APP=HatorRGB.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/HatorRGB "$APP/Contents/MacOS/HatorRGB"
cp .build/release/hator "$APP/Contents/Resources/hator"
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
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    pkill -x HatorRGB 2>/dev/null || true
    rm -rf ~/Applications/$APP
    cp -R "$APP" ~/Applications/
    open ~/Applications/$APP
    echo "Installed to ~/Applications/$APP"
fi
