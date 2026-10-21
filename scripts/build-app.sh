#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
bin=$(swift build -c release --show-bin-path)
app=build/HomeAwake.app

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/HomeAwake" "$bin/homeawake-agent" "$app/Contents/MacOS/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>dev.homeawake.HomeAwake</string>
	<key>CFBundleExecutable</key>
	<string>HomeAwake</string>
	<key>CFBundleName</key>
	<string>HomeAwake</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
</dict>
</plist>
PLIST

codesign --force -s - "$app/Contents/MacOS/homeawake-agent"
codesign --force -s - "$app"
codesign --verify --strict "$app"
echo "$app"
