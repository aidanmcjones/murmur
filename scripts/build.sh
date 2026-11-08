#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=build/Murmur.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Murmur" "$APP/Contents/MacOS/Murmur"
cp -R "$BIN/Murmur_Murmur.bundle" "$APP/Contents/Resources/"
cp Resources/Murmur.icns "$APP/Contents/Resources/Murmur.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Murmur</string>
  <key>CFBundleIdentifier</key><string>com.aidanjones.murmur</string>
  <key>CFBundleName</key><string>Murmur</string>
  <key>CFBundleDisplayName</key><string>Murmur</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>CFBundleIconFile</key><string>Murmur</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Murmur records your voice while the dictation hotkey is held.</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP"
