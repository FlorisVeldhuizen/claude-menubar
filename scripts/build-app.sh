#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Permission Relay"
BUNDLE_ID="dev.local.claude-menubar"
APP="$ROOT/build/$APP_NAME.app"
VERSION="0.1"
# Which build you are running, since the app never updates itself: the commit count reads as a
# version number, the hash says exactly what is in it.
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ClaudeMenuBar"

[ -f "$ROOT/Resources/AppIcon.icns" ] || "$ROOT/scripts/make-icon.sh"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeMenuBar"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>ClaudeMenuBar</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>GitCommit</key><string>$COMMIT</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Permission Relay brings the terminal tab running a Claude Code session to the front.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Floris Veldhuizen · MIT licence</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "Built $APP"
echo "Run it with: open \"$APP\""

if [ "${1:-}" = "--install" ]; then
    DEST="/Applications/$APP_NAME.app"
    # Without this the old copy keeps running and holds the port, so the new one dies on launch.
    pkill -f "$DEST/Contents/MacOS/ClaudeMenuBar" 2>/dev/null && sleep 1 || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "Installed to $DEST and launched"
    echo "Right-click the menu bar icon to enable 'Open at login'"
fi
