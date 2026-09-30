#import <Cocoa/Cocoa.h>
#import <sys/stat.h>

static NSString * const CCServer = @"https://compassionworship.com/cc/app/location-helper-api.php";
static NSString * const CCAppName = @"Church Communications Location Station";
static NSString * const CCTokenKey = @"CCLocationToken";
static NSString * const CCLocationNameKey = @"CCLocationName";
static NSString * const CCLocationIDKey = @"CCLocationID";
static NSString * const CCCursorKey = @"CCAlertCursor";

typedef void (^CCJSONCompletion)(NSDictionary *json, NSError *error);
typedef void (^CCTextCompletion)(NSString *text, NSError *error);

@interface CCAppDelegate : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSTextFieldDelegate>
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) NSTextField *locationLabel;
@property(nonatomic,strong) NSTextField *statusLabel;
@property(nonatomic,strong) NSTableView *threadsTable;
@property(nonatomic,strong) NSTableView *messagesTable;
@property(nonatomic,strong) NSScrollView *threadsScroll;
@property(nonatomic,strong) NSScrollView *messagesScroll;
@property(nonatomic,strong) NSTextField *messageField;
@property(nonatomic,strong) NSButton *sendButton;
@property(nonatomic,strong) NSButton *refreshButton;
@property(nonatomic,strong) NSButton *newMessageButton;
@property(nonatomic,strong) NSButton *pairButton;
@property(nonatomic,strong) NSButton *settingsButton;
@property(nonatomic,strong) NSButton *soundButton;
@property(nonatomic,strong) NSButton *keepAwakeButton;
@property(nonatomic,strong) NSMutableArray *threads;
@property(nonatomic,strong) NSMutableArray *messages;
@property(nonatomic,strong) NSMutableDictionary *threadByID;
@property(nonatomic,strong) NSString *selectedThreadID;
@property(nonatomic,strong) NSString *token;
@property(nonatomic,strong) NSString *locationName;
@property(nonatomic,assign) NSInteger locationID;
@property(nonatomic,assign) NSInteger cursor;
@property(nonatomic,strong) NSTimer *pollTimer;
@property(nonatomic,strong) NSPanel *alertPanel;
@property(nonatomic,strong) NSTextField *alertTitle;
@property(nonatomic,strong) NSTextField *alertBody;
@property(nonatomic,strong) NSTextField *alertMeta;
@property(nonatomic,strong) NSMutableArray *pendingAlerts;
@property(nonatomic,assign) BOOL alertVisible;
@property(nonatomic,assign) BOOL soundEnabled;
@property(nonatomic,assign) BOOL keepAwakeEnabled;
@property(nonatomic,assign) IOPMAssertionID assertionID;
@end

#import <IOKit/pwr_mgt/IOPMLib.h>

@implementation CCAppDelegate

- (instancetype)init {
    if ((self = [super init])) {
        _threads = [NSMutableArray array];
        _messages = [NSMutableArray array];
        _threadByID = [NSMutableDictionary dictionary];
        _pendingAlerts = [NSMutableArray array];
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        _token = [d stringForKey:CCTokenKey];
        _locationName = [d stringForKey:CCLocationNameKey] ?: @"Location Station";
        _locationID = [d integerForKey:CCLocationIDKey];
        _cursor = [d integerForKey:CCCursorKey];
        _soundEnabled = [d objectForKey:@"CCSoundEnabled"] ? [d boolForKey:@"CCSoundEnabled"] : YES;
        _keepAwakeEnabled = [d boolForKey:@"CCKeepAwakeEnabled"];
        _assertionID = kIOPMNullAssertionID;
    }
    return self;
}

static NSTextField *CCLabel(NSString *text, CGFloat size, NSFontWeight weight) {
    NSTextField *f = [NSTextField labelWithString:text ?: @""];
    f.font = [NSFont systemFontOfSize:size weight:weight];
    f.textColor = [NSColor labelColor];
    f.lineBreakMode = NSLineBreakByTruncatingTail;
    return f;
}

static NSButton *CCButton(NSString *title, id target, SEL action) {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    b.bezelStyle = NSBezelStyleRounded;
    return b;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self buildMainWindow];
    [self applyKeepAwake];
    if (self.token.length == 0) {
        [self showPairingSheet];
    } else {
        [self refreshAll:nil];
        [self startPolling];
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    [self releaseKeepAwake];
    return NSTerminateNow;
}

- (void)buildMainWindow {
    NSRect frame = NSMakeRect(0, 0, 1180, 760);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.title = CCAppName;
    self.window.minSize = NSMakeSize(900, 560);
    self.window.delegate = self;
    [self.window center];

    NSView *root = self.window.contentView;
    root.wantsLayer = YES;

    NSView *header = [[NSView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.wantsLayer = YES;
    header.layer.backgroundColor = [NSColor windowBackgroundColor].CGColor;
    [root addSubview:header];

    self.locationLabel = CCLabel(self.locationName, 25, NSFontWeightBold);
    self.locationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:self.locationLabel];

    self.statusLabel = CCLabel(@"Connecting…", 12, NSFontWeightRegular);
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    [header addSubview:self.statusLabel];

    self.refreshButton = CCButton(@"Refresh", self, @selector(refreshAll:));
    self.refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:self.refreshButton];

    self.newMessageButton = CCButton(@"New Message", self, @selector(newMessage:));
    self.newMessageButton.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:self.newMessageButton];

    self.soundButton = CCButton(self.soundEnabled ? @"Sound On" : @"Sound Off", self, @selector(toggleSound:));
    self.soundButton.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:self.soundButton];

    self.keepAwakeButton = CCButton(self.keepAwakeEnabled ? @"Keep Awake On" : @"Keep Awake", self, @selector(toggleKeepAwake:));
    self.keepAwakeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:self.keepAwakeButton];

    self.settingsButton = CCButton(@"Pair / Settings", self, @selector(showPairingSheet));
    self.settingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:self.settingsButton];

    NSView *body = [[NSView alloc] init];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:body];

    self.threadsTable = [[NSTableView alloc] init];
    self.threadsTable.delegate = self;
    self.threadsTable.dataSource = self;
    self.threadsTable.headerView = nil;
    self.threadsTable.rowHeight = 58;
    self.threadsTable.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    NSTableColumn *tc = [[NSTableColumn alloc] initWithIdentifier:@"threads"];
    tc.width = 300;
    [self.threadsTable addTableColumn:tc];

    self.threadsScroll = [[NSScrollView alloc] init];
    self.threadsScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.threadsScroll.documentView = self.threadsTable;
    self.threadsScroll.hasVerticalScroller = YES;
    self.threadsScroll.borderType = NSBezelBorder;
    [body addSubview:self.threadsScroll];

    NSView *chat = [[NSView alloc] init];
    chat.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:chat];

    self.messagesTable = [[NSTableView alloc] init];
    self.messagesTable.delegate = self;
    self.messagesTable.dataSource = self;
    self.messagesTable.headerView = nil;
    self.messagesTable.rowHeight = 62;
    NSTableColumn *mc = [[NSTableColumn alloc] initWithIdentifier:@"messages"];
    mc.width = 760;
    [self.messagesTable addTableColumn:mc];

    self.messagesScroll = [[NSScrollView alloc] init];
    self.messagesScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.messagesScroll.documentView = self.messagesTable;
    self.messagesScroll.hasVerticalScroller = YES;
    self.messagesScroll.borderType = NSBezelBorder;
    [chat addSubview:self.messagesScroll];

    self.messageField = [[NSTextField alloc] init];
    self.messageField.translatesAutoresizingMaskIntoConstraints = NO;
    self.messageField.placeholderString = @"Type a message…";
    self.messageField.delegate = self;
    [chat addSubview:self.messageField];

    self.sendButton = CCButton(@"Send", self, @selector(sendMessage:));
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.sendButton.keyEquivalent = @"\r";
    [chat addSubview:self.sendButton];

    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [header.topAnchor constraintEqualToAnchor:root.topAnchor],
        [header.heightAnchor constraintEqualToConstant:92],

        [self.locationLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [self.locationLabel.topAnchor constraintEqualToAnchor:header.topAnchor constant:16],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.locationLabel.leadingAnchor],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.locationLabel.bottomAnchor constant:4],

        [self.settingsButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-18],
        [self.settingsButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.keepAwakeButton.trailingAnchor constraintEqualToAnchor:self.settingsButton.leadingAnchor constant:-8],
        [self.keepAwakeButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.soundButton.trailingAnchor constraintEqualToAnchor:self.keepAwakeButton.leadingAnchor constant:-8],
        [self.soundButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.newMessageButton.trailingAnchor constraintEqualToAnchor:self.soundButton.leadingAnchor constant:-8],
        [self.newMessageButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.refreshButton.trailingAnchor constraintEqualToAnchor:self.newMessageButton.leadingAnchor constant:-8],
        [self.refreshButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [body.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [body.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [body.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],

        [self.threadsScroll.leadingAnchor constraintEqualToAnchor:body.leadingAnchor],
        [self.threadsScroll.topAnchor constraintEqualToAnchor:body.topAnchor],
        [self.threadsScroll.bottomAnchor constraintEqualToAnchor:body.bottomAnchor],
        [self.threadsScroll.widthAnchor constraintEqualToConstant:320],

        [chat.leadingAnchor constraintEqualToAnchor:self.threadsScroll.trailingAnchor],
        [chat.trailingAnchor constraintEqualToAnchor:body.trailingAnchor],
        [chat.topAnchor constraintEqualToAnchor:body.topAnchor],
        [chat.bottomAnchor constraintEqualToAnchor:body.bottomAnchor],

        [self.messagesScroll.leadingAnchor constraintEqualToAnchor:chat.leadingAnchor constant:10],
        [self.messagesScroll.trailingAnchor constraintEqualToAnchor:chat.trailingAnchor constant:-10],
        [self.messagesScroll.topAnchor constraintEqualToAnchor:chat.topAnchor constant:10],
        [self.messagesScroll.bottomAnchor constraintEqualToAnchor:self.messageField.topAnchor constant:-10],

        [self.messageField.leadingAnchor constraintEqualToAnchor:chat.leadingAnchor constant:10],
        [self.messageField.bottomAnchor constraintEqualToAnchor:chat.bottomAnchor constant:-12],
        [self.messageField.heightAnchor constraintEqualToConstant:38],
        [self.sendButton.leadingAnchor constraintEqualToAnchor:self.messageField.trailingAnchor constant:8],
        [self.sendButton.trailingAnchor constraintEqualToAnchor:chat.trailingAnchor constant:-10],
        [self.sendButton.bottomAnchor constraintEqualToAnchor:self.messageField.bottomAnchor],
        [self.sendButton.widthAnchor constraintEqualToConstant:90],
        [self.sendButton.heightAnchor constraintEqualToAnchor:self.messageField.heightAnchor]
    ]];

    [self.window makeKeyAndOrderFront:nil];
    [self updateSendState];
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    if ([obj.userInfo[@"NSTextMovement"] integerValue] == NSReturnTextMovement) [self sendMessage:nil];
}

- (void)updateSendState {
    BOOL ok = self.token.length > 0 && self.selectedThreadID.length > 0;
    self.messageField.enabled = ok;
    self.sendButton.enabled = ok;
}

- (void)setStatus:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{ self.statusLabel.stringValue = s ?: @""; });
}

- (NSMutableURLRequest *)requestForAction:(NSString *)action params:(NSDictionary *)params {
    NSURLComponents *c = [NSURLComponents componentsWithString:CCServer];
    NSMutableArray *items = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"action" value:action]];
    if (self.token.length) [items addObject:[NSURLQueryItem queryItemWithName:@"token" value:self.token]];
    [params enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        [items addObject:[NSURLQueryItem queryItemWithName:[key description] value:[obj description]]];
    }];
    c.queryItems = items;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:c.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [r setValue:@"ChurchCommunications-Mac-Native/2.0.1" forHTTPHeaderField:@"User-Agent"];
    return r;
}

- (void)getJSON:(NSString *)action params:(NSDictionary *)params completion:(CCJSONCompletion)completion {
    NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:[self requestForAction:action params:params ?: @{}] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { completion(nil,error); return; }
        NSError *e=nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&e];
        if (![obj isKindOfClass:NSDictionary.class]) {
            if (!e) e=[NSError errorWithDomain:@"CC" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Invalid server response"}];
            completion(nil,e); return;
        }
        completion(obj,nil);
    }];
    [t resume];
}

- (void)postForm:(NSString *)action params:(NSDictionary *)params completion:(CCJSONCompletion)completion {
    NSMutableURLRequest *r = [self requestForAction:action params:@{}];
    r.HTTPMethod = @"POST";
    NSMutableDictionary *p=[params mutableCopy] ?: [NSMutableDictionary dictionary];
    if (self.token.length) p[@"token"] = self.token;
    p[@"action"] = action;
    NSMutableArray *parts=[NSMutableArray array];
    [p enumerateKeysAndObjectsUsingBlock:^(id key,id obj,BOOL *stop){
        NSString *v=[[obj description] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
        [parts addObject:[NSString stringWithFormat:@"%@=%@",key,v ?: @""]];
    }];
    r.HTTPBody=[[parts componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    [r setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    NSURLSessionDataTask *t=[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        if(error){ completion(nil,error); return; }
        NSError *e=nil; id obj=[NSJSONSerialization JSONObjectWithData:data options:0 error:&e];
        if(![obj isKindOfClass:NSDictionary.class]) { if(!e)e=[NSError errorWithDomain:@"CC" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Invalid server response"}]; completion(nil,e); return; }
        completion(obj,nil);
    }]; [t resume];
}

- (void)refreshAll:(id)sender {
    if (!self.token.length) { [self showPairingSheet]; return; }
    [self setStatus:@"Refreshing…"];
    [self getJSON:@"station_threads" params:@{} completion:^(NSDictionary *json, NSError *error) {
        if(error){ [self setStatus:error.localizedDescription]; return; }
        if(![json[@"ok"] boolValue]) { [self setStatus:json[@"error"] ?: @"Unable to load conversations"]; return; }
        NSArray *arr=[json[@"threads"] isKindOfClass:NSArray.class] ? json[@"threads"] : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.threads removeAllObjects];
            [self.threadByID removeAllObjects];
            for(NSDictionary *d in arr){
                NSMutableDictionary *m=[d mutableCopy];
                NSString *tid=[m[@"id"] description];
                if(tid.length){ [self.threads addObject:m]; self.threadByID[tid]=m; }
            }
            [self.threadsTable reloadData];
            if(self.selectedThreadID.length){
                NSUInteger idx=[self.threads indexOfObjectPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop){ return [[obj[@"id"] description] isEqualToString:self.selectedThreadID]; }];
                if(idx!=NSNotFound){ [self.threadsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:idx] byExtendingSelection:NO]; }
            }
            if(!self.selectedThreadID.length && self.threads.count){ [self.threadsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO]; [self tableViewSelectionDidChange:[NSNotification notificationWithName:NSTableViewSelectionDidChangeNotification object:self.threadsTable]]; }
            [self setStatus:[NSString stringWithFormat:@"Connected • %lu conversation%@",(unsigned long)self.threads.count,self.threads.count==1?@"":@"s"]];
        });
    }];
}

- (void)loadMessagesForThread:(NSString *)threadID {
    if(!threadID.length)return;
    [self getJSON:@"station_messages" params:@{ @"thread":threadID } completion:^(NSDictionary *json,NSError *error){
        if(error){ [self setStatus:error.localizedDescription]; return; }
        NSArray *arr=[json[@"messages"] isKindOfClass:NSArray.class] ? json[@"messages"] : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.messages removeAllObjects]; [self.messages addObjectsFromArray:arr]; [self.messagesTable reloadData];
            if(self.messages.count){ [self.messagesTable scrollRowToVisible:self.messages.count-1]; }
        });
    }];
}

- (void)sendMessage:(id)sender {
    NSString *body=[self.messageField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!body.length || !self.selectedThreadID.length)return;
    self.sendButton.enabled=NO;
    [self postForm:@"station_send" params:@{ @"thread":self.selectedThreadID, @"message":body } completion:^(NSDictionary *json,NSError *error){
        dispatch_async(dispatch_get_main_queue(), ^{ self.sendButton.enabled=YES; });
        if(error){ [self setStatus:error.localizedDescription]; return; }
        if(![json[@"ok"] boolValue]){ [self setStatus:json[@"error"] ?: @"Send failed"]; return; }
        dispatch_async(dispatch_get_main_queue(), ^{ self.messageField.stringValue=@""; });
        [self loadMessagesForThread:self.selectedThreadID];
    }];
}

- (void)newMessage:(id)sender {
    if(!self.token.length)return;
    [self getJSON:@"station_recipients" params:@{} completion:^(NSDictionary *json,NSError *error){
        if(error){ [self setStatus:error.localizedDescription]; return; }
        NSArray *rec=[json[@"recipients"] isKindOfClass:NSArray.class]?json[@"recipients"]:@[];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *a=[[NSAlert alloc]init]; a.messageText=@"New Location Message";
            NSPopUpButton *pop=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(0,0,320,28)];
            NSMutableArray *ids=[NSMutableArray array];
            for(NSDictionary *r in rec){ [pop addItemWithTitle:[r[@"name"] description]]; [ids addObject:[r[@"id"] description]]; }
            NSTextField *msg=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,320,32)]; msg.placeholderString=@"Message";
            NSStackView *stack=[[NSStackView alloc]initWithFrame:NSMakeRect(0,0,330,75)]; stack.orientation=NSUserInterfaceLayoutOrientationVertical; stack.spacing=8; [stack addArrangedSubview:pop]; [stack addArrangedSubview:msg]; a.accessoryView=stack;
            [a addButtonWithTitle:@"Send"]; [a addButtonWithTitle:@"Cancel"];
            if([a runModal]==NSAlertFirstButtonReturn && pop.indexOfSelectedItem>=0 && msg.stringValue.length){
                NSString *rid=ids[pop.indexOfSelectedItem];
                [self postForm:@"station_new_message" params:@{@"recipient":rid,@"message":msg.stringValue} completion:^(NSDictionary *j,NSError *e){ if(e){[self setStatus:e.localizedDescription];return;} [self refreshAll:nil]; }];
            }
        });
    }];
}

- (void)showPairingSheet { [self showPairingSheet:nil]; }
- (void)showPairingSheet:(id)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *a=[[NSAlert alloc]init]; a.messageText=@"Pair This Mac Location"; a.informativeText=@"Enter the 8-digit Mac setup code from Church Communications.";
        NSTextField *code=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,280,30)]; code.placeholderString=@"8-digit setup code"; code.font=[NSFont monospacedDigitSystemFontOfSize:18 weight:NSFontWeightSemibold]; a.accessoryView=code;
        [a addButtonWithTitle:@"Pair"]; [a addButtonWithTitle:@"Cancel"];
        if([a runModal]!=NSAlertFirstButtonReturn)return;
        NSString *c=[[code.stringValue componentsSeparatedByCharactersInSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet] componentsJoinedByString:@""];
        if(c.length!=8){ [self setStatus:@"Setup code must be 8 digits"]; return; }
        [self postForm:@"pair_native" params:@{@"code":c} completion:^(NSDictionary *json,NSError *error){
            if(error){[self setStatus:error.localizedDescription];return;}
            if(![json[@"ok"] boolValue]){[self setStatus:json[@"error"]?:@"Pairing failed"];return;}
            NSString *tok=[json[@"token"] description]; NSString *name=[json[@"location_name"] description]; NSInteger lid=[json[@"location_id"] integerValue];
            if(!tok.length){[self setStatus:@"Server did not return a location token"];return;}
            self.token=tok; self.locationName=name.length?name:@"Location Station"; self.locationID=lid;
            NSUserDefaults *d=[NSUserDefaults standardUserDefaults]; [d setObject:tok forKey:CCTokenKey]; [d setObject:self.locationName forKey:CCLocationNameKey]; [d setInteger:lid forKey:CCLocationIDKey]; [d synchronize];
            dispatch_async(dispatch_get_main_queue(), ^{ self.locationLabel.stringValue=self.locationName; [self updateSendState]; });
            [self refreshAll:nil]; [self startPolling];
        }];
    });
}

- (void)startPolling {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.pollTimer invalidate];
        self.pollTimer=[NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(pollAlerts:) userInfo:nil repeats:YES];
        [self pollAlerts:nil];
    });
}

- (void)pollAlerts:(id)sender {
    if(!self.token.length)return;
    NSInteger startCursor=self.cursor;
    [self getJSON:@"station_alerts" params:@{@"after":@(startCursor)} completion:^(NSDictionary *json,NSError *error){
        if(error)return;
        NSArray *arr=[json[@"alerts"] isKindOfClass:NSArray.class]?json[@"alerts"]:@[];
        __block NSInteger finalCursor=startCursor;
        NSMutableArray *incoming=[NSMutableArray array];
        for(NSDictionary *m in arr){
            NSInteger mid=[m[@"id"] integerValue]; finalCursor=MAX(finalCursor,mid);
            if([m[@"direct_to_location"] boolValue]) [incoming addObject:m];
        }
        if(finalCursor>self.cursor){ self.cursor=finalCursor; NSUserDefaults *d=[NSUserDefaults standardUserDefaults]; [d setInteger:finalCursor forKey:CCCursorKey]; }
        if(incoming.count){
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.pendingAlerts addObjectsFromArray:incoming]; [self presentNextAlertIfNeeded];
                [self refreshAll:nil];
                if(self.selectedThreadID.length) [self loadMessagesForThread:self.selectedThreadID];
            });
        }
    }];
}

- (void)presentNextAlertIfNeeded {
    if(self.alertVisible || !self.pendingAlerts.count)return;
    NSDictionary *m=self.pendingAlerts.firstObject; [self.pendingAlerts removeObjectAtIndex:0];
    self.alertVisible=YES;
    if(!self.alertPanel){
        self.alertPanel=[[NSPanel alloc]initWithContentRect:NSMakeRect(0,0,620,360) styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
        self.alertPanel.level=NSStatusWindowLevel+4;
        self.alertPanel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorStationary;
        self.alertPanel.hidesOnDeactivate=NO;
        self.alertPanel.floatingPanel=YES;
        NSView *v=self.alertPanel.contentView;
        self.alertTitle=CCLabel(@"LOCATION MESSAGE",25,NSFontWeightBold); self.alertTitle.translatesAutoresizingMaskIntoConstraints=NO; [v addSubview:self.alertTitle];
        self.alertMeta=CCLabel(@"",13,NSFontWeightSemibold); self.alertMeta.translatesAutoresizingMaskIntoConstraints=NO; self.alertMeta.textColor=[NSColor secondaryLabelColor]; [v addSubview:self.alertMeta];
        self.alertBody=CCLabel(@"",24,NSFontWeightMedium); self.alertBody.translatesAutoresizingMaskIntoConstraints=NO; self.alertBody.maximumNumberOfLines=6; self.alertBody.lineBreakMode=NSLineBreakByWordWrapping; [v addSubview:self.alertBody];
        NSButton *dismiss=CCButton(@"Dismiss",self,@selector(dismissAlert:)); dismiss.translatesAutoresizingMaskIntoConstraints=NO; [v addSubview:dismiss];
        NSButton *open=CCButton(@"Open Location Station",self,@selector(openAlert:)); open.translatesAutoresizingMaskIntoConstraints=NO; [v addSubview:open];
        [NSLayoutConstraint activateConstraints:@[
            [self.alertTitle.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:28],[self.alertTitle.topAnchor constraintEqualToAnchor:v.topAnchor constant:26],
            [self.alertMeta.leadingAnchor constraintEqualToAnchor:self.alertTitle.leadingAnchor],[self.alertMeta.topAnchor constraintEqualToAnchor:self.alertTitle.bottomAnchor constant:8],
            [self.alertBody.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:28],[self.alertBody.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-28],[self.alertBody.topAnchor constraintEqualToAnchor:self.alertMeta.bottomAnchor constant:22],
            [dismiss.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:28],[dismiss.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-24],[dismiss.widthAnchor constraintEqualToConstant:120],
            [open.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-28],[open.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-24],[open.widthAnchor constraintEqualToConstant:180]
        ]];
    }
    self.alertPanel.title=[NSString stringWithFormat:@"%@ — New Message",self.locationName];
    self.alertMeta.stringValue=[NSString stringWithFormat:@"From %@",[m[@"sender"] description] ?: @"Church Communications"];
    self.alertBody.stringValue=[m[@"message"] description] ?: @"New message";
    objc_setAssociatedObject(self.alertPanel, @selector(openAlert:), m, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.alertPanel center]; [self.alertPanel makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    [self.alertPanel orderFrontRegardless];
    if(self.soundEnabled) [[NSSound soundNamed:@"Glass"] play];
}

- (void)dismissAlert:(id)sender { self.alertVisible=NO; [self.alertPanel orderOut:nil]; [self presentNextAlertIfNeeded]; }
- (void)openAlert:(id)sender {
    NSDictionary *m=objc_getAssociatedObject(self.alertPanel,@selector(openAlert:)); NSString *tid=[m[@"thread"] description];
    if(tid.length){ self.selectedThreadID=tid; NSUInteger idx=[self.threads indexOfObjectPassingTest:^BOOL(NSDictionary *obj,NSUInteger idx,BOOL *stop){return [[[obj objectForKey:@"id"] description] isEqualToString:tid];}]; if(idx!=NSNotFound)[self.threadsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:idx] byExtendingSelection:NO]; [self loadMessagesForThread:tid]; }
    [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; [self dismissAlert:nil];
}

- (void)toggleSound:(id)sender { self.soundEnabled=!self.soundEnabled; [[NSUserDefaults standardUserDefaults] setBool:self.soundEnabled forKey:@"CCSoundEnabled"]; self.soundButton.title=self.soundEnabled?@"Sound On":@"Sound Off"; }
- (void)toggleKeepAwake:(id)sender { self.keepAwakeEnabled=!self.keepAwakeEnabled; [[NSUserDefaults standardUserDefaults] setBool:self.keepAwakeEnabled forKey:@"CCKeepAwakeEnabled"]; [self applyKeepAwake]; self.keepAwakeButton.title=self.keepAwakeEnabled?@"Keep Awake On":@"Keep Awake"; }
- (void)applyKeepAwake {
    if(self.keepAwakeEnabled && self.assertionID==kIOPMNullAssertionID){ IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep,kIOPMAssertionLevelOn,CFSTR("Church Communications Location Station"),&_assertionID); }
    else if(!self.keepAwakeEnabled) [self releaseKeepAwake];
}
- (void)releaseKeepAwake { if(self.assertionID!=kIOPMNullAssertionID){ IOPMAssertionRelease(self.assertionID); self.assertionID=kIOPMNullAssertionID; } }

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return tableView==self.threadsTable?self.threads.count:self.messages.count; }
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSString *ident=tableView==self.threadsTable?@"ThreadCell":@"MessageCell";
    NSTableCellView *cell=[tableView makeViewWithIdentifier:ident owner:self];
    if(!cell){ cell=[[NSTableCellView alloc]init]; cell.identifier=ident; NSTextField *t=CCLabel(@"",tableView==self.threadsTable?14:13,NSFontWeightRegular); t.tag=101; t.translatesAutoresizingMaskIntoConstraints=NO; t.maximumNumberOfLines=3; t.lineBreakMode=NSLineBreakByWordWrapping; [cell addSubview:t]; [NSLayoutConstraint activateConstraints:@[[t.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10],[t.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-10],[t.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]]]; }
    NSTextField *t=[cell viewWithTag:101];
    NSDictionary *d=tableView==self.threadsTable?self.threads[row]:self.messages[row];
    if(tableView==self.threadsTable){ NSString *name=[d[@"name"] description]?:@"Conversation"; NSString *preview=[d[@"preview"] description]?:@""; t.stringValue=preview.length?[NSString stringWithFormat:@"%@\n%@",name,preview]:name; }
    else { NSString *sender=[d[@"sender"] description]?:@""; NSString *body=[d[@"message"] description]?:@""; NSString *time=[d[@"time"] description]?:@""; t.stringValue=[NSString stringWithFormat:@"%@%@\n%@",sender,time.length?[NSString stringWithFormat:@" • %@",time]:@"",body]; }
    return cell;
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if(notification.object!=self.threadsTable)return; NSInteger row=self.threadsTable.selectedRow; if(row<0||row>=self.threads.count)return; self.selectedThreadID=[[self.threads[row] objectForKey:@"id"] description]; [self updateSendState]; [self loadMessagesForThread:self.selectedThreadID];
}
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app=[NSApplication sharedApplication];
        CCAppDelegate *delegate=[[CCAppDelegate alloc]init];
        app.delegate=delegate;
        [app run];
    }
    return 0;
}
