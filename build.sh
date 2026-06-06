#!/usr/bin/env bash
set -euo pipefail

# Builds the ClaudeUsageBar menu bar app into build/ClaudeUsageBar.app.
# Idempotent: the build directory is recreated from scratch every run.

cd "$(dirname "$0")"

APP="build/ClaudeUsageBar.app"
MACOS_DIR="$APP/Contents/MacOS"

rm -rf build
mkdir -p "$MACOS_DIR"

swiftc -O MenuBarApp/main.swift -o "$MACOS_DIR/ClaudeUsageBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ClaudeUsageBar</string>
    <key>CFBundleDisplayName</key>
    <string>ClaudeUsageBar</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeUsageBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.claudeusagebar.app</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "Built $APP"
