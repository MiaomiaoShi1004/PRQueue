#!/bin/bash
set -e
cd "$(dirname "$0")"
APP="PRQueue.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>PRQueue</string>
  <key>CFBundleIdentifier</key><string>local.prqueue</string>
  <key>CFBundleExecutable</key><string>PRQueue</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
swiftc -O -target arm64-apple-macos14 -parse-as-library main.swift -o "$APP/Contents/MacOS/PRQueue"
codesign --force --sign - "$APP"
echo "built $APP"
