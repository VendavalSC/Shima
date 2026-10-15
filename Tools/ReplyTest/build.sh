#!/bin/zsh
# Builds build/Shima Reply Test.app (see main.swift).
set -e
cd "$(dirname "$0")/../.."
APP="build/Shima Reply Test.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O Tools/ReplyTest/main.swift -o "$APP/Contents/MacOS/ShimaReplyTest"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ShimaReplyTest</string>
    <key>CFBundleIdentifier</key><string>io.github.vendavalsc.shima.replytest</string>
    <key>CFBundleName</key><string>Shima Reply Test</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# Signed like Shima (see ../../build.sh).
WANTED="Shima Development"
[ -f .signing-identity ] && WANTED="$(cat .signing-identity)"
IDENTITY=-
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$WANTED\""; then IDENTITY="$WANTED"; fi
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"
