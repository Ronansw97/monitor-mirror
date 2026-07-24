#!/bin/bash
#
# Builds Monitor Mirror.app — a universal (Apple silicon + Intel) release binary wrapped
# in a menu-bar-only bundle, ad-hoc signed so it launches without a developer account.
#
#   ./scripts/build-app.sh            → build/Monitor Mirror.app
#   ./scripts/build-app.sh --install  → also copies it to /Applications
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Monitor Mirror"
EXECUTABLE="MonitorMirror"
BUNDLE_ID="com.monitormirror.MonitorMirror"
VERSION="1.0"
BUILD="1"

BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"

echo "==> Building universal release binary"
swift build -c release --arch arm64 --arch x86_64 --product "${EXECUTABLE}"
BINARY="$(swift build -c release --arch arm64 --arch x86_64 --product "${EXECUTABLE}" --show-bin-path)/${EXECUTABLE}"

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BINARY}" "${APP}/Contents/MacOS/${EXECUTABLE}"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>           <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>            <string>${EXECUTABLE}</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>${VERSION}</string>
    <key>CFBundleVersion</key>               <string>${BUILD}</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>                   <true/>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>NSHumanReadableCopyright</key>      <string>Monitor Mirror</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "${APP}"
codesign --verify --strict "${APP}"

echo "==> Built ${APP}"
lipo -archs "${APP}/Contents/MacOS/${EXECUTABLE}" | sed 's/^/    architectures: /'

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    # Quit any running copy first so the replacement is clean.
    pkill -f "/Applications/${APP_NAME}.app" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP}" "/Applications/"
    open "/Applications/${APP_NAME}.app"
    echo "==> Running. Look for the monitor glyph in the menu bar."
fi
