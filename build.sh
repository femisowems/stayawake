#!/bin/sh
# Build StayAwake.app (native Mac version) on macOS.
# Needs Xcode Command Line Tools (swiftc). If missing: xcode-select --install
set -e
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Command Line Tools first, then re-run:"
  echo "  xcode-select --install"
  exit 1
fi

APP="StayAwake.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -framework Cocoa -framework IOKit \
  -o "$APP/Contents/MacOS/StayAwake" main.swift

# App icon (coffee cup / moon / star on teal) — built from AppIcon-1024.png.
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>StayAwake</string>
  <key>CFBundleDisplayName</key><string>StayAwake</string>
  <key>CFBundleIdentifier</key><string>io.starterdev.stayawake</string>
  <key>CFBundleVersion</key><string>2.1.0</string>
  <key>CFBundleShortVersionString</key><string>2.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>StayAwake</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>io.starterdev.stayawake</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key>
      <array><string>stayawake</string></array>
    </dict>
  </array>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHumanReadableCopyright</key><string>Made for Femi Sowemimo by Edison. No data collected.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper treats it as a local build, not a download.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo ""
echo "Built $APP"
echo "Install:  drag StayAwake.app into /Applications, then double-click it."
echo "It lives in the menu bar (coffee cup). Starting a session pops the"
echo "floating mini timer to the top-right of your screen."
