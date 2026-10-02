#!/bin/bash
set -euo pipefail
cat staging/native-mac-location-station-2.0.2/part-*.b64 | base64 -D > /tmp/native-mac-source.zip
test "$(shasum -a 256 /tmp/native-mac-source.zip | awk '{print $1}')" = 'e15e9f28d3c454992c217de046a0dbb0621db81c54410b4b25cb2f760c57fcc5'
unzip -t /tmp/native-mac-source.zip
rm -rf /tmp/native-src
mkdir -p /tmp/native-src
ditto -x -k /tmp/native-mac-source.zip /tmp/native-src
python3 - <<'PY'
from pathlib import Path
p=Path('/tmp/native-src/main.m')
s=p.read_text()
s=s.replace('newMessageButton','composeButton')
s=s.replace('ChurchCommunications-Mac-Native/2.0.1','ChurchCommunications-Mac-Native/2.1.1')
old='static NSString * const CCServer = @"https://compassionworship.com/cc/app/location-helper-api.php";'
new='static NSString * const CCServer = @"https://www.compassionworship.com/cc/native-station-api.php";'
if old not in s: raise SystemExit('server constant not found')
s=s.replace(old,new)
s=s.replace('static NSString * const CCAppName = @"Church Communications Location Station";','static NSString * const CCAppName = @"Church Communications Location Station - 2.1.1";')
s=s.replace('self.alertPanel.level=NSStatusWindowLevel+4;','self.alertPanel.level=NSScreenSaverWindowLevel;')
old_launch='    if (self.token.length == 0) {\n        [self.window makeKeyAndOrderFront:nil];\n        [NSApp activateIgnoringOtherApps:YES];\n        [self showPairingDialog];\n    } else {\n        [self startLocationStation];\n    }\n}'
new_launch='    if (self.token.length == 0) {\n        [self.window makeKeyAndOrderFront:nil];\n        [NSApp activateIgnoringOtherApps:YES];\n        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (self.token.length == 0) [self showPairingDialog]; });\n    } else {\n        [self startLocationStation];\n    }\n}'
if old_launch not in s: raise SystemExit('launch block not found')
s=s.replace(old_launch,new_launch)
start=s.index('- (void)showPairingDialog {')
end=s.index('\n- (void)repairClicked:', start)
new_pair=r'''- (void)showPairingDialog {
    if (self.token.length) return;
    NSAlert *a=[[NSAlert alloc]init];
    a.messageText=@"Pair This Mac to a Church Location";
    a.informativeText=@"Enter the normal 8-digit Pair Device code from Admin -> Locations. Each location can have up to 5 paired devices. This Mac gets its own permanent device token, so pairing it does not replace another Mac, iPad, browser station, or future Windows station.\n\nMac app version 2.1.1";
    NSTextField *code=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,300,30)];
    code.placeholderString=@"8-digit Pair Device code";
    code.font=[NSFont monospacedDigitSystemFontOfSize:18 weight:NSFontWeightSemibold];
    a.accessoryView=code;
    [a addButtonWithTitle:@"Pair This Mac"];
    [a addButtonWithTitle:@"Cancel"];
    [NSApp activateIgnoringOtherApps:YES];
    if([a runModal]!=NSAlertFirstButtonReturn)return;
    NSString *c=[[code.stringValue componentsSeparatedByCharactersInSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet] componentsJoinedByString:@""];
    if(c.length!=8){ [self showError:@"The Pair Device code must be exactly 8 digits."]; return; }
    NSString *deviceName=[[NSHost currentHost] localizedName];
    if(!deviceName.length) deviceName=[[NSProcessInfo processInfo] hostName];
    if(!deviceName.length) deviceName=@"Mac Location Station";
    [self postJSONAction:@"pair_device" params:@{@"code":c,@"device_name":deviceName,@"device_type":@"mac",@"app_version":@"2.1.1"} completion:^(NSDictionary *json,NSError *error){
        if(error){ [self showError:error.localizedDescription ?: @"Pairing failed"]; return; }
        if(![json[@"ok"] boolValue]){ [self showError:[json[@"error"] description] ?: @"Pairing failed"]; return; }
        NSString *tok=[json[@"token"] description];
        NSString *name=[json[@"location_name"] description];
        NSInteger lid=[json[@"location_id"] integerValue];
        if(tok.length<32 || lid<=0){ [self showError:@"The server did not return a valid device token."]; return; }
        self.token=tok; self.locationName=name.length?name:@"Location Station"; self.locationID=lid; self.cursor=0;
        NSUserDefaults *d=[NSUserDefaults standardUserDefaults];
        [d setObject:tok forKey:CCTokenKey]; [d setObject:self.locationName forKey:CCLocationNameKey]; [d setInteger:lid forKey:CCLocationIDKey]; [d removeObjectForKey:CCCursorKey]; [d synchronize];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.locationLabel.stringValue=self.locationName;
            NSInteger used=[json[@"slots_used"] integerValue]; NSInteger max=[json[@"max_devices"] integerValue];
            self.statusLabel.stringValue=(used>0&&max>0)?[NSString stringWithFormat:@"Paired - Device %ld of %ld",(long)used,(long)max]:@"Paired successfully - connecting...";
            [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
        });
        [self startLocationStation];
    }];
}
'''
s=s[:start]+new_pair+s[end:]
s=s.replace('This will disconnect the current location from this Mac and ask for a new setup code.','This will disconnect only this Mac from the current location and ask for a new Pair Device code. Other paired devices stay connected.')
if 'postJSONAction:@"pair_device"' not in s: raise SystemExit('pair_device call missing')
if 'postJSONAction:@"pair_json"' in s: raise SystemExit('old pair_json call still present')
p.write_text(s)
p=Path('/tmp/native-src/Info.plist')
info=p.read_text().replace('<string>2.0.1</string>','<string>2.1.1</string>').replace('<string>200</string>','<string>211</string>')
p.write_text(info)
PY
plutil -lint /tmp/native-src/Info.plist
grep -q 'ChurchCommunications-Mac-Native/2.1.1' /tmp/native-src/main.m
grep -q 'https://www.compassionworship.com/cc/native-station-api.php' /tmp/native-src/main.m
grep -q 'postJSONAction:@"pair_device"' /tmp/native-src/main.m
grep -q 'up to 5 paired devices' /tmp/native-src/main.m
grep -q 'NSScreenSaverWindowLevel' /tmp/native-src/main.m
if grep -q 'postJSONAction:@"pair_json"' /tmp/native-src/main.m; then echo 'old pair_json still present'; exit 1; fi
APP='/tmp/Church Communications Location Station 2.1.1.app'
EXE="$APP/Contents/MacOS/Church Communications Location Station"
RES="$APP/Contents/Resources"
rm -rf "$APP" /tmp/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$RES" /tmp/AppIcon.iconset
cp /tmp/native-src/Info.plist "$APP/Contents/Info.plist"
for spec in '16 icon_16x16.png' '32 icon_16x16@2x.png' '32 icon_32x32.png' '64 icon_32x32@2x.png' '128 icon_128x128.png' '256 icon_128x128@2x.png' '256 icon_256x256.png' '512 icon_256x256@2x.png' '512 icon_512x512.png' '1024 icon_512x512@2x.png'; do
  set -- $spec
  sips -z "$1" "$1" /tmp/native-src/AppIcon-1024.png --out "/tmp/AppIcon.iconset/$2" >/dev/null
done
iconutil -c icns /tmp/AppIcon.iconset -o "$RES/AppIcon.icns"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -fobjc-arc -fblocks -arch x86_64 -mmacosx-version-min=10.15 -isysroot "$SDK" -framework Cocoa -framework IOKit /tmp/native-src/main.m -o "$EXE"
chmod +x "$EXE"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
lipo -info "$EXE" | grep -q 'x86_64'
test "$(defaults read "$APP/Contents/Info" LSMinimumSystemVersion)" = '10.15.0'
test "$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)" = '2.1.1'
strings "$EXE" > /tmp/location-station-strings.txt
grep -q 'native-station-api.php' /tmp/location-station-strings.txt
grep -q 'pair_device' /tmp/location-station-strings.txt
grep -q '2.1.1' /tmp/location-station-strings.txt
ROOT=/tmp/location-station-dmg
OUT='releases/Church-Communications-Mac-Location-Station-2.1.1.dmg'
rm -rf "$ROOT" "$OUT"
mkdir -p "$ROOT" releases
ditto "$APP" "$ROOT/Church Communications Location Station 2.1.1.app"
ln -s /Applications "$ROOT/Applications"
hdiutil create -volname 'Church Communications Location Station 2.1.1' -srcfolder "$ROOT" -ov -format UDZO "$OUT"
hdiutil verify "$OUT"
test -s "$OUT"
shasum -a 256 "$OUT" | tee releases/Church-Communications-Mac-Location-Station-2.1.1.dmg.sha256.txt
