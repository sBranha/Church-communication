#!/bin/bash
set -euo pipefail

SRC='native-mac-tech-booth-3.0.0'
VER='3.0.1'
APP='/tmp/Church Communications Tech Booth.app'
EXE="$APP/Contents/MacOS/Church Communications Tech Booth"
RES="$APP/Contents/Resources"
DMGROOT='/tmp/cc-techbooth-dmg'
DMG="releases/Church-Communications-Tech-Booth-${VER}.dmg"
ICONSET='/tmp/cc-techbooth.iconset'
MAINTMP='/tmp/cc-techbooth-main.m'
MOUNT='/tmp/cc-techbooth-mount'

rm -rf "$APP" "$ICONSET" "$DMGROOT" "$MOUNT" /tmp/cc-techbooth-old.zip /tmp/AppIcon-1024.png "$MAINTMP"
mkdir -p "$APP/Contents/MacOS" "$RES" "$ICONSET" "$DMGROOT" releases
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 301" "$APP/Contents/Info.plist"
sed 's/3\.0\.0/3.0.1/g' "$SRC/main.m" > "$MAINTMP"

# Reuse only the existing Church Communications artwork. No previous Mac application code is reused.
cat staging/native-mac-location-station-2.0.2/part-*.b64 | base64 -D > /tmp/cc-techbooth-old.zip
unzip -p /tmp/cc-techbooth-old.zip AppIcon-1024.png > /tmp/AppIcon-1024.png
test -s /tmp/AppIcon-1024.png
for spec in '16 icon_16x16.png' '32 icon_16x16@2x.png' '32 icon_32x32.png' '64 icon_32x32@2x.png' '128 icon_128x128.png' '256 icon_128x128@2x.png' '256 icon_256x256.png' '512 icon_256x256@2x.png' '512 icon_512x512.png' '1024 icon_512x512@2x.png'; do
  set -- $spec
  sips -z "$1" "$1" /tmp/AppIcon-1024.png --out "$ICONSET/$2" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

plutil -lint "$APP/Contents/Info.plist"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -fobjc-arc -fblocks -arch x86_64 -mmacosx-version-min=10.15 -isysroot "$SDK" -framework Cocoa -framework CoreGraphics "$MAINTMP" -o "$EXE"
chmod +x "$EXE"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
lipo -info "$EXE" | grep -q 'x86_64'
test "$(defaults read "$APP/Contents/Info" LSMinimumSystemVersion)" = '10.15.0'
test "$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)" = "$VER"
strings "$EXE" | grep -q 'station-v3-api.php'
strings "$EXE" | grep -q '6-digit setup code'
strings "$EXE" | grep -q 'TECHBOOTH MESSAGE'
strings "$EXE" | grep -q '3.0.1'

# Finished-product Mac DMG: open it and drag the app directly to Applications.
cp -R "$APP" "$DMGROOT/Church Communications Tech Booth.app"
ln -s /Applications "$DMGROOT/Applications"
cat > "$DMGROOT/READ ME.txt" <<'TXT'
CHURCH COMMUNICATIONS TECH BOOTH 3.0.1

INSTALL
1. Drag “Church Communications Tech Booth” onto the Applications folder in this window.
2. Open Applications > Church Communications Tech Booth.
3. If macOS blocks the first launch, Control-click the app, choose Open, then Open again.
4. In Church Communications Admin, open Station Setup, choose TECHBOOTH, and generate a 6-digit setup code.
5. Enter that code in the Mac app once. The Mac keeps its permanent station connection afterward.

This DMG contains the finished Mac application. No PKG installer is required.
TXT

rm -f "$DMG"
hdiutil create -volname "Church Communications Tech Booth ${VER}" -srcfolder "$DMGROOT" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"
test -s "$DMG"

# Verify the actual mounted DMG contains the app and Applications drag target.
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
test -d "$MOUNT/Church Communications Tech Booth.app"
test -L "$MOUNT/Applications"
codesign --verify --deep --strict "$MOUNT/Church Communications Tech Booth.app"
lipo -info "$MOUNT/Church Communications Tech Booth.app/Contents/MacOS/Church Communications Tech Booth" | grep -q 'x86_64'
test "$(defaults read "$MOUNT/Church Communications Tech Booth.app/Contents/Info" CFBundleShortVersionString)" = "$VER"
hdiutil detach "$MOUNT" >/dev/null

shasum -a 256 "$DMG" | tee "releases/Church-Communications-Tech-Booth-${VER}.dmg.sha256.txt"
