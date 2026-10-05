#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

static NSString * const CCSAPI = @"https://www.compassionworship.com/cc/station-v3-api.php";
static NSString * const CCTokenKey = @"CCStationV3Token";
static NSString * const CCLocationNameKey = @"CCStationV3LocationName";
static NSString * const CCLocationIDKey = @"CCStationV3LocationID";
static NSString * const CCCursorKey = @"CCStationV3Cursor";

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property NSTextField *locationLabel;
@property NSTextField *statusLabel;
@property NSTextView *logView;
@property NSTextField *replyField;
@property NSButton *sendButton;
@property NSTimer *pollTimer;
@property NSString *token;
@property NSString *locationName;
@property NSInteger locationID;
@property NSInteger cursor;
@property NSInteger currentThreadID;
@property NSPanel *alertPanel;
@property NSTextField *alertTitle;
@property NSTextField *alertSender;
@property NSTextField *alertBody;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self buildMainWindow];
    NSUserDefaults *d=[NSUserDefaults standardUserDefaults];
    self.token=[d stringForKey:CCTokenKey];
    self.locationName=[d stringForKey:CCLocationNameKey] ?: @"Not connected";
    self.locationID=[d integerForKey:CCLocationIDKey];
    self.cursor=[d integerForKey:CCCursorKey];
    self.locationLabel.stringValue=self.locationName;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self installLoginAgentIfPossible];
    if(self.token.length){
        [self validateSavedConnection];
    }else{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [self showSetupDialog]; });
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(CGFloat)size bold:(BOOL)bold {
    NSTextField *l=[[NSTextField alloc] initWithFrame:frame];
    l.stringValue=text ?: @""; l.editable=NO; l.bezeled=NO; l.drawsBackground=NO; l.selectable=YES;
    l.font=bold?[NSFont boldSystemFontOfSize:size]:[NSFont systemFontOfSize:size];
    return l;
}

- (void)buildMainWindow {
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,760,560)
                                           styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable)
                                             backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"Church Communications Tech Booth — 3.0.0";
    [self.window center];
    NSView *v=self.window.contentView;

    NSTextField *title=[self label:@"CHURCH COMMUNICATIONS — TECH BOOTH" frame:NSMakeRect(24,510,500,28) size:20 bold:YES]; [v addSubview:title];
    self.locationLabel=[self label:@"Not connected" frame:NSMakeRect(24,478,430,24) size:16 bold:YES]; [v addSubview:self.locationLabel];
    self.statusLabel=[self label:@"Waiting for setup" frame:NSMakeRect(24,452,600,22) size:13 bold:NO]; [v addSubview:self.statusLabel];

    NSButton *setup=[[NSButton alloc] initWithFrame:NSMakeRect(610,480,120,30)]; setup.title=@"Setup / Reset"; setup.bezelStyle=NSBezelStyleRounded; setup.target=self; setup.action=@selector(resetClicked:); [v addSubview:setup];

    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(24,110,712,330)]; scroll.hasVerticalScroller=YES; scroll.borderType=NSBezelBorder;
    self.logView=[[NSTextView alloc] initWithFrame:scroll.bounds]; self.logView.editable=NO; self.logView.selectable=YES; self.logView.font=[NSFont systemFontOfSize:14]; self.logView.string=@"Messages sent directly to this location in the last two hours will appear here.\n\n"; scroll.documentView=self.logView; [v addSubview:scroll];

    self.replyField=[[NSTextField alloc] initWithFrame:NSMakeRect(24,56,600,36)]; self.replyField.placeholderString=@"Reply to the most recent direct TECHBOOTH conversation…"; [v addSubview:self.replyField];
    self.sendButton=[[NSButton alloc] initWithFrame:NSMakeRect(635,56,101,36)]; self.sendButton.title=@"Send Reply"; self.sendButton.bezelStyle=NSBezelStyleRounded; self.sendButton.target=self; self.sendButton.action=@selector(sendReply:); self.sendButton.enabled=NO; [v addSubview:self.sendButton];

    NSTextField *foot=[self label:@"Native Mac app • Intel/Catalina 10.15+ • Starts with the Mac • Direct alerts expire after 2 hours" frame:NSMakeRect(24,20,700,20) size:11 bold:NO]; [v addSubview:foot];
}

- (void)appendLog:(NSString *)text {
    if(!text.length)return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *s=[NSString stringWithFormat:@"%@%@\n",self.logView.string ?: @"",text];
        self.logView.string=s;
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.string.length,0)];
    });
}

- (NSError *)errorWithMessage:(NSString *)message code:(NSInteger)code {
    return [NSError errorWithDomain:@"ChurchCommunicationsTechBooth" code:code userInfo:@{NSLocalizedDescriptionKey:message ?: @"Unknown error"}];
}

- (NSString *)urlEncode:(NSString *)s {
    NSMutableCharacterSet *allowed=[[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

- (void)requestAction:(NSString *)action method:(NSString *)method params:(NSDictionary *)params token:(NSString *)token completion:(void(^)(NSDictionary *,NSError *))completion {
    NSMutableString *url=[NSMutableString stringWithFormat:@"%@?action=%@",CCSAPI,[self urlEncode:action]];
    if([method isEqualToString:@"GET"]){
        for(NSString *k in params){ [url appendFormat:@"&%@=%@",[self urlEncode:k],[self urlEncode:[[params objectForKey:k] description]]]; }
    }
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
    r.HTTPMethod=method; [r setValue:@"ChurchCommunications-TechBooth/3.0.0" forHTTPHeaderField:@"User-Agent"];
    if(token.length)[r setValue:token forHTTPHeaderField:@"X-CC-Station-Token"];
    if([method isEqualToString:@"POST"]){
        NSMutableArray *parts=[NSMutableArray array];
        for(NSString *k in params){ [parts addObject:[NSString stringWithFormat:@"%@=%@",[self urlEncode:k],[self urlEncode:[[params objectForKey:k] description]]]]; }
        NSString *body=[parts componentsJoinedByString:@"&"]; r.HTTPBody=[body dataUsingEncoding:NSUTF8StringEncoding]; [r setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    }
    NSURLSessionDataTask *task=[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *data,NSURLResponse *response,NSError *err){
        if(err){ completion(nil,err); return; }
        NSHTTPURLResponse *hr=(NSHTTPURLResponse *)response;
        NSError *je=nil; id obj=data.length?[NSJSONSerialization JSONObjectWithData:data options:0 error:&je]:nil;
        if(![obj isKindOfClass:[NSDictionary class]]){
            NSString *raw=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
            if(raw.length>400)raw=[raw substringToIndex:400];
            NSString *m=[NSString stringWithFormat:@"Server response was not valid station data (HTTP %ld). %@",(long)hr.statusCode,raw]; completion(nil,[self errorWithMessage:m code:hr.statusCode]); return;
        }
        NSDictionary *json=(NSDictionary *)obj;
        if(hr.statusCode<200 || hr.statusCode>=300 || ![[json objectForKey:@"ok"] boolValue]){
            NSString *m=[[json objectForKey:@"error"] description]; if(!m.length)m=[NSString stringWithFormat:@"Station server returned HTTP %ld.",(long)hr.statusCode]; completion(json,[self errorWithMessage:m code:hr.statusCode]); return;
        }
        completion(json,nil);
    }]; [task resume];
}

- (void)showSetupDialog {
    NSAlert *a=[[NSAlert alloc] init]; a.messageText=@"Connect this Mac to TECHBOOTH";
    a.informativeText=@"On the Church Communications website, open Station Setup, choose TECHBOOTH, and generate a 6-digit setup code. Enter it below. This code is used once; the Mac then keeps its own permanent connection.";
    NSTextField *f=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,300,32)]; f.placeholderString=@"6-digit setup code"; f.font=[NSFont monospacedDigitSystemFontOfSize:18 weight:NSFontWeightSemibold]; a.accessoryView=f;
    [a addButtonWithTitle:@"Connect This Mac"]; [a addButtonWithTitle:@"Cancel"]; [NSApp activateIgnoringOtherApps:YES];
    if([a runModal]!=NSAlertFirstButtonReturn)return;
    NSString *digits=[[f.stringValue componentsSeparatedByCharactersInSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet] componentsJoinedByString:@""];
    if(digits.length!=6){ [self showError:@"Enter all 6 digits from the Station Setup page."]; [self showSetupDialog]; return; }
    self.statusLabel.stringValue=@"Connecting…";
    NSString *device=[[NSHost currentHost] localizedName]; if(!device.length)device=@"Mac Tech Booth";
    [self requestAction:@"pair" method:@"POST" params:@{ @"code":digits,@"device_name":device,@"app_version":@"3.0.0" } token:nil completion:^(NSDictionary *json,NSError *error){
        dispatch_async(dispatch_get_main_queue(), ^{
            if(error){ self.statusLabel.stringValue=@"Not connected"; [self showError:error.localizedDescription]; return; }
            self.token=[[json objectForKey:@"token"] description]; self.locationName=[[json objectForKey:@"location_name"] description]; self.locationID=[[json objectForKey:@"location_id"] integerValue]; self.cursor=0;
            if(self.token.length<40 || self.locationID<=0){ self.token=nil; [self showError:@"The server did not return a valid station connection."]; return; }
            NSUserDefaults *d=[NSUserDefaults standardUserDefaults]; [d setObject:self.token forKey:CCTokenKey]; [d setObject:self.locationName forKey:CCLocationNameKey]; [d setInteger:self.locationID forKey:CCLocationIDKey]; [d setInteger:0 forKey:CCCursorKey]; [d synchronize];
            self.locationLabel.stringValue=self.locationName; self.statusLabel.stringValue=@"Connected — waiting for direct messages"; [self appendLog:[NSString stringWithFormat:@"Connected to %@.",self.locationName]]; [self startPolling];
        });
    }];
}

- (void)validateSavedConnection {
    self.statusLabel.stringValue=@"Checking saved connection…";
    [self requestAction:@"status" method:@"GET" params:@{} token:self.token completion:^(NSDictionary *json,NSError *error){ dispatch_async(dispatch_get_main_queue(), ^{
        if(error){ [self clearLocalConnection]; [self showError:@"The old saved connection is no longer valid. Generate a fresh 6-digit Station Setup code."]; [self showSetupDialog]; return; }
        self.locationName=[[json objectForKey:@"location_name"] description]; self.locationID=[[json objectForKey:@"location_id"] integerValue]; self.locationLabel.stringValue=self.locationName; self.statusLabel.stringValue=@"Connected — waiting for direct messages"; [self startPolling];
    }); }];
}

- (void)startPolling {
    [self.pollTimer invalidate]; self.pollTimer=[NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(pollNow:) userInfo:nil repeats:YES]; [self pollNow:nil];
}

- (void)pollNow:(id)sender {
    if(!self.token.length)return;
    [self requestAction:@"poll" method:@"GET" params:@{ @"after":@(self.cursor) } token:self.token completion:^(NSDictionary *json,NSError *error){
        if(error){ dispatch_async(dispatch_get_main_queue(), ^{ self.statusLabel.stringValue=[NSString stringWithFormat:@"Connection problem — %@",error.localizedDescription]; }); return; }
        NSArray *msgs=[json objectForKey:@"messages"] ?: @[]; NSInteger newCursor=[[json objectForKey:@"cursor"] integerValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            for(NSDictionary *m in msgs){ NSInteger mid=[[m objectForKey:@"id"] integerValue]; NSInteger tid=[[m objectForKey:@"thread_id"] integerValue]; NSString *sender=[[m objectForKey:@"sender"] description]; NSString *body=[[m objectForKey:@"body"] description]; NSString *title=[[m objectForKey:@"title"] description]; self.currentThreadID=tid; self.sendButton.enabled=(tid>0); [self appendLog:[NSString stringWithFormat:@"%@ — %@\n%@",sender,title,body]]; [self showNativeAlertFrom:sender title:title body:body threadID:tid messageID:mid]; }
            if(newCursor>self.cursor){ self.cursor=newCursor; [[NSUserDefaults standardUserDefaults] setInteger:self.cursor forKey:CCCursorKey]; [[NSUserDefaults standardUserDefaults] synchronize]; }
            self.statusLabel.stringValue=@"Connected — waiting for direct messages";
        });
    }];
}

- (void)showNativeAlertFrom:(NSString *)sender title:(NSString *)title body:(NSString *)body threadID:(NSInteger)threadID messageID:(NSInteger)messageID {
    dispatch_async(dispatch_get_main_queue(), ^{
        if(!self.alertPanel){
            self.alertPanel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,720,330) styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskUtilityWindow) backing:NSBackingStoreBuffered defer:NO];
            self.alertPanel.title=@"TECHBOOTH MESSAGE"; self.alertPanel.hidesOnDeactivate=NO; self.alertPanel.releasedWhenClosed=NO; self.alertPanel.floatingPanel=YES;
            self.alertPanel.level=CGWindowLevelForKey(kCGMaximumWindowLevelKey)-1;
            self.alertPanel.collectionBehavior=(NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorStationary);
            NSView *v=self.alertPanel.contentView;
            self.alertTitle=[self label:@"DIRECT MESSAGE TO TECHBOOTH" frame:NSMakeRect(24,272,660,30) size:23 bold:YES]; [v addSubview:self.alertTitle];
            self.alertSender=[self label:@"" frame:NSMakeRect(24,238,660,26) size:17 bold:YES]; [v addSubview:self.alertSender];
            self.alertBody=[self label:@"" frame:NSMakeRect(24,90,660,140) size:20 bold:NO]; self.alertBody.maximumNumberOfLines=6; self.alertBody.lineBreakMode=NSLineBreakByWordWrapping; [v addSubview:self.alertBody];
            NSButton *open=[[NSButton alloc] initWithFrame:NSMakeRect(470,28,105,38)]; open.title=@"Open App"; open.bezelStyle=NSBezelStyleRounded; open.target=self; open.action=@selector(openFromAlert:); [v addSubview:open];
            NSButton *dismiss=[[NSButton alloc] initWithFrame:NSMakeRect(585,28,105,38)]; dismiss.title=@"Dismiss"; dismiss.bezelStyle=NSBezelStyleRounded; dismiss.target=self; dismiss.action=@selector(dismissAlert:); [v addSubview:dismiss];
        }
        self.alertSender.stringValue=[NSString stringWithFormat:@"%@ • %@",sender ?: @"Church Communications",title ?: @"Conversation"];
        self.alertBody.stringValue=body.length?body:@"New message";
        self.currentThreadID=threadID; self.sendButton.enabled=(threadID>0);
        [self.alertPanel center]; [NSApp activateIgnoringOtherApps:YES]; [self.alertPanel makeKeyAndOrderFront:nil]; [self.alertPanel orderFrontRegardless]; NSBeep();
    });
}

- (void)dismissAlert:(id)sender { [self.alertPanel orderOut:nil]; }
- (void)openFromAlert:(id)sender { [self.alertPanel orderOut:nil]; [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }

- (void)sendReply:(id)sender {
    if(!self.token.length || self.currentThreadID<=0){ [self showError:@"There is no direct conversation to reply to yet."]; return; }
    NSString *body=[self.replyField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; if(!body.length)return;
    self.sendButton.enabled=NO;
    [self requestAction:@"send" method:@"POST" params:@{ @"thread_id":@(self.currentThreadID),@"body":body } token:self.token completion:^(NSDictionary *json,NSError *error){ dispatch_async(dispatch_get_main_queue(), ^{
        self.sendButton.enabled=YES; if(error){ [self showError:error.localizedDescription]; return; } [self appendLog:[NSString stringWithFormat:@"TECHBOOTH\n%@",body]]; self.replyField.stringValue=@"";
    }); }];
}

- (void)resetClicked:(id)sender {
    NSAlert *a=[[NSAlert alloc] init]; a.messageText=@"Reset this Mac's station connection?"; a.informativeText=@"This clears only this Mac. You can immediately generate another 6-digit code from Station Setup."; [a addButtonWithTitle:@"Reset"]; [a addButtonWithTitle:@"Cancel"];
    if([a runModal]!=NSAlertFirstButtonReturn)return;
    NSString *old=[self.token copy]; if(old.length)[self requestAction:@"unpair" method:@"POST" params:@{} token:old completion:^(NSDictionary *j,NSError *e){}]; [self clearLocalConnection]; [self showSetupDialog];
}

- (void)clearLocalConnection {
    [self.pollTimer invalidate]; self.pollTimer=nil; self.token=nil; self.locationName=@"Not connected"; self.locationID=0; self.cursor=0; self.currentThreadID=0; self.sendButton.enabled=NO; self.locationLabel.stringValue=self.locationName; self.statusLabel.stringValue=@"Waiting for setup";
    NSUserDefaults *d=[NSUserDefaults standardUserDefaults]; [d removeObjectForKey:CCTokenKey]; [d removeObjectForKey:CCLocationNameKey]; [d removeObjectForKey:CCLocationIDKey]; [d removeObjectForKey:CCCursorKey]; [d synchronize];
}

- (void)showError:(NSString *)message { dispatch_async(dispatch_get_main_queue(), ^{ NSAlert *a=[[NSAlert alloc] init]; a.alertStyle=NSAlertStyleCritical; a.messageText=@"Church Communications Tech Booth"; a.informativeText=message ?: @"Unknown error"; [a addButtonWithTitle:@"OK"]; [NSApp activateIgnoringOtherApps:YES]; [a runModal]; }); }

- (void)installLoginAgentIfPossible {
    NSString *exe=[[NSBundle mainBundle] executablePath]; if(![exe hasPrefix:@"/Applications/"])return;
    NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"]; [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *plist=[dir stringByAppendingPathComponent:@"com.churchcommunications.techbooth.plist"];
    NSDictionary *obj=@{ @"Label":@"com.churchcommunications.techbooth", @"ProgramArguments":@[exe], @"RunAtLoad":@YES, @"KeepAlive":@NO };
    [obj writeToFile:plist atomically:YES];
    NSTask *unload=[[NSTask alloc] init]; unload.launchPath=@"/bin/launchctl"; unload.arguments=@[@"unload",plist]; @try{[unload launch];[unload waitUntilExit];}@catch(NSException *e){}
    NSTask *load=[[NSTask alloc] init]; load.launchPath=@"/bin/launchctl"; load.arguments=@[@"load",plist]; @try{[load launch];}@catch(NSException *e){}
}
@end

int main(int argc,const char *argv[]){ @autoreleasepool { NSApplication *app=[NSApplication sharedApplication]; AppDelegate *delegate=[AppDelegate new]; app.delegate=delegate; [app setActivationPolicy:NSApplicationActivationPolicyRegular]; [app run]; } return 0; }
