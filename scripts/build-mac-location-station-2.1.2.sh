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
s=s.replace('ChurchCommunications-Mac-Native/2.0.1','ChurchCommunications-Mac-Native/2.1.2')
s=s.replace('ChurchCommunications-Mac-Native/2.0.2','ChurchCommunications-Mac-Native/2.1.2')
old='static NSString * const CCServer = @"https://compassionworship.com/cc/app/location-helper-api.php";'
new='static NSString * const CCServer = @"https://www.compassionworship.com/cc/native-station-api.php";'
if old not in s: raise SystemExit('server constant not found')
s=s.replace(old,new)
s=s.replace('static NSString * const CCAppName = @"Church Communications Location Station";','static NSString * const CCAppName = @"Church Communications Location Station - 2.1.2";')
# Force one clean Station-Key setup when upgrading from any of the failed pairing builds.
marker='    self.locationID = [d integerForKey:CCLocationIDKey];\n'
insert='''    self.locationID = [d integerForKey:CCLocationIDKey];\n    if (![d boolForKey:@"CCPermanentStationKeyMode"]) {\n        self.token = nil; self.locationName = @"Location"; self.locationID = 0;\n        [d removeObjectForKey:CCTokenKey]; [d removeObjectForKey:CCLocationNameKey]; [d removeObjectForKey:CCLocationIDKey]; [d removeObjectForKey:CCCursorKey]; [d synchronize];\n    }\n'''
if marker not in s: raise SystemExit('defaults marker not found')
s=s.replace(marker,insert,1)
# Replace the entire old pair-code dialog with a permanent Station Key validator.
start=s.index('- (void)showPairingDialog {')
end=s.index('\n- (void)repairClicked:', start)
new_pair=r'''- (void)showPairingDialog {
    if (self.token.length) return;
    NSAlert *a=[[NSAlert alloc]init];
    a.messageText=@"Connect This Mac to TECHBOOTH";
    a.informativeText=@"This version does not use pairing codes.\n\n1. In Church Communications, open /cc/station-key.php while signed in as an Administrator.\n2. Generate the permanent Station Key for TECHBOOTH.\n3. Paste that Station Key below.\n\nThe key does not expire. This Mac will stay assigned to TECHBOOTH until you change or revoke the key.\n\nMac app version 2.1.2";
    NSTextField *field=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,430,30)];
    field.placeholderString=@"Permanent Station Key";
    field.font=[NSFont monospacedSystemFontOfSize:15 weight:NSFontWeightSemibold];
    a.accessoryView=field;
    [a addButtonWithTitle:@"Connect"];
    [a addButtonWithTitle:@"Cancel"];
    [NSApp activateIgnoringOtherApps:YES];
    if([a runModal]!=NSAlertFirstButtonReturn)return;
    NSString *raw=[field.stringValue uppercaseString];
    NSCharacterSet *hex=[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"];
    NSMutableString *key=[NSMutableString string];
    for(NSUInteger i=0;i<raw.length;i++){ unichar c=[raw characterAtIndex:i]; if([hex characterIsMember:c]) [key appendFormat:@"%C",c]; }
    if(key.length!=32){ [self showError:@"The Station Key should contain 32 letters/numbers. Copy the full key from the Church Communications Station Key page."]; [self showPairingDialog]; return; }
    self.token=key;
    [self getJSONAction:@"device_status" params:@{} completion:^(NSDictionary *json,NSError *error){
        dispatch_async(dispatch_get_main_queue(), ^{
            if(error || ![json[@"ok"] boolValue]){
                self.token=nil;
                NSString *m=error.localizedDescription ?: [json[@"error"] description] ?: @"The Station Key was not accepted.";
                [self showError:m]; [self showPairingDialog]; return;
            }
            NSString *mode=[json[@"auth_mode"] description];
            if(mode.length && ![mode isEqualToString:@"station_key"]){ self.token=nil; [self showError:@"That credential is not a permanent Station Key. Generate a new Station Key from the website and try again."]; [self showPairingDialog]; return; }
            NSString *name=[json[@"location_name"] description]; NSInteger lid=[json[@"location_id"] integerValue];
            if(!name.length || lid<=0){ self.token=nil; [self showError:@"The website accepted the key but did not identify a location."]; [self showPairingDialog]; return; }
            self.locationName=name; self.locationID=lid;
            NSUserDefaults *d=[NSUserDefaults standardUserDefaults];
            [d setObject:self.token forKey:CCTokenKey]; [d setObject:self.locationName forKey:CCLocationNameKey]; [d setInteger:lid forKey:CCLocationIDKey]; [d setBool:YES forKey:@"CCPermanentStationKeyMode"]; [d removeObjectForKey:CCCursorKey]; [d synchronize];
            self.locationLabel.stringValue=[NSString stringWithFormat:@"CHURCH COMMUNICATIONS - %@",[self.locationName uppercaseString]];
            self.statusLabel.stringValue=@"Connected with permanent Station Key";
            [self startLocationStation];
        });
    }];
}
'''
s=s[:start]+new_pair+s[end:]
rstart=s.index('- (void)repairClicked:')
rend=s.index('\n- (void)installLoginAgentIfPossible', rstart)
new_repair=r'''- (void)repairClicked:(id)sender {
    NSAlert *a=[[NSAlert alloc]init];
    a.messageText=@"Change this Mac's Station Key?";
    a.informativeText=@"This only clears the Station Key saved on this Mac. It does not change the website. Generate/replace/revoke Station Keys from the Church Communications Station Key page.";
    [a addButtonWithTitle:@"Change Key"];
    [a addButtonWithTitle:@"Cancel"];
    if([a runModal]!=NSAlertFirstButtonReturn)return;
    [self stopTimers];
    self.token=nil; self.locationName=@"Location"; self.locationID=0;
    NSUserDefaults *d=[NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:CCTokenKey]; [d removeObjectForKey:CCLocationNameKey]; [d removeObjectForKey:CCLocationIDKey]; [d removeObjectForKey:CCCursorKey]; [d setBool:NO forKey:@"CCPermanentStationKeyMode"]; [d synchronize];
    [self.threads removeAllObjects]; [self.messages removeAllObjects]; [self.threadsTable reloadData]; [self.messagesTable reloadData];
    [self showPairingDialog];
}
'''
s=s[:rstart]+new_repair+s[rend:]
s=s.replace('title:@"Pair Another Location"','title:@"Change Station Key"')
if 'pair_device' in s or 'pair_json' in s or 'claim_setup' in s: raise SystemExit('old pairing action still present')
if 'CCPermanentStationKeyMode' not in s: raise SystemExit('station key marker missing')
if 'device_status' not in s: raise SystemExit('station key validation missing')
if 'CGWindowLevelForKey(kCGMaximumWindowLevelKey) - 1' not in s: raise SystemExit('maximum always-on-top alert level missing')
p.write_text(s)
p=Path('/tmp/native-src/Info.plist')
info=p.read_text().replace('<string>2.0.1</string>','<string>2.1.2</string>').replace('<string>2.0.2</string>','<string>2.1.2</string>').replace('<string>200</string>','<string>212</string>').replace('<string>202</string>','<string>212</string>')
p.write_text(info)
PY
plutil -lint /tmp/native-src/Info.plist
APP='/tmp/Church Communications Location Station 2.1.2.app'
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
test "$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)" = '2.1.2'
strings "$EXE" > /tmp/location-station-strings.txt
grep -q 'native-station-api.php' /tmp/location-station-strings.txt
grep -q 'Permanent Station Key' /tmp/location-station-strings.txt
grep -q '2.1.2' /tmp/location-station-strings.txt
ROOT=/tmp/location-station-dmg
OUT='releases/Church-Communications-Mac-Location-Station-2.1.2.dmg'
rm -rf "$ROOT" "$OUT"
mkdir -p "$ROOT" releases
ditto "$APP" "$ROOT/Church Communications Location Station 2.1.2.app"
ln -s /Applications "$ROOT/Applications"
hdiutil create -volname 'Church Communications Location Station 2.1.2' -srcfolder "$ROOT" -ov -format UDZO "$OUT"
hdiutil verify "$OUT"
test -s "$OUT"
shasum -a 256 "$OUT" | tee releases/Church-Communications-Mac-Location-Station-2.1.2.dmg.sha256.txt
