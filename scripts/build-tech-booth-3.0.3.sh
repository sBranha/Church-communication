#!/bin/bash
set -euo pipefail

# Mac Tech Booth baseline: 3.0.2. This builds 3.0.3.
# Website 2.5.23 is the source of truth for active location buttons and sends.
TMP_SCRIPT="$(mktemp /tmp/cc-techbooth-3.0.3.XXXXXX.sh)"
trap 'rm -f "$TMP_SCRIPT"' EXIT
cp scripts/build-tech-booth-3.0.0.sh "$TMP_SCRIPT"

python3 - "$TMP_SCRIPT" <<'PYWRAP'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
s=s.replace("VER='2.5.22'", "VER='3.0.3'")
s=s.replace('Set :CFBundleVersion 20522', 'Set :CFBundleVersion 303')
s=s.replace('2.5.22', '3.0.3')
marker='# Reuse only the existing Church Communications artwork.\n'
if marker not in s:
    raise SystemExit('Could not find Mac build insertion point')
patch=r"""# Add website-driven active-location buttons and direct location sending.
python3 - "$MAINTMP" <<'PYLOC'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()

prop='''@property NSTextField *alertBody;\n@end'''
prop_new='''@property NSTextField *alertBody;\n@property NSScrollView *locationBarScroll;\n@property NSView *locationBarView;\n@property NSTimer *locationRefreshTimer;\n@property NSArray *activeLocations;\n@end'''
if prop not in s: raise SystemExit('property insertion point missing')
s=s.replace(prop,prop_new,1)

status='''    self.statusLabel=[self label:@"Waiting for setup" frame:NSMakeRect(24,452,600,22) size:13 bold:NO]; [v addSubview:self.statusLabel];\n'''
status_new=status+'''\n    NSTextField *locationBarTitle=[self label:@"SEND TO ACTIVE LOCATION" frame:NSMakeRect(24,421,260,18) size:11 bold:YES]; [v addSubview:locationBarTitle];\n    self.locationBarScroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(24,366,712,50)];\n    self.locationBarScroll.hasHorizontalScroller=YES; self.locationBarScroll.hasVerticalScroller=NO; self.locationBarScroll.borderType=NSBezelBorder;\n    self.locationBarView=[[NSView alloc] initWithFrame:NSMakeRect(0,0,700,30)]; self.locationBarScroll.documentView=self.locationBarView; [v addSubview:self.locationBarScroll];\n'''
if status not in s: raise SystemExit('status UI insertion point missing')
s=s.replace(status,status_new,1)

old_scroll='''    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(24,110,712,330)]; scroll.hasVerticalScroller=YES; scroll.borderType=NSBezelBorder;\n'''
new_scroll='''    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(24,110,712,246)]; scroll.hasVerticalScroller=YES; scroll.borderType=NSBezelBorder;\n'''
if old_scroll not in s: raise SystemExit('message log frame insertion point missing')
s=s.replace(old_scroll,new_scroll,1)

start_old='''- (void)startPolling {\n    [self.pollTimer invalidate]; self.pollTimer=[NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(pollNow:) userInfo:nil repeats:YES]; [self pollNow:nil];\n}\n'''
start_new='''- (void)startPolling {\n    [self.pollTimer invalidate]; self.pollTimer=[NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(pollNow:) userInfo:nil repeats:YES]; [self pollNow:nil];\n    [self.locationRefreshTimer invalidate]; self.locationRefreshTimer=[NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(refreshLocations:) userInfo:nil repeats:YES]; [self refreshLocations:nil];\n}\n\n- (void)refreshLocations:(id)sender {\n    if(!self.token.length)return;\n    [self requestAction:@"locations" method:@"GET" params:@{} token:self.token completion:^(NSDictionary *json,NSError *error){\n        dispatch_async(dispatch_get_main_queue(), ^{\n            if(error){ [self showLocationBarMessage:@"Locations unavailable — install website 2.5.23+"]; return; }\n            id rows=[json objectForKey:@"locations"]; self.activeLocations=[rows isKindOfClass:[NSArray class]]?(NSArray *)rows:@[]; [self rebuildLocationButtons];\n        });\n    }];\n}\n\n- (void)showLocationBarMessage:(NSString *)message {\n    for(NSView *sub in [self.locationBarView.subviews copy])[sub removeFromSuperview];\n    NSTextField *l=[self label:message ?: @"No active locations" frame:NSMakeRect(10,6,650,22) size:12 bold:NO]; [self.locationBarView addSubview:l];\n    self.locationBarView.frame=NSMakeRect(0,0,700,34);\n}\n\n- (void)rebuildLocationButtons {\n    for(NSView *sub in [self.locationBarView.subviews copy])[sub removeFromSuperview];\n    if(self.activeLocations.count==0){ [self showLocationBarMessage:@"No other active locations"]; return; }\n    CGFloat x=8.0; NSDictionary *attrs=@{NSFontAttributeName:[NSFont boldSystemFontOfSize:12]};\n    for(NSDictionary *loc in self.activeLocations){\n        NSInteger lid=[[loc objectForKey:@"id"] integerValue]; NSString *name=[[loc objectForKey:@"name"] description]; if(lid<=0||!name.length)continue;\n        CGFloat width=MAX(105.0,MIN(210.0,[name sizeWithAttributes:attrs].width+34.0));\n        NSButton *b=[[NSButton alloc] initWithFrame:NSMakeRect(x,4,width,30)]; b.title=name; b.font=[NSFont boldSystemFontOfSize:12]; b.bezelStyle=NSBezelStyleRounded; b.tag=lid; b.target=self; b.action=@selector(locationButtonClicked:); [self.locationBarView addSubview:b]; x+=width+8.0;\n    }\n    CGFloat viewport=self.locationBarScroll.contentView.bounds.size.width; self.locationBarView.frame=NSMakeRect(0,0,MAX(viewport,x+4.0),38);\n}\n\n- (void)locationButtonClicked:(NSButton *)button {\n    if(!self.token.length||button.tag<=0)return;\n    NSString *targetName=button.title.length?button.title:@"Location";\n    NSAlert *a=[[NSAlert alloc] init]; a.messageText=[NSString stringWithFormat:@"Message %@",targetName]; a.informativeText=@"This sends a direct Church Communications message from this location.";\n    NSScrollView *sv=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,430,140)]; sv.hasVerticalScroller=YES; sv.borderType=NSBezelBorder; NSTextView *tv=[[NSTextView alloc] initWithFrame:sv.bounds]; tv.font=[NSFont systemFontOfSize:18]; tv.string=@""; sv.documentView=tv; a.accessoryView=sv;\n    [a addButtonWithTitle:@"Send Message"]; [a addButtonWithTitle:@"Cancel"]; [NSApp activateIgnoringOtherApps:YES];\n    if([a runModal]!=NSAlertFirstButtonReturn)return;\n    NSString *body=[tv.string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; if(!body.length)return;\n    self.statusLabel.stringValue=[NSString stringWithFormat:@"Sending to %@…",targetName];\n    [self requestAction:@"send_location" method:@"POST" params:@{ @"target_location_id":@(button.tag), @"body":body } token:self.token completion:^(NSDictionary *json,NSError *error){\n        dispatch_async(dispatch_get_main_queue(), ^{\n            if(error){ self.statusLabel.stringValue=@"Connected — waiting for direct messages"; [self showError:error.localizedDescription]; [self refreshLocations:nil]; return; }\n            NSInteger tid=[[json objectForKey:@"thread_id"] integerValue]; if(tid>0){ self.currentThreadID=tid; self.sendButton.enabled=YES; }\n            [self appendLog:[NSString stringWithFormat:@"TECHBOOTH → %@\\n%@",targetName,body]]; self.statusLabel.stringValue=[NSString stringWithFormat:@"Sent to %@",targetName];\n            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ if(self.token.length)self.statusLabel.stringValue=@"Connected — waiting for direct messages"; });\n        });\n    }];\n}\n'''
if start_old not in s: raise SystemExit('startPolling insertion point missing')
s=s.replace(start_old,start_new,1)

clear_old='''    [self.pollTimer invalidate]; self.pollTimer=nil; self.token=nil; self.locationName=@"Not connected"; self.locationID=0; self.cursor=0; self.currentThreadID=0; self.sendButton.enabled=NO; self.locationLabel.stringValue=self.locationName; self.statusLabel.stringValue=@"Waiting for setup";\n'''
clear_new='''    [self.pollTimer invalidate]; self.pollTimer=nil; [self.locationRefreshTimer invalidate]; self.locationRefreshTimer=nil; self.activeLocations=@[]; [self showLocationBarMessage:@"Connect this Mac to load active locations"]; self.token=nil; self.locationName=@"Not connected"; self.locationID=0; self.cursor=0; self.currentThreadID=0; self.sendButton.enabled=NO; self.locationLabel.stringValue=self.locationName; self.statusLabel.stringValue=@"Waiting for setup";\n'''
if clear_old not in s: raise SystemExit('clearLocalConnection insertion point missing')
s=s.replace(clear_old,clear_new,1)

p.write_text(s)
PYLOC

"""
s=s.replace(marker,patch+marker,1)
verify="strings \"$EXE\" | grep -q 'MESSAGE FOR TECH BOOTH'\n"
s=s.replace(verify,verify+"strings \"$EXE\" | grep -q 'SEND TO ACTIVE LOCATION'\nstrings \"$EXE\" | grep -q 'send_location'\nstrings \"$EXE\" | grep -q 'locations'\n",1)
mounted="strings \"$MOUNT/Church Communications Tech Booth.app/Contents/MacOS/Church Communications Tech Booth\" | grep -q 'MESSAGE FOR TECH BOOTH'\n"
s=s.replace(mounted,mounted+"strings \"$MOUNT/Church Communications Tech Booth.app/Contents/MacOS/Church Communications Tech Booth\" | grep -q 'SEND TO ACTIVE LOCATION'\nstrings \"$MOUNT/Church Communications Tech Booth.app/Contents/MacOS/Church Communications Tech Booth\" | grep -q 'send_location'\n",1)
readme='''ALERT BEHAVIOR\nIncoming TECHBOOTH messages display as a huge, high-priority overlay across Spaces and over normal full-screen apps. The alert remains visible until OPEN APP or DISMISS is pressed.\n\nThis DMG contains the finished Mac application. No PKG installer is required.\n'''
readme_new='''ALERT BEHAVIOR\nIncoming TECHBOOTH messages display as a huge, high-priority overlay across Spaces and over normal full-screen apps. The alert remains visible until OPEN APP or DISMISS is pressed.\n\nACTIVE LOCATION BUTTONS\nThe buttons across the top are loaded from the Church Communications website. Only active locations are shown, and this Mac's own location is excluded. Click a location button to send it a direct message. Website 2.5.23 or newer is required for this feature.\n\nThis DMG contains the finished Mac application. No PKG installer is required.\n'''
s=s.replace(readme,readme_new,1)
p.write_text(s)
PYWRAP

chmod +x "$TMP_SCRIPT"
bash "$TMP_SCRIPT"

test -s releases/Church-Communications-Tech-Booth-3.0.3.dmg
test -s releases/Church-Communications-Tech-Booth-3.0.3.dmg.sha256.txt
