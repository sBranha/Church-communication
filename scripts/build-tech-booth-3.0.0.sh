#!/bin/bash
set -euo pipefail

SRC='native-mac-tech-booth-3.0.0'
VER='2.5.22'
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
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 20522" "$APP/Contents/Info.plist"
sed 's/3\.0\.0/2.5.22/g' "$SRC/main.m" > "$MAINTMP"

# Replace the old small utility popup with a huge, full-screen-priority alert.
python3 - "$MAINTMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
start=s.index('- (void)showNativeAlertFrom:')
end=s.index('- (void)dismissAlert:', start)
new=r'''- (void)showNativeAlertFrom:(NSString *)sender title:(NSString *)title body:(NSString *)body threadID:(NSInteger)threadID messageID:(NSInteger)messageID {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSScreen *screen=[NSScreen mainScreen];
        if(!screen)screen=[[NSScreen screens] firstObject];
        NSRect sf=screen?screen.frame:NSMakeRect(0,0,1440,900);
        NSRect pf=NSInsetRect(sf,24,24);

        if(!self.alertPanel){
            self.alertPanel=[[NSPanel alloc] initWithContentRect:pf
                                                     styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskFullSizeContentView)
                                                       backing:NSBackingStoreBuffered defer:NO];
            self.alertPanel.title=@"TECHBOOTH MESSAGE";
            self.alertPanel.hidesOnDeactivate=NO;
            self.alertPanel.releasedWhenClosed=NO;
            self.alertPanel.floatingPanel=YES;
            self.alertPanel.becomesKeyOnlyIfNeeded=NO;
            self.alertPanel.movableByWindowBackground=NO;
            self.alertPanel.level=CGWindowLevelForKey(kCGMaximumWindowLevelKey)-1;
            self.alertPanel.collectionBehavior=(NSWindowCollectionBehaviorCanJoinAllSpaces|
                                                NSWindowCollectionBehaviorFullScreenAuxiliary|
                                                NSWindowCollectionBehaviorStationary|
                                                NSWindowCollectionBehaviorIgnoresCycle);
            self.alertPanel.backgroundColor=[NSColor blackColor];
            self.alertPanel.opaque=YES;

            NSView *v=self.alertPanel.contentView;
            v.wantsLayer=YES;
            v.layer.backgroundColor=[NSColor blackColor].CGColor;
            CGFloat w=v.bounds.size.width, h=v.bounds.size.height;

            self.alertTitle=[self label:@"MESSAGE FOR TECH BOOTH" frame:NSMakeRect(48,h-118,w-96,70) size:50 bold:YES];
            self.alertTitle.textColor=[NSColor whiteColor];
            self.alertTitle.alignment=NSTextAlignmentCenter;
            [v addSubview:self.alertTitle];

            self.alertSender=[self label:@"" frame:NSMakeRect(60,h-185,w-120,52) size:34 bold:YES];
            self.alertSender.textColor=[NSColor colorWithCalibratedRed:0.35 green:0.78 blue:1.0 alpha:1.0];
            self.alertSender.alignment=NSTextAlignmentCenter;
            [v addSubview:self.alertSender];

            self.alertBody=[self label:@"" frame:NSMakeRect(70,145,w-140,h-355) size:58 bold:YES];
            self.alertBody.textColor=[NSColor whiteColor];
            self.alertBody.alignment=NSTextAlignmentCenter;
            self.alertBody.maximumNumberOfLines=8;
            self.alertBody.lineBreakMode=NSLineBreakByWordWrapping;
            [v addSubview:self.alertBody];

            NSButton *open=[[NSButton alloc] initWithFrame:NSMakeRect(w-420,42,175,66)];
            open.title=@"OPEN APP";
            open.font=[NSFont boldSystemFontOfSize:22];
            open.bezelStyle=NSBezelStyleRounded;
            open.target=self;
            open.action=@selector(openFromAlert:);
            [v addSubview:open];

            NSButton *dismiss=[[NSButton alloc] initWithFrame:NSMakeRect(w-225,42,175,66)];
            dismiss.title=@"DISMISS";
            dismiss.font=[NSFont boldSystemFontOfSize:22];
            dismiss.bezelStyle=NSBezelStyleRounded;
            dismiss.target=self;
            dismiss.action=@selector(dismissAlert:);
            [v addSubview:dismiss];
        }

        [self.alertPanel setFrame:pf display:YES];
        NSView *v=self.alertPanel.contentView;
        CGFloat w=v.bounds.size.width, h=v.bounds.size.height;
        self.alertTitle.frame=NSMakeRect(48,h-118,w-96,70);
        self.alertSender.frame=NSMakeRect(60,h-185,w-120,52);
        self.alertBody.frame=NSMakeRect(70,145,w-140,h-355);

        NSString *safeBody=body.length?body:@"New message";
        CGFloat bodySize=58.0;
        if(safeBody.length>260)bodySize=38.0;
        else if(safeBody.length>150)bodySize=44.0;
        else if(safeBody.length>80)bodySize=50.0;
        self.alertBody.font=[NSFont boldSystemFontOfSize:bodySize];
        self.alertSender.stringValue=[NSString stringWithFormat:@"%@  •  %@",sender ?: @"Church Communications",title ?: @"Conversation"];
        self.alertBody.stringValue=safeBody;
        self.currentThreadID=threadID;
        self.sendButton.enabled=(threadID>0);

        [NSApp activateIgnoringOtherApps:YES];
        [self.alertPanel makeKeyAndOrderFront:nil];
        [self.alertPanel orderFrontRegardless];
        NSBeep();
    });
}

'''
s=s[:start]+new+s[end:]
p.write_text(s)
PY

# Reuse only the existing Church Communications artwork.
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
strings "$EXE" | grep -q 'MESSAGE FOR TECH BOOTH'
strings "$EXE" | grep -q '2.5.22'

# Finished-product Mac DMG: open it and drag the app directly to Applications.
cp -R "$APP" "$DMGROOT/Church Communications Tech Booth.app"
ln -s /Applications "$DMGROOT/Applications"
cat > "$DMGROOT/READ ME.txt" <<'TXT'
CHURCH COMMUNICATIONS TECH BOOTH 2.5.22

INSTALL
1. Drag “Church Communications Tech Booth” onto the Applications folder in this window.
2. Open Applications > Church Communications Tech Booth.
3. If macOS blocks the first launch, Control-click the app, choose Open, then Open again.
4. In Church Communications Admin, open Station Setup, choose TECHBOOTH, and generate a 6-digit setup code.
5. Enter that code in the Mac app once. The Mac keeps its permanent station connection afterward.

ALERT BEHAVIOR
Incoming TECHBOOTH messages display as a huge, high-priority overlay across Spaces and over normal full-screen apps. The alert remains visible until OPEN APP or DISMISS is pressed.

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
strings "$MOUNT/Church Communications Tech Booth.app/Contents/MacOS/Church Communications Tech Booth" | grep -q 'MESSAGE FOR TECH BOOTH'
hdiutil detach "$MOUNT" >/dev/null

shasum -a 256 "$DMG" | tee "releases/Church-Communications-Tech-Booth-${VER}.dmg.sha256.txt"
