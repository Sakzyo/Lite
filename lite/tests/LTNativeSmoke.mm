#import "LTNativeSmoke.h"
#import "../macos/LTWindow.h"

// Exercise the same native command paths as the UI without exposing test flags
// in the browser engine or changing lifecycle state to manufacture a pass.
@interface LTWindow (NativeVerification)
- (LTPage *)activePage;
- (void)selectTab:(NSString *)identifier;
- (void)splitWith:(NSString *)identifier vertical:(BOOL)vertical;
@end

static NSArray<NSView *> *Views(NSView *root) {
    if (!root) return @[];
    NSMutableArray *views = [NSMutableArray arrayWithObject:root];
    for (NSView *view in root.subviews) [views addObjectsFromArray:Views(view)];
    return views;
}
static NSView *Label(NSWindow *window, NSString *label) {
    for (NSView *view in Views(window.contentView))
        if ([view.accessibilityLabel isEqual:label]) return view;
    return nil;
}
static NSButton *Button(NSWindow *window, NSString *title) {
    for (NSView *view in Views(window.contentView))
        if ([view isKindOfClass:NSButton.class] && [((NSButton *)view).title isEqual:title])
            return (NSButton *)view;
    return nil;
}
static NSWindow *VisibleWindow(NSString *title) {
    for (NSWindow *window in NSApp.windows)
        if (window.visible && [window.title isEqual:title]) return window;
    return nil;
}
static BOOL Focuses(NSWindow *window, LTPage *page) {
    NSResponder *responder = window.firstResponder;
    return [responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:page.container];
}
static void Key(NSWindow *window, NSString *characters, unsigned short code, NSEventModifierFlags flags) {
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
        characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:code];
    [NSApp sendEvent:event];
}
@interface LTNativeSmoke : NSObject
@property LTWindow *owner;
@property LTWindow *other;
@property LTWindow *privateWindow;
@property LTPage *primary;
@property LTPage *secondary;
@property LTPage *privatePage;
@property LTPage *otherPage;
@property LTPage *authPage;
@property NSView *sidebar;
@property NSWindow *panel;
@property NSTimer *timer;
@property NSMutableDictionary *results;
@property NSString *output;
@property(copy) void (^finished)(void);
@property NSInteger stage;
@property NSTimeInterval started;
@property NSTimeInterval next;
- (void)begin;
@end
static LTNativeSmoke *runningNative;
@implementation LTNativeSmoke
- (void)advance:(NSInteger)stage delay:(double)delay {
    _stage = stage;
    _next = NSDate.date.timeIntervalSince1970 + delay;
    [[NSString stringWithFormat:@"stage=%ld elapsed=%.2f\n", (long)stage, NSDate.date.timeIntervalSince1970 - _started]
        writeToFile:[_output stringByAppendingString:@".progress"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
- (void)record:(NSString *)name passed:(BOOL)passed { _results[name] = @(passed); }
- (void)begin {
    _results = [NSMutableDictionary dictionaryWithDictionary:@{@"processID": @(getpid()), @"scope": @"actual LTWindow AppKit and CEF integration"}];
    _started = NSDate.date.timeIntervalSince1970;
    [_owner openURL:@"http://127.0.0.1:18743/?native=primary"];
    _primary = [_owner activePage];
    __weak typeof(self) weak = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:.1 repeats:YES block:^(NSTimer *timer) { [weak tick]; }];
}
- (LTWindow *)additionalWindow:(BOOL)privateMode {
    for (NSWindow *window in NSApp.windows) {
        LTWindow *controller = (LTWindow *)window.windowController;
        if (window.visible && [controller isKindOfClass:LTWindow.class] && controller != _owner &&
            controller.store.privateMode == privateMode) return controller;
    }
    return nil;
}
- (void)verifyQuitCancellation {
    __block BOOL clickedCancel = NO;
    __block NSInteger attempts = 0;
    NSTimer *response = [NSTimer timerWithTimeInterval:.1 repeats:YES block:^(NSTimer *timer) {
        NSWindow *dialog = NSApp.modalWindow;
        NSButton *cancel = Button(dialog, @"Cancel");
        if (cancel && Button(dialog, @"Close All and Quit")) {
            clickedCancel = YES;
            [timer invalidate];
            [cancel performClick:nil];
        } else if (++attempts == 50) {
            // Release an unexpected modal loop so the failed check can be saved.
            [timer invalidate];
            [NSApp abortModal];
        }
    }];
    [NSRunLoop.currentRunLoop addTimer:response forMode:NSModalPanelRunLoopMode];
    [NSApp terminate:nil];
    [response invalidate];
    [self record:@"nativeQuitCancelDialog" passed:clickedCancel];
    [self record:@"nativeQuitCancelPreservesAllWindows" passed:clickedCancel &&
        _owner.window.visible && _other.window.visible && _privateWindow.window.visible &&
        _primary.alive && _secondary.alive && _otherPage.alive && _privatePage.alive];
}
- (void)tick {
    double now = NSDate.date.timeIntervalSince1970;
    if (now - _started > 100) { _results[@"timeoutStage"] = @(_stage); [self finish]; return; }
    if (now < _next) return;
    switch (_stage) {
        case 0: {
            if (_primary.loading || ![_primary.title isEqual:@"Lite Test Page"]) return;
            [self record:@"nativeMainWindow" passed:_owner.window.visible && _owner.window.windowController == _owner];
            _sidebar = Label(_owner.window, @"Browser sidebar");
            [self record:@"nativeAccessibleNavigation" passed:Label(_owner.window, @"Address") && Label(_owner.window, @"Sidebar tabs and folders") && Label(_owner.window, @"Site information and permissions")];
            [self advance:90 delay:0];
            [_primary evaluateForTesting:@"document.cookie='nativeRegular=yes;path=/';localStorage.setItem('nativeRegular','yes');window.onbeforeunload=()=>true;true"
                completion:^(id value, BOOL success) {
                    [self record:@"nativeFixtureSeeded" passed:success && [value boolValue]];
                    [self.owner openURL:@"http://127.0.0.1:18743/second?native=secondary"];
                    self.secondary = [self.owner activePage];
                    [self advance:1 delay:.2];
                }];
            break;
        }
        case 1:
            if (_secondary.loading || !_secondary.alive) return;
            [_owner selectTab:_primary.identifier];
            [_owner splitWith:_secondary.identifier vertical:YES];
            [_primary focus]; [self advance:2 delay:.3]; break;
        case 2:
            [self record:@"nativeSplitPrimaryFocused" passed:Focuses(_owner.window, _primary)];
            [_owner performCommand:@"focusSplit"]; [self advance:3 delay:.3]; break;
        case 3:
            [self record:@"nativeSplitFocusForward" passed:Focuses(_owner.window, _secondary)];
            [_owner performCommand:@"focusSplit"]; [self advance:4 delay:.3]; break;
        case 4:
            [self record:@"nativeSplitFocusBackward" passed:Focuses(_owner.window, _primary)];
            [_owner performCommand:@"toggleSidebar"]; [self advance:5 delay:.5]; break;
        case 5:
            [self record:@"nativeSidebarCollapsed" passed:_sidebar && _sidebar.window == nil];
            [_owner performCommand:@"toggleSidebar"]; [self advance:6 delay:.5]; break;
        case 6:
            [self record:@"nativeSidebarRevealed" passed:_sidebar.window == _owner.window && _sidebar.frame.size.width >= 238];
            [_owner.window makeKeyAndOrderFront:nil];
            Key(_owner.window, @"l", 37, NSEventModifierFlagCommand);
            [self advance:7 delay:.3]; break;
        case 7: {
            _panel = VisibleWindow(@"Lite Command Bar");
            NSView *search = Label(_panel, @"Search or enter address");
            NSTableView *table = (NSTableView *)Label(_panel, @"Command results");
            [self record:@"nativeCommandShortcutAndNames" passed:_panel && search && table && _panel.keyWindow];
            // Clear the current URL through the same text delegate the field uses.
            if ([search isKindOfClass:NSSearchField.class]) {
                NSSearchField *field = (NSSearchField *)search;
                field.stringValue = @"";
                [field.delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:field]];
            }
            NSInteger row = table.selectedRow;
            Key(_panel, @"\uf701", 125, 0);
            BOOL down = table.selectedRow == row + 1;
            Key(_panel, @"\uf700", 126, 0);
            [self record:@"nativeCommandArrowNavigation" passed:down && table.selectedRow == row];
            Key(_panel, @"\x1b", 53, 0);
            [self advance:8 delay:.2]; break;
        }
        case 8:
            [self record:@"nativeCommandEscape" passed:_panel && !_panel.visible && _owner.window.keyWindow];
            [_owner performCommand:@"settings"]; [self advance:9 delay:.2]; break;
        case 9:
            _panel = VisibleWindow(@"Lite — Settings");
            [self record:@"nativeSettingsAccessibleControls" passed:_panel && Label(_panel, @"Search engine") && Label(_panel, @"Memory policy") && Button(_panel, @"Clear browsing data…")];
            [_panel performClose:nil];
            [_owner performCommand:@"downloads"]; [self advance:10 delay:.2]; break;
        case 10:
            _panel = VisibleWindow(@"Lite — Downloads");
            [self record:@"nativeDownloadsAccessibleControls" passed:_panel && Label(_panel, @"Search downloads") && Label(_panel, @"Downloads") && Button(_panel, @"Pause / Resume")];
            [_panel performClose:nil]; [_owner.window makeKeyAndOrderFront:nil];
            [_owner.window performClose:nil]; [self advance:11 delay:.2]; break;
        case 11: {
            NSButton *cancel = Button(_owner.window.attachedSheet, @"Cancel");
            if (!cancel) return;
            [self record:@"nativeWindowCloseDialog" passed:Button(_owner.window.attachedSheet, @"Close All Pages") != nil];
            [cancel performClick:nil]; [self advance:12 delay:.4]; break;
        }
        case 12:
            [self record:@"nativeWindowCancelPreservesEveryPage" passed:_owner.window.visible && _primary.alive && _secondary.alive && !_owner.window.attachedSheet];
            [_owner performCommand:@"closeSplit"]; [_owner selectTab:_primary.identifier];
            [_owner performCommand:@"closeTab"]; [self advance:13 delay:.2]; break;
        case 13: {
            NSButton *stay = Button(_owner.window.attachedSheet, @"Stay");
            if (!stay) return;
            [self record:@"nativeBeforeUnloadDialog" passed:Button(_owner.window.attachedSheet, @"Leave") != nil];
            [stay performClick:nil]; [self advance:14 delay:.3]; break;
        }
        case 14: {
            [self record:@"nativeBeforeUnloadCancelPreservesTab" passed:_primary.alive && _secondary.alive && [_owner.store.profile node:_primary.identifier] != nil];
            [self advance:90 delay:0];
            [_primary evaluateForTesting:@"window.onbeforeunload=null;localStorage.getItem('nativeRegular')==='yes'" completion:^(id value, BOOL success) {
                [self record:@"nativeCanceledPageStateIntact" passed:success && [value boolValue]];
                [self.owner performCommand:@"newWindow"]; [self advance:15 delay:.2];
            }]; break;
        }
        case 15:
            _other = [self additionalWindow:NO];
            [self record:@"nativeMultipleRegularWindows" passed:_other && _other.store == _owner.store];
            [_other openURL:@"http://127.0.0.1:18743/storage"];
            _otherPage = [_other activePage];
            [_owner performCommand:@"newPrivate"]; [self advance:16 delay:.2]; break;
        case 16:
            _privateWindow = [self additionalWindow:YES];
            [self record:@"nativePrivateWindow" passed:_privateWindow && _privateWindow.store != _owner.store && [_privateWindow.window.title containsString:@"Private"]];
            [_privateWindow openURL:@"http://127.0.0.1:18743/storage"];
            _privatePage = [_privateWindow activePage]; [self advance:17 delay:.2]; break;
        case 17: {
            if (_otherPage.loading || _privatePage.loading || !_privatePage.alive) return;
            [self advance:90 delay:0];
            [_privatePage evaluateForTesting:@"(()=>{const isolated=!document.cookie.includes('nativeRegular')&&localStorage.getItem('nativeRegular')===null;document.cookie='nativePrivate=yes;path=/';localStorage.setItem('nativePrivate','yes');return isolated})()" completion:^(id value, BOOL success) {
                [self record:@"nativePrivateStorageIsolated" passed:success && [value boolValue]];
                [self.otherPage evaluateForTesting:@"document.cookie.includes('nativeRegular=yes')&&!document.cookie.includes('nativePrivate')&&localStorage.getItem('nativePrivate')===null" completion:^(id value, BOOL success) {
                    [self record:@"nativeRegularStorageSharedWithoutPrivateLeak" passed:success && [value boolValue]];
                    [self verifyQuitCancellation];
                    [self.privateWindow performCommand:@"clearData"]; [self advance:23 delay:.2];
                }];
            }]; break;
        }
        case 18:
            if (_privatePage.alive) return;
            [self record:@"nativePrivateWindowClosure" passed:!_privateWindow.window.visible && _primary.alive && _otherPage.alive];
            [_other.window performClose:nil]; [self advance:19 delay:.2]; break;
        case 19:
            if (_other.window.attachedSheet) {
                NSButton *close = Button(_other.window.attachedSheet, @"Close All Pages");
                if (close) { [close performClick:nil]; [self advance:19 delay:.2]; }
                return;
            }
            if (_otherPage.alive) return;
            [self record:@"nativeRegularWindowClosure" passed:!_other.window.visible && _primary.alive && _secondary.alive];
            [_owner.window makeKeyAndOrderFront:nil]; [_owner selectTab:_primary.identifier];
            [_owner performCommand:@"closeTab"]; [self advance:20 delay:.2]; break;
        case 20:
            if (_primary.alive) return;
            [self record:@"nativeTabClosure" passed:[_owner.store.profile node:_primary.identifier] == nil && _secondary.alive];
            [_owner openURL:@"http://127.0.0.1:18743/auth-basic"];
            _authPage = [_owner activePage]; [self advance:21 delay:.2]; break;
        case 21: {
            NSWindow *sheet = _owner.window.attachedSheet;
            NSTextField *username = (NSTextField *)Label(sheet, @"Authentication username");
            NSSecureTextField *password = nil;
            for (NSView *view in Views(sheet.contentView)) if ([view isKindOfClass:NSSecureTextField.class]) password = (NSSecureTextField *)view;
            NSButton *signIn = Button(sheet, @"Sign In");
            if (!username || !password || !signIn) return;
            [self record:@"nativeAuthenticationDialog" passed:Button(sheet, @"Cancel") != nil];
            username.stringValue = @"synthetic-http"; password.stringValue = @"synthetic-only-password";
            [signIn performClick:nil]; [self advance:22 delay:.2]; break;
        }
        case 22:
            if (_authPage.loading || ![_authPage.title isEqual:@"Authenticated basic"]) return;
            [self record:@"nativeAuthenticationSucceeded" passed:!_owner.window.attachedSheet];
            [self finish]; break;
        case 23: {
            NSWindow *sheet = _privateWindow.window.attachedSheet;
            NSButton *cancel = Button(sheet, @"Cancel");
            if (!cancel) return;
            [self record:@"nativePrivateClearConfirmation" passed:Button(sheet, @"Clear Private Data") != nil];
            [cancel performClick:nil]; [self advance:24 delay:.2]; break;
        }
        case 24:
            [self record:@"nativePrivateClearCancelPreservesSession" passed:_privateWindow.window.visible &&
                _privatePage.alive && _primary.alive && _otherPage.alive && !_privateWindow.window.attachedSheet];
            [_privateWindow performCommand:@"clearData"]; [self advance:25 delay:.2]; break;
        case 25: {
            NSButton *clear = Button(_privateWindow.window.attachedSheet, @"Clear Private Data");
            if (!clear) return;
            [clear performClick:nil]; [self advance:26 delay:.2]; break;
        }
        case 26: {
            if (_privatePage.alive || _privateWindow.window.visible) return;
            [self record:@"nativePrivateClearClosesOldContext" passed:!_privatePage.alive && _primary.alive && _otherPage.alive];
            LTWindow *fresh = [self additionalWindow:YES];
            [self record:@"nativePrivateClearFreshWindow" passed:fresh && fresh != _privateWindow && fresh.store != _privateWindow.store];
            _privateWindow = fresh;
            [_privateWindow openURL:@"http://127.0.0.1:18743/storage"];
            _privatePage = [_privateWindow activePage]; [self advance:27 delay:.2]; break;
        }
        case 27: {
            if (_privatePage.loading || !_privatePage.alive) return;
            [self advance:90 delay:0];
            [_privatePage evaluateForTesting:@"!document.cookie.includes('nativePrivate')&&!document.cookie.includes('nativeRegular')&&localStorage.getItem('nativePrivate')===null&&localStorage.getItem('nativeRegular')===null" completion:^(id value, BOOL success) {
                [self record:@"nativePrivateClearStorageEmpty" passed:success && [value boolValue]];
                [self.otherPage evaluateForTesting:@"document.cookie.includes('nativeRegular=yes')&&localStorage.getItem('nativeRegular')==='yes'" completion:^(id value, BOOL success) {
                    [self record:@"nativePrivateClearPreservesRegularData" passed:success && [value boolValue]];
                    [self.privateWindow.window performClose:nil]; [self advance:18 delay:.2];
                }];
            }]; break;
        }
        default: break;
    }
}
- (void)finish {
    [_timer invalidate]; _timer = nil;
    _results[@"elapsedSeconds"] = @(NSDate.date.timeIntervalSince1970 - _started);
    if (_results[@"timeoutStage"]) {
        NSMutableArray *buttons = [NSMutableArray new];
        for (NSView *view in Views(_owner.window.attachedSheet.contentView))
            if ([view isKindOfClass:NSButton.class]) [buttons addObject:((NSButton *)view).title ?: @""];
        _results[@"timeoutDetails"] = @{@"ownerVisible": @(_owner.window.visible), @"otherVisible": @(_other.window.visible),
            @"otherPageAlive": @(_otherPage.alive), @"otherSheet": _other.window.attachedSheet.title ?: @"",
            @"ownerSheetButtons": buttons, @"authenticationTitle": _authPage.title ?: @"", @"authenticationError": _authPage.errorText ?: @""};
    }
    _results[@"notCovered"] = @[@"VoiceOver spoken output", @"Full Keyboard Access system mode", @"physical drag and drop", @"contrast and scaling", @"macOS capture authorization", @"signed upgrade recovery"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:_results options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:_output options:NSDataWritingAtomic error:nil];
    void (^completion)(void) = _finished; _finished = nil;
    if (completion) completion();
    runningNative = nil;
}
@end
void LTRunNativeSmoke(LTWindow *window, NSString *output, void (^finished)(void)) {
    runningNative = [LTNativeSmoke new];
    runningNative.owner = window; runningNative.output = output; runningNative.finished = finished;
    [runningNative begin];
}
