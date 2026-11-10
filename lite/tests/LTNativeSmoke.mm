#import "LTNativeSmoke.h"
#import "LTWindowState.h"
#import "../macos/LTTheme.h"
#import "../macos/LTWindow.h"
#import "../model/LTExtensions.h"

// Exercise the same native command paths as the UI without exposing test flags
// in the browser engine or changing lifecycle state to manufacture a pass.
@interface LTWindow (NativeVerification)
- (LTPage *)activePage;
- (void)selectTab:(NSString *)identifier;
- (void)splitWith:(NSString *)identifier vertical:(BOOL)vertical;
- (NSPopover *)showExtensionPopup:(LTExtension *)extension;
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
static NSArray *SidebarRows(NSOutlineView *tree) {
    NSMutableArray *rows = [NSMutableArray new];
    for (NSInteger row = 0; row < tree.numberOfRows; row++) {
        id item = [tree itemAtRow:row];
        [rows addObject:[item isKindOfClass:LTNode.class] ? ((LTNode *)item).identifier : item];
    }
    return rows;
}
static void AppendExpected(NSMutableArray *rows, NSArray<LTNode *> *nodes, NSDictionary *children) {
    for (LTNode *node in nodes) {
        [rows addObject:node.identifier];
        if (node.expanded && children[node.identifier]) AppendExpected(rows, children[node.identifier], children);
    }
}
static NSArray *ExpectedRows(LTProfile *profile, NSString *space) {
    NSDictionary *children = [profile childrenInSpace:space];
    NSArray *top = children[@""] ?: @[];
    NSPredicate *temporary = [NSPredicate predicateWithBlock:^BOOL(LTNode *node, id unused) { return [node.kind isEqual:@"temporary"]; }];
    NSMutableArray *rows = [NSMutableArray arrayWithObject:@"Pinned"];
    AppendExpected(rows, [top filteredArrayUsingPredicate:[NSCompoundPredicate notPredicateWithSubpredicate:temporary]], children);
    [rows addObject:@"Today"];
    AppendExpected(rows, [top filteredArrayUsingPredicate:temporary], children);
    return rows;
}
// Every label in one Command Bar row, joined.
static NSString *RowText(NSTableView *table, NSInteger row) {
    if (![table isKindOfClass:NSTableView.class] || row < 0 || row >= table.numberOfRows) return @"";
    NSMutableArray *text = [NSMutableArray new];
    for (NSView *view in Views([table viewAtColumn:0 row:row makeIfNecessary:YES]))
        if ([view isKindOfClass:NSTextField.class]) [text addObject:((NSTextField *)view).stringValue];
    return [text componentsJoinedByString:@" "];
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
static BOOL FullScreen(NSWindow *window) {
    return (window.styleMask & NSWindowStyleMaskFullScreen) != 0;
}
static BOOL TrafficLightsHidden(NSWindow *window) {
    for (NSNumber *kind in @[ @(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton) ])
        if (![window standardWindowButton:(NSWindowButton)kind.unsignedIntegerValue].hidden) return NO;
    return YES;
}
static BOOL TrafficLightsShown(NSWindow *window) {
    for (NSNumber *kind in @[ @(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton) ])
        if ([window standardWindowButton:(NSWindowButton)kind.unsignedIntegerValue].hidden) return NO;
    return YES;
}
// The page cards' outer edge, in content view coordinates, and whether they are all flush.
static NSRect CardBounds(NSWindow *window, BOOL *flush) {
    NSView *root = window.contentView;
    [root layoutSubtreeIfNeeded];
    NSRect bounds = NSZeroRect;
    *flush = YES;
    for (NSView *view in Views(root)) {
        if (![view isKindOfClass:LTCard.class] || view.hiddenOrHasHiddenAncestor) continue;
        bounds = NSUnionRect(bounds, [root convertRect:view.bounds fromView:view]);
        *flush = *flush && ((LTCard *)view).flush;
    }
    return bounds;
}
static BOOL SameRect(NSRect a, NSRect b) {
    return fabs(NSMinX(a) - NSMinX(b)) < .5 && fabs(NSMinY(a) - NSMinY(b)) < .5 &&
           fabs(NSWidth(a) - NSWidth(b)) < .5 && fabs(NSHeight(a) - NSHeight(b)) < .5;
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
@property NSPopover *popover;
@property NSUInteger browsersWithPopover;
@property NSTimer *timer;
@property NSMutableDictionary *results;
@property NSString *output;
@property(copy) void (^finished)(void);
@property NSInteger stage;
@property NSTimeInterval started;
@property NSTimeInterval next;
@property NSArray<LTProfileChange> *sidebarChanges;
@property NSUInteger sidebarStep;
@property NSUInteger sidebarBaseline;
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
    [_owner openURL:@"http://127.0.0.1:18743/?native=primary" then:^{ self.primary = [self.owner activePage]; }];
    __weak typeof(self) weak = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:.1 repeats:YES block:^(NSTimer *timer) {
        [weak tick];
        typeof(self) strong = weak;
        if (strong) LTSampleWindowState(strong.results, strong.owner.window);
    }];
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
            NSWindow *prompt = _owner.window.attachedSheet;
            if (!_results[@"nativeCrashPromptDisclosure"]) {
                NSMutableString *text = [NSMutableString new];
                for (NSView *view in Views(prompt.contentView))
                    if ([view isKindOfClass:NSTextField.class]) [text appendString:((NSTextField *)view).stringValue];
                [self record:@"nativeCrashPromptDisclosure" passed:[text containsString:@"Sentry"] && [text containsString:@"text you entered"] && [text containsString:@"deletes"]];
                NSButton *decline = Button(prompt, @"Don't Send");
                [self record:@"nativeCrashPromptDefaultsToDecline" passed:decline && [decline.keyEquivalent isEqual:@"\r"]];
                [Button(prompt, @"Send") performClick:nil];
                [self advance:0 delay:.5];
                return;
            }
            [self record:@"nativeMainWindow" passed:_owner.window.visible && _owner.window.windowController == _owner];
            _sidebar = Label(_owner.window, @"Browser sidebar");
            [self record:@"nativeAccessibleNavigation" passed:Label(_owner.window, @"Address") && Label(_owner.window, @"Sidebar tabs and folders") && Label(_owner.window, @"Site information and permissions")];
            [self advance:90 delay:0];
            [_primary evaluateForTesting:@"document.cookie='nativeRegular=yes;path=/';localStorage.setItem('nativeRegular','yes');window.onbeforeunload=()=>true;true"
                completion:^(id value, BOOL success) {
                    [self record:@"nativeFixtureSeeded" passed:success && [value boolValue]];
                    [self.owner openURL:@"http://127.0.0.1:18743/second?native=secondary" then:^{
                        self.secondary = [self.owner activePage];
                        [self advance:70 delay:.2];
                    }];
                }];
            break;
        }
        case 70:
            [self advance:90 delay:0];
            [self checkSidebar]; break;
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
            [self record:@"nativeSidebarCollapsed" passed:_sidebar && _sidebar.window == nil && TrafficLightsHidden(_owner.window)];
            [_owner.window makeKeyAndOrderFront:nil];
            [_owner performCommand:@"fullScreen"]; [self advance:40 delay:.2]; break;
        case 40:
            if (!FullScreen(_owner.window)) {
                if (now - _next < 6) return;
                [self record:@"nativeFullScreenChrome" passed:NO];
                [_owner performCommand:@"toggleSidebar"]; [self advance:6 delay:.5]; break;
            }
            [self advance:41 delay:1.5]; break;
        case 41: {
            // A collapsed sidebar must not take the traffic lights away from the full-screen titlebar.
            BOOL flush = NO;
            NSRect cards = CardBounds(_owner.window, &flush);
            [self record:@"nativeFullScreenChrome" passed:FullScreen(_owner.window) && flush &&
                SameRect(cards, _owner.window.contentView.bounds) && TrafficLightsShown(_owner.window)];
            [_owner performCommand:@"fullScreen"]; [self advance:42 delay:.2]; break;
        }
        case 42:
            if (FullScreen(_owner.window) && now - _next < 6) return;
            [self advance:43 delay:1.5]; break;
        case 43: {
            BOOL flush = YES;
            NSRect cards = CardBounds(_owner.window, &flush);
            [self record:@"nativeFullScreenRestored" passed:!FullScreen(_owner.window) && !flush &&
                SameRect(cards, NSInsetRect(_owner.window.contentView.bounds, 8, 8)) &&
                (_sidebar.window || TrafficLightsHidden(_owner.window))];
            [_owner performCommand:@"toggleSidebar"]; [self advance:6 delay:.5]; break;
        }
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
            // The start of a visited host leads the results ahead of web search, from the real store.
            BOOL history = NO;
            if ([search isKindOfClass:NSSearchField.class] && table.numberOfRows > 1) {
                NSSearchField *field = (NSSearchField *)search;
                field.stringValue = @"127";
                [field.delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:field]];
                NSMutableArray *first = [NSMutableArray new], *second = [NSMutableArray new];
                for (NSInteger r = 0; r < 2; r++)
                    for (NSView *view in Views([table viewAtColumn:0 row:r makeIfNecessary:YES]))
                        if ([view isKindOfClass:NSTextField.class]) [r ? second : first addObject:((NSTextField *)view).stringValue];
                history = table.selectedRow == 0 && [[first componentsJoinedByString:@" "] containsString:@"http://127.0.0.1:18743/"] &&
                    [[second componentsJoinedByString:@" "] containsString:@"Search for"];
            }
            [self record:@"nativeCommandHistoryPrefix" passed:history];
            // The profile's search engine is the loopback fixture, with suggestions on. Its answer
            // arrives after typing pauses; "127" above was replaced before that and is never sent.
            if ([search isKindOfClass:NSSearchField.class]) {
                NSSearchField *field = (NSSearchField *)search;
                field.stringValue = @"lite fixt";
                [field.delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:field]];
            }
            [self advance:71 delay:.8]; break;
        }
        case 71: {
            NSTableView *table = (NSTableView *)Label(_panel, @"Command results");
            NSString *first = RowText(table, 0), *second = RowText(table, 1);
            [self record:@"nativeCommandSearchSuggestions" passed:table.selectedRow == 0 && [first containsString:@"Search for “lite fixt”"] &&
                [second containsString:@"lite fixture suggestion"] && [second containsString:@"Fixture Search suggestion"]];
            Key(_panel, @"\x1b", 53, 0);
            [self advance:8 delay:.2]; break;
        }
        case 8:
            [self record:@"nativeCommandEscape" passed:_panel && !_panel.visible && _owner.window.keyWindow];
            [_owner performCommand:@"settings"]; [self advance:9 delay:.2]; break;
        case 9: {
            _panel = VisibleWindow(@"Lite — Settings");
            [self record:@"nativeSettingsAccessibleControls" passed:_panel && Label(_panel, @"Search engine") && Label(_panel, @"Memory policy") && Button(_panel, @"Clear browsing data…")];
            NSPopUpButton *engines = (NSPopUpButton *)Label(_panel, @"Search engine");
            NSButton *remove = (NSButton *)Label(_panel, @"Remove search engine");
            [self record:@"nativeSettingsSearchEngines" passed:[engines isKindOfClass:NSPopUpButton.class] && [engines.itemTitles containsObject:@"Kagi"] &&
                [engines.titleOfSelectedItem isEqual:@"Fixture Search"] && Label(_panel, @"Add search engine") && remove.enabled &&
                Button(_panel, @"Show search suggestions in the Command Bar").state == NSControlStateValueOn];
            [_panel performClose:nil];
            [_owner performCommand:@"downloads"]; [self advance:10 delay:.2]; break;
        }
        case 10:
            _panel = VisibleWindow(@"Lite — Downloads");
            [self record:@"nativeDownloadsAccessibleControls" passed:_panel && Label(_panel, @"Search downloads") && Label(_panel, @"Downloads") && Button(_panel, @"Pause / Resume")];
            [_panel performClose:nil];
            [_owner performCommand:@"extensions"]; [self advance:60 delay:.2]; break;
        case 60: {
            // The runner registers the fixture extension in this profile's Extensions.json.
            _panel = VisibleWindow(@"Extensions");
            NSTableView *table = (NSTableView *)Label(_panel, @"Extensions");
            NSView *button = Label(_owner.window, @"Extensions");
            [self record:@"nativeExtensionsPanel" passed:_panel && Button(_panel, @"Add Folder…") &&
                Button(_panel, @"Add from Chrome Web Store…") && [table isKindOfClass:NSTableView.class] &&
                table.numberOfRows == 1 && button && !button.hidden];
            [_panel performClose:nil];
            _popover = _owner.extensions.launched.count ? [_owner showExtensionPopup:_owner.extensions.launched.firstObject] : nil;
            [self advance:61 delay:.2]; break;
        }
        case 61:
            if (!NSEqualSizes(_popover.contentSize, NSMakeSize(240, 120)) && now - _next < 8) return;
            [self record:@"nativeExtensionPopup" passed:_popover.shown && NSEqualSizes(_popover.contentSize, NSMakeSize(240, 120))];
            _browsersWithPopover = LTLivingBrowserCount();
            [_popover close]; [self advance:62 delay:1]; break;
        case 62:
            [self record:@"nativeExtensionPopupClosed" passed:_popover && !_popover.shown && LTLivingBrowserCount() + 1 == _browsersWithPopover];
            _popover = nil;
            [_owner.window makeKeyAndOrderFront:nil];
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
        case 15: {
            _other = [self additionalWindow:NO];
            [self record:@"nativeMultipleRegularWindows" passed:_other && _other.store == _owner.store];
            [self advance:90 delay:0];
            [_other openURL:@"http://127.0.0.1:18743/storage" then:^{
                self.otherPage = [self.other activePage];
                [self.owner performCommand:@"newPrivate"]; [self advance:16 delay:.2];
            }]; break;
        }
        case 16: {
            _privateWindow = [self additionalWindow:YES];
            [self record:@"nativePrivateWindow" passed:_privateWindow && _privateWindow.store != _owner.store && [_privateWindow.window.title containsString:@"Private"]];
            [self record:@"nativeExtensionsHiddenInPrivate" passed:!_privateWindow.extensions && Label(_privateWindow.window, @"Extensions").hidden];
            NSDictionary *privateSettings = _privateWindow.store.profile.settings;
            [self record:@"nativePrivateSearchEngine" passed:[LTSelectedSearchEngine(privateSettings)[@"name"] isEqual:@"Fixture Search"] &&
                !privateSettings[@"searchSuggestions"]];
            [self advance:90 delay:0];
            [_privateWindow openURL:@"http://127.0.0.1:18743/storage" then:^{
                self.privatePage = [self.privateWindow activePage];
                [self.privateWindow performCommand:@"newTab"]; [self advance:72 delay:.3];
            }]; break;
        }
        case 72: {
            // Text typed in a private window is searched only when the user asks; the fixture's
            // request log, read by test_native.py, must not contain it.
            _panel = VisibleWindow(@"Lite Command Bar");
            NSSearchField *field = (NSSearchField *)Label(_panel, @"Search or enter address");
            if ([field isKindOfClass:NSSearchField.class]) {
                field.stringValue = @"lite private";
                [field.delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:field]];
            }
            [self advance:73 delay:.6]; break;
        }
        case 73: {
            NSTableView *table = (NSTableView *)Label(_panel, @"Command results");
            BOOL suggested = NO;
            for (NSInteger row = 0; row < table.numberOfRows; row++) suggested = suggested || [RowText(table, row) containsString:@"suggestion"];
            [self record:@"nativePrivateCommandWithoutSuggestions" passed:_panel && [RowText(table, 0) containsString:@"Search for “lite private”"] && !suggested];
            Key(_panel, @"\x1b", 53, 0);
            [self advance:17 delay:.2]; break;
        }
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
        case 20: {
            if (_primary.alive) return;
            [self record:@"nativeTabClosure" passed:[_owner.store.profile node:_primary.identifier] == nil && _secondary.alive];
            LTProfile *profile = _owner.store.profile;
            [self record:@"nativeClosedTabRecorded" passed:[[profile latestClosed:@"tab"][@"node"][@"id"] isEqual:_primary.identifier]];
            [self record:@"nativeClosedWindowRecorded" passed:[profile latestClosed:@"window"] != nil];
            [_owner performCommand:@"reopenTab"]; [self advance:80 delay:.2]; break;
        }
        case 80: {
            LTNode *reopened = [_owner.store.profile node:_primary.identifier];
            if (!reopened) return;
            [self record:@"nativeReopenClosedTab" passed:[reopened.kind isEqual:@"temporary"] &&
                ![[_owner.store.profile latestClosed:@"tab"][@"node"][@"id"] isEqual:_primary.identifier]];
            [_owner performCommand:@"reopenWindow"]; [self advance:81 delay:.2]; break;
        }
        case 81: {
            LTWindow *reopened = [self additionalWindow:NO];
            if (!reopened) return;
            [self record:@"nativeReopenClosedWindow" passed:reopened != _other && reopened.store == _owner.store &&
                ![_owner.store.profile latestClosed:@"window"]];
            _other = reopened;
            [_other.window performClose:nil]; [self advance:82 delay:.2]; break;
        }
        case 82: {
            if (_other.window.attachedSheet) {
                NSButton *close = Button(_other.window.attachedSheet, @"Close All Pages");
                if (close) { [close performClick:nil]; [self advance:82 delay:.2]; }
                return;
            }
            if (_other.window.visible) return;
            [_owner.window makeKeyAndOrderFront:nil];
            [self advance:90 delay:0];
            [_owner openURL:@"http://127.0.0.1:18743/auth-basic" then:^{
                self.authPage = [self.owner activePage]; [self advance:21 delay:.2];
            }]; break;
        }
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
            [self advance:90 delay:0];
            [_privateWindow openURL:@"http://127.0.0.1:18743/storage" then:^{
                self.privatePage = [self.privateWindow activePage]; [self advance:27 delay:.2];
            }]; break;
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
// Each save below reaches the outline as no change, a row-level change or a full reload. Afterwards
// the outline's real rows must match the model exactly, in order.
- (void)checkSidebar {
    LTStore *store = _owner.store;
    NSString *space = store.profile.activeSpaceID;
    NSUInteger baseline = store.profile.nodes.count;
    NSString *first = @"sidebar-pin", *second = @"sidebar-temporary", *folder = @"sidebar-folder", *child = @"sidebar-child", *late = @"sidebar-late";
    LTNode *(^add)(LTProfile *, NSString *, NSString *, NSString *) = ^LTNode *(LTProfile *p, NSString *identifier, NSString *kind, NSString *parent) {
        LTNode *node = [p addNode:kind title:identifier url:[kind isEqual:@"folder"] ? @"" : @"https://example.invalid/" space:space parent:parent];
        node.identifier = identifier;
        return node;
    };
    NSArray<LTProfileChange> *changes = @[
        ^(LTProfile *p) { add(p, second, @"temporary", @""); },
        ^(LTProfile *p) { add(p, first, @"pinned", @""); },
        ^(LTProfile *p) { [p node:first].customTitle = @"Renamed"; },
        ^(LTProfile *p) { LTNode *n = [p node:second]; n.kind = @"pinned"; n.pinnedURL = n.url; },
        ^(LTProfile *p) { [p moveNode:second space:space parent:@"" index:0 error:nil]; },
        ^(LTProfile *p) { add(p, folder, @"folder", @""); add(p, child, @"pinned", folder); },
        ^(LTProfile *p) { [p node:folder].expanded = YES; },
        ^(LTProfile *p) { add(p, late, @"pinned", folder); },
        ^(LTProfile *p) { [p removeNode:child]; },
        ^(LTProfile *p) { [p node:folder].expanded = NO; },
        ^(LTProfile *p) { [p moveNode:first space:space parent:folder index:0 error:nil]; },
        ^(LTProfile *p) { [p removeNode:first]; },
        ^(LTProfile *p) { [p removeNode:late]; [p node:folder].expanded = YES; },
        ^(LTProfile *p) { [p removeNode:folder]; },
        ^(LTProfile *p) { [p removeNode:second]; },
    ];
    _sidebarChanges = changes;
    _sidebarStep = 0;
    _sidebarBaseline = baseline;
    [self nextSidebarChange];
}
- (void)nextSidebarChange {
    LTStore *store = _owner.store;
    if (_sidebarStep == _sidebarChanges.count) {
        [self record:@"nativeSidebarFollowsSaves" passed:!_results[@"nativeSidebarFirstMismatch"] && store.profile.nodes.count == _sidebarBaseline];
        [self advance:1 delay:.2];
        return;
    }
    NSOutlineView *tree = (NSOutlineView *)Label(_owner.window, @"Sidebar tabs and folders");
    NSUInteger step = _sidebarStep++;
    [store commit:_sidebarChanges[step] completion:^(NSError *error) {
        NSArray *rows = SidebarRows(tree), *expected = ExpectedRows(store.profile, store.profile.activeSpaceID);
        if ((error || ![rows isEqual:expected]) && !self.results[@"nativeSidebarFirstMismatch"])
            self.results[@"nativeSidebarFirstMismatch"] = @{@"step": @(step), @"error": error.localizedDescription ?: @"", @"rows": rows, @"expected": expected};
        [self nextSidebarChange];
    }];
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

// Measures saves in the running app: real windows observe the store, and a 2 ms timer on the main
// run loop shows every period the main thread could not have drawn or handled input.
@interface LTWindow (SaveProbe)
- (void)refresh;
@end
@interface LTSaveProbe : NSObject
@end
@implementation LTSaveProbe {
    LTWindow *_window;
    NSString *_output;
    NSMutableArray<NSDictionary *> *_kinds;
    NSMutableArray *_gaps, *_calls, *_durable;
    NSArray<NSString *> *_kindNames;
    NSTimer *_ticks;
    double _lastTick;
    int _kind, _saves, _finished;
}
static const int ProbeSavesPerKind = 12;
static double ProbeNow(void) { return NSProcessInfo.processInfo.systemUptime * 1000; }
- (instancetype)initWithWindow:(LTWindow *)window output:(NSString *)output {
    if ((self = [super init])) {
        _window = window;
        _output = output;
        _kinds = [NSMutableArray new];
        _kindNames = @[@"quiet", @"organization", @"structure"];
        _ticks = [NSTimer timerWithTimeInterval:.002 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
        [NSRunLoop.currentRunLoop addTimer:_ticks forMode:NSRunLoopCommonModes];
        [self startKind];
    }
    return self;
}
- (void)tick:(NSTimer *)timer {
    double now = ProbeNow();
    if (_lastTick > 0) [_gaps addObject:@(now - _lastTick)];
    _lastTick = now;
}
- (void)startKind {
    _gaps = [NSMutableArray new]; _calls = [NSMutableArray new]; _durable = [NSMutableArray new];
    _saves = _finished = 0;
    [self performSelector:@selector(save) withObject:nil afterDelay:.3];
}
- (void)save {
    BOOL quiet = _kind == 0, structure = _kind == 2;
    int index = _saves++;
    NSString *title = [NSString stringWithFormat:@"Probe %d", index];
    NSString *spaceID = _window.store.profile.activeSpaceID;
    double start = ProbeNow();
    [_window.store commit:^(LTProfile *p) {
        if (!structure) p.nodes.lastObject.customTitle = title;
        else if ([p.nodes.lastObject.kind isEqual:@"temporary"]) [p removeNode:p.nodes.lastObject.identifier];
        else [p addNode:@"temporary" title:title url:@"https://example.invalid/" space:spaceID parent:@""];
    }
                 quietFor:quiet ? _window : nil
               completion:^(NSError *error) {
        [self->_durable addObject:@(ProbeNow() - start)];
        if (++self->_finished == ProbeSavesPerKind) [self finishKind];
    }];
    [_calls addObject:@(ProbeNow() - start)];
    if (_saves < ProbeSavesPerKind) [self performSelector:@selector(save) withObject:nil afterDelay:.3];
}
- (void)finishKind {
    NSArray *sorted = [_gaps sortedArrayUsingSelector:@selector(compare:)], *calls = [_calls sortedArrayUsingSelector:@selector(compare:)];
    NSArray *durable = [_durable sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger over = 0;
    for (NSNumber *gap in sorted) if (gap.doubleValue > 1000.0 / 60) over++;
    [_kinds addObject:@{@"kind": _kindNames[_kind], @"saves": @(ProbeSavesPerKind), @"gapsOverBudget": @(over), @"ticks": @(sorted.count),
                        @"largestGapMs": sorted.lastObject ?: @0, @"mainCallMedianMs": calls[calls.count / 2],
                        @"savedDurablyMedianMs": durable[durable.count / 2]}];
    if (++_kind < (int)_kindNames.count) { [self startKind]; return; }
    [_ticks invalidate];
    NSMutableArray *refreshes = [NSMutableArray new];
    for (int i = 0; i < 5; i++) {
        double start = ProbeNow();
        [_window refresh];
        [refreshes addObject:@(ProbeNow() - start)];
    }
    [refreshes sortUsingSelector:@selector(compare:)];
    NSDictionary *result = @{@"nodes": @(_window.store.profile.nodes.count), @"kinds": _kinds, @"windowRefreshMedianMs": refreshes[2]};
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil] writeToFile:_output atomically:YES];
}
@end
void LTRunSaveProbe(LTWindow *window, NSString *output) {
    static LTSaveProbe *probe;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        probe = [[LTSaveProbe alloc] initWithWindow:window output:output];
    });
}
