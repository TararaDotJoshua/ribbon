#!/bin/sh
# Builds Ribbon.app (a menu-bar app with no Dock icon) and ad-hoc signs it.
#   ./scripts/bundle.sh            build into build/Ribbon.app
#   ./scripts/bundle.sh --install  also install to ~/Applications and launch it
set -e
cd "$(dirname "$0")/.."
swift build -c release --product Ribbon
APP=build/Ribbon.app
rm -rf "$APP" build/Ribbon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Ribbon "$APP/Contents/MacOS/Ribbon"
swift scripts/make-icon.swift build/Ribbon.iconset
iconutil -c icns build/Ribbon.iconset -o "$APP/Contents/Resources/Ribbon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.ribbon.Ribbon</string>
  <key>CFBundleName</key><string>Ribbon</string>
  <key>CFBundleDisplayName</key><string>Ribbon</string>
  <key>CFBundleExecutable</key><string>Ribbon</string>
  <key>CFBundleIconFile</key><string>Ribbon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "$1" = "--install" ]; then
  DEST="$HOME/Applications/Ribbon.app"
  pkill -x Ribbon 2>/dev/null && sleep 1 || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
