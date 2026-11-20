#!/bin/bash
# Сборка MacStat.app: один бинарник, без зависимостей.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MacStat.app"
mkdir -p build && rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -Osize -wmo -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -Xlinker -dead_strip \
  Sources/main.swift -o "$APP/Contents/MacOS/MacStat"
strip -x "$APP/Contents/MacOS/MacStat"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MacStat</string>
  <key>CFBundleIdentifier</key><string>dev.macstat.app</string>
  <key>CFBundleExecutable</key><string>MacStat</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built: $APP  ($(du -sk "$APP" | cut -f1) KB)"
