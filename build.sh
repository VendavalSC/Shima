#!/bin/bash
# Builds build/Shima.app (release). Needs only the Command Line Tools, not Xcode.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Shima.app
swift build -c release --product Shima
BIN="$(swift build -c release --show-bin-path)/Shima"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Shima"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
clang -dynamiclib -fobjc-arc -O2 -framework Foundation \
    Helper/ShimaMedia.m -o "$APP/Contents/Resources/libshimamedia.dylib"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.vendavalsc.shima</string>
    <key>CFBundleName</key><string>Shima</string>
    <key>CFBundleDisplayName</key><string>Shima</string>
    <key>CFBundleExecutable</key><string>Shima</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Shima shows your next event in the notch a few minutes before it starts.</string>
    <key>NSCalendarsUsageDescription</key><string>Shima shows your next event in the notch a few minutes before it starts.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocationUsageDescription</key><string>Shima shows the weather where you are on the Weather page.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>Shima shows the weather where you are on the Weather page.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>Shima shows today's reminders on the Reminders page, and lets you tick them off and add new ones.</string>
    <key>NSRemindersUsageDescription</key><string>Shima shows today's reminders on the Reminders page, and lets you tick them off and add new ones.</string>
</dict>
</plist>
PLIST
# The version lives in VERSION; releases are tagged v<VERSION> on GitHub, which the updater reads.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(cat VERSION)" "$APP/Contents/Info.plist"

# Sign with a local code-signing certificate when there is one: macOS then keeps Shima's
# permissions (Accessibility, Calendars, Full Disk Access) across rebuilds. It's the one named
# "Shima Development" (Keychain Access → Certificate Assistant → Create a Certificate, type Code
# Signing), or the name in .signing-identity, which isn't checked in. Without one, sign ad hoc, and
# macOS treats every build as a new app.
WANTED="Shima Development"
[ -f .signing-identity ] && WANTED="$(cat .signing-identity)"
IDENTITY=-
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$WANTED\""; then
    IDENTITY="$WANTED"
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/libshimamedia.dylib"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP (signed: $IDENTITY)"
