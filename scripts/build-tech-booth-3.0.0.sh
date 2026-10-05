#!/bin/bash
set -euo pipefail

SRC='native-mac-tech-booth-3.0.0'
APP='/tmp/Church Communications Tech Booth.app'
EXE="$APP/Contents/MacOS/Church Communications Tech Booth"
RES="$APP/Contents/Resources"
PKG='/tmp/Church-Communications-Tech-Booth-3.0.0.pkg'
DMG='releases/Church-Communications-Tech-Booth-3.0.0-Installer.dmg'
ICONSET='/tmp/cc-techbooth.iconset'

rm -rf "$APP" "$ICONSET" /tmp/cc-techbooth-dmg /tmp/cc-techbooth-old.zip /tmp/AppIcon-1024.png "$PKG"
mkdir -p "$APP/Contents/MacOS" "$RES" "$ICONSET" releases
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"

# Reuse only the existing Church Communications artwork. No previous Mac code is reused.
cat staging/native-mac-location-station-2.0.2/part-*.b64 | base64 -D > /tmp/cc-techbooth-old.zip
unzip -p /tmp/cc-techbooth-old.zip AppIcon-1024.png > /tmp/AppIcon-1024.png
test -s /tmp/AppIcon-1024.png
for spec in '16 icon_16x16.png' '32 icon_16x16@2x.png' '32 icon_32x32.png' '64 icon_32x32@2x.png' '128 icon_128x128.png' '256 icon_128x128@2x.png' '256 icon_256x256.png' '512 icon_256x256@2x.png' '512 icon_512x512.png' '1024 icon_512x512@2x.png'; do
  set -- $spec
  sips -z "$1" "$1" /tmp/AppIcon-1024.png --out "$ICONSET/$2" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

plutil -lint "$SRC/Info.plist"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -fobjc-arc -fblocks -arch x86_64 -mmacosx-version-min=10.15 -isysroot "$SDK" -framework Cocoa -framework CoreGraphics "$SRC/main.m" -o "$EXE"
chmod +x "$EXE"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
lipo -info "$EXE" | grep -q 'x86_64'
test "$(defaults read "$APP/Contents/Info" LSMinimumSystemVersion)" = '10.15.0'
test "$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)" = '3.0.0'
strings "$EXE" | grep -q 'station-v3-api.php'
strings "$EXE" | grep -q '6-digit setup code'
strings "$EXE" | grep -q 'TECHBOOTH MESSAGE'

pkgbuild --component "$APP" --install-location /Applications --identifier com.churchcommunications.techbooth.pkg --version 3.0.0 "$PKG"
pkgutil --check-signature "$PKG" || true
pkgutil --payload-files "$PKG" | grep -q 'Church Communications Tech Booth.app'

mkdir -p /tmp/cc-techbooth-dmg
cp "$PKG" /tmp/cc-techbooth-dmg/'Install Church Communications Tech Booth 3.0.0.pkg'
cat > /tmp/cc-techbooth-dmg/'READ ME.txt' <<'TXT'
CHURCH COMMUNICATIONS TECH BOOTH 3.0.0

1. Double-click “Install Church Communications Tech Booth 3.0.0.pkg”.
2. Finish the installer.
3. Open Applications > Church Communications Tech Booth.
4. On the Church Communications website, open /cc/station-pair.php as Administrator.
5. Generate a 6-digit code for TECHBOOTH and enter it in the Mac app.

This is a completely new Mac app with a new bundle ID and a new pairing backend.
TXT
rm -f "$DMG"
hdiutil create -volname 'Church Communications Tech Booth 3.0.0' -srcfolder /tmp/cc-techbooth-dmg -ov -format UDZO "$DMG"
hdiutil verify "$DMG"
test -s "$DMG"
shasum -a 256 "$DMG" | tee releases/Church-Communications-Tech-Booth-3.0.0-Installer.dmg.sha256.txt
cp "$PKG" releases/Church-Communications-Tech-Booth-3.0.0.pkg
shasum -a 256 releases/Church-Communications-Tech-Booth-3.0.0.pkg | tee releases/Church-Communications-Tech-Booth-3.0.0.pkg.sha256.txt
