#import "LTWindow.h"
#import "../migration/LTImporter.h"
#import "../model/LTGitHub.h"
#import "LTCommandPanel.h"
#import "LTFaviconCache.h"
#import "LTLibraryPanel.h"
#import "LTPasswords.h"
#import "LTSidebar.h"
#import "LTUI.h"
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface LTWindowSurface : NSView
@property (nonatomic, copy) void (^pointerChanged)(NSPoint);
@end
@implementation LTWindowSurface {
    NSTrackingArea *_tracking;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking)
        [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingInVisibleRect | NSTrackingMouseEnteredAndExited |
                     NSTrackingActiveAlways
               owner:self
            userInfo:nil];
    [self addTrackingArea:_tracking];
}
- (void)mouseEntered:(NSEvent *)event {
    self.pointerChanged([self convertPoint:event.locationInWindow fromView:nil]);
}
- (void)mouseExited:(NSEvent *)event {
    self.pointerChanged(NSMakePoint(-1, -1));
}
@end

@interface LTWindowDragArea : NSView
@end
@implementation LTWindowDragArea
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}
- (void)mouseDown:(NSEvent *)event {
    [self.window performWindowDragWithEvent:event];
}
@end

@interface LTContentSplit : NSSplitView
@property (nonatomic, copy) void (^dropped)(NSString *);
@end
@implementation LTContentSplit
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return NSDragOperationCopy;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSString *s = [sender.draggingPasteboard stringForType:@"app.lite.sidebar-item"];
    if (s && self.dropped) {
        self.dropped(s);
        return YES;
    }
    return NO;
}
@end
@interface LTWindow () <NSWindowDelegate, NSSplitViewDelegate, NSSearchFieldDelegate>
@end
@implementation LTWindow {
    LTBrowserContext *_context;
    NSMutableDictionary<NSString *, LTPage *> *_pageMap;
    NSString *_spaceID;
    NSString *_activeID;
    NSString *_secondaryID;
    NSString *_focusedID;
    NSSplitView *_layout;
    LTContentSplit *_webSplit;
    LTSidebar *_sidebar;
    NSView *_sidebarHost;
    BOOL _sidebarCollapsed, _sidebarRevealed, _updatingSidebar;
    CGFloat _sidebarWidth;
    NSUInteger _sidebarAnimationGeneration;
    NSTimer *_sidebarHideTimer;
    id _mouseMonitor;
    NSView *_content;
    NSView *_landing;
    NSView *_parking;
    NSButton *_address, *_back, *_forward, *_reload, *_media;
    NSTextField *_error;
    NSSearchField *_find;
    NSStackView *_findBar;
    LTCommandPanel *_command;
    LTLibraryPanel *_library;
    LTFaviconCache *_icons;
    LTPasswords *_passwords;
    NSMutableArray<NSDictionary *> *_closed;
    NSMutableDictionary *_downloadRows;
    NSMutableDictionary *_visitKeys;
    BOOL _metadataChange, _closingWindow, _restoring, _splitPending, _addressMode;
    BOOL _verticalSplit;
    double _splitRatio;
    NSTimer *_saveTimer;
    NSMutableSet<NSString *> *_pendingClose;
}
- (instancetype)initWithStore:(LTStore *)store
                         mini:(BOOL)mini
                      restore:(NSDictionary *)state
                        icons:(LTFaviconCache *)icons
                       logins:(LTLoginStore *)logins {
    NSWindow *w = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, mini ? 760 : 1260, mini ? 580 : 820)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                            NSWindowStyleMaskFullSizeContentView
                    backing:NSBackingStoreBuffered
                      defer:NO];
    w.title = mini ? @"Mini Lite" : store.privateMode ? @"Lite — Private" : @"Lite";
    w.titleVisibility = NSWindowTitleHidden;
    w.titlebarAppearsTransparent = YES;
    w.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    w.acceptsMouseMovedEvents = YES;
    w.minSize = NSMakeSize(mini ? 500 : 780, 420);
    w.releasedWhenClosed = NO;
    w.backgroundColor = NSColor.windowBackgroundColor;
    w.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    if ((self = [super initWithWindow:w])) {
        _store = store;
        _icons = store.privateMode ? nil : icons;
        _passwords =
            !store.privateMode && logins ? [[LTPasswords alloc] initWithStore:logins] : nil;
        _mini = mini;
        _context = [[LTBrowserContext alloc] initPrivate:store.privateMode];
        _pageMap = [NSMutableDictionary new];
        _closed = [NSMutableArray new];
        _downloadRows = [NSMutableDictionary new];
        _splitRatio = 0.5;
        _verticalSplit = YES;
        _spaceID =
            [store.profile space:state[@"space"]] ? state[@"space"] : store.profile.activeSpaceID;
        _activeID = state[@"active"] ?: [store.profile space:_spaceID].selectedID;
        _secondaryID = state[@"secondary"] ?: @"";
        _verticalSplit = state[@"vertical"] ? [state[@"vertical"] boolValue] : YES;
        _splitRatio = state[@"ratio"] ? [state[@"ratio"] doubleValue] : 0.5;
        _sidebarCollapsed = mini || [state[@"sidebarCollapsed"] boolValue];
        _sidebarWidth =
            state[@"sidebarWidth"] ? MIN(340, MAX(238, [state[@"sidebarWidth"] doubleValue])) : 238;
        w.delegate = self;
        _visitKeys = [NSMutableDictionary new];
        _pendingClose = [NSMutableSet new];
        [self buildUI];
        [w center];
        if ([state[@"frame"] isKindOfClass:NSString.class])
            [w setFrame:NSRectFromString(state[@"frame"]) display:NO];
        __weak typeof(self) weak = self;
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(storeChanged:)
                                                   name:LTStoreChanged
                                                 object:store];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(pageFocused:)
                                                   name:@"LTPageFocused"
                                                 object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storeChanged:)
            name:@"LTGitHubChanged" object:nil];
        if (_icons)
            [NSNotificationCenter.defaultCenter addObserver:self
                                                   selector:@selector(faviconChanged:)
                                                       name:LTFaviconChanged
                                                     object:_icons];
        _library = [[LTLibraryPanel alloc] initWithStore:store];
        _library.openURL = ^(NSString *url) {
          [weak openURL:url];
        };
        _library.command = ^(NSString *c) {
          [weak performCommand:c];
        };
        _library.downloadAction = ^(NSDictionary *d, NSString *a) {
          LTWindow *owner = weak;
          if (!owner)
              return;
          if ([a isEqual:@"forget"])
              [owner->_downloadRows removeObjectForKey:d[@"id"]];
          else
              [owner->_pageMap[d[@"page"]] downloadAction:a identifier:[d[@"id"] integerValue]];
        };
        [w makeKeyAndOrderFront:nil];
        [w.contentView layoutSubtreeIfNeeded];
        [self refresh];
        [NSApp activateIgnoringOtherApps:YES];
    }
    return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_saveTimer invalidate];
    [_sidebarHideTimer invalidate];
    if (_mouseMonitor)
        [NSEvent removeMonitor:_mouseMonitor];
}
- (NSArray<LTPage *> *)pages {
    return _pageMap.allValues;
}
- (void)buildUI {
    LTWindowSurface *root = [LTWindowSurface new];
    root.wantsLayer = YES;
    root.layer.masksToBounds = YES;
    self.window.contentView = root;
    _back = LTButton(@"chevron.left", @"Back", self, @selector(back:));
    _forward = LTButton(@"chevron.right", @"Forward", self, @selector(forward:));
    _reload = LTButton(@"arrow.clockwise", @"Reload", self, @selector(reload:));
    _address = [NSButton buttonWithTitle:@"Search or enter URL"
                                  target:self
                                  action:@selector(address:)];
    _address.bordered = NO;
    _address.font = [NSFont systemFontOfSize:12];
    _address.contentTintColor = NSColor.secondaryLabelColor;
    _address.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _address.alignment = NSTextAlignmentLeft;
    _address.accessibilityLabel = @"Address";
    [_address setContentCompressionResistancePriority:250
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    _media = LTButton(@"play.rectangle", @"Media controls", self, @selector(media:));
    NSButton *security =
        LTButton(@"info.circle", @"Site information and permissions", self, @selector(siteInfo:));
    NSArray *controls = @[
        _back, _forward, _reload, security, _media,
        LTButton(@"rectangle.split.2x1", @"Split View", self, @selector(split:)),
        LTButton(@"square.and.arrow.up", @"Share page", self, @selector(share:))
    ];
    LTWindowDragArea *dragArea = [LTWindowDragArea new];
    [dragArea.heightAnchor constraintEqualToConstant:24].active = YES;
    if (_store.privateMode) {
        NSTextField *badge = LTLabel(@"Private", 11, NSFontWeightSemibold);
        badge.textColor = NSColor.secondaryLabelColor;
        badge.translatesAutoresizingMaskIntoConstraints = NO;
        [dragArea addSubview:badge];
        [badge.trailingAnchor constraintEqualToAnchor:dragArea.trailingAnchor].active = YES;
        [badge.centerYAnchor constraintEqualToAnchor:dragArea.centerYAnchor].active = YES;
    }
    NSStackView *navigation = LTStack(controls, NSUserInterfaceLayoutOrientationHorizontal, 2);
    NSStackView *header =
        LTStack(@[ dragArea, navigation, _address ], NSUserInterfaceLayoutOrientationVertical, 4);
    [dragArea.widthAnchor constraintEqualToAnchor:header.widthAnchor].active = YES;
    [_address.widthAnchor constraintEqualToAnchor:header.widthAnchor].active = YES;
    [_address.heightAnchor constraintEqualToConstant:28].active = YES;
    _layout = [[NSSplitView alloc] initWithFrame:NSZeroRect];
    _layout.vertical = YES;
    _layout.dividerStyle = NSSplitViewDividerStyleThin;
    _layout.delegate = self;
    _layout.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_layout];
    if (!_mini) {
        _sidebar = [[LTSidebar alloc] initWithStore:_store header:header];
        _sidebarHost = _sidebar;
        __weak typeof(self) weak = self;
        _sidebar.selected = ^(NSString *identifier) {
          [weak selectTab:identifier];
        };
        _sidebar.spaceSelected = ^(NSString *identifier) {
          [weak selectSpace:identifier];
        };
        _sidebar.command = ^(NSString *c, NSString *identifier) {
          [weak command:c item:identifier];
        };
        _sidebar.pageState = ^NSDictionary *(NSString *identifier) {
          LTWindow *owner = weak;
          if (!owner)
              return @{};
          LTPage *p = owner->_pageMap[identifier];
          NSMutableDictionary *d = [NSMutableDictionary new];
          if (owner->_store.profile.settings[@"githubLiveFolders"][identifier])
              d[@"liveStatus"] = [owner.github statusForFolder:identifier] ?: @"GitHub Live Folder";
          NSImage *icon =
              p.favicon ?: [owner->_icons imageForURL:[owner->_store.profile node:identifier].url];
          if (icon)
              d[@"favicon"] = icon;
          if (p.loading)
              d[@"loading"] = @YES;
          if (p.audible)
              d[@"audio"] = @YES;
          if (p.errorText.length)
              d[@"error"] = @YES;
          if (p && (p.frozen || !p.alive))
              d[@"frozen"] = @YES;
          return d;
        };
    } else {
        NSVisualEffectView *miniSidebar = [NSVisualEffectView new];
        miniSidebar.material = NSVisualEffectMaterialSidebar;
        miniSidebar.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        _sidebarHost = miniSidebar;
        NSButton *promote = [NSButton buttonWithTitle:@"Open in Lite ↗"
                                               target:self
                                               action:@selector(promote:)];
        promote.bezelStyle = NSBezelStyleRecessed;
        [header addArrangedSubview:promote];
        header.translatesAutoresizingMaskIntoConstraints = NO;
        [miniSidebar addSubview:header];
        [header.topAnchor constraintEqualToAnchor:miniSidebar.topAnchor constant:10].active = YES;
        [header.leadingAnchor constraintEqualToAnchor:miniSidebar.leadingAnchor constant:12]
            .active = YES;
        [header.trailingAnchor constraintEqualToAnchor:miniSidebar.trailingAnchor constant:-12]
            .active = YES;
    }
    _sidebarHost.accessibilityLabel = @"Browser sidebar";
    _sidebarHost.wantsLayer = YES;
    [_layout addSubview:_sidebarHost];
    _content = [NSView new];
    [_layout addSubview:_content];
    _content.wantsLayer = YES;
    _content.layer.masksToBounds = YES;
    _content.layer.backgroundColor = NSColor.textBackgroundColor.CGColor;
    _webSplit = [[LTContentSplit alloc] initWithFrame:NSZeroRect];
    _webSplit.vertical = _verticalSplit;
    _webSplit.dividerStyle = NSSplitViewDividerStyleThin;
    _webSplit.delegate = self;
    LTPin(_webSplit, _content, 0);
    [_webSplit registerForDraggedTypes:@[ @"app.lite.sidebar-item" ]];
    __weak typeof(self) weak = self;
    _webSplit.dropped = ^(NSString *identifier) {
      [weak splitWith:identifier vertical:YES];
    };
    _parking = [NSView new];
    _parking.hidden = YES;
    [root addSubview:_parking];
    _landing = [NSView new];
    NSImageView *logo =
        [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"leaf"
                                                  accessibilityDescription:@"Lite"]];
    logo.contentTintColor = [NSColor colorWithRed:0.32 green:0.52 blue:0.47 alpha:1];
    [logo.widthAnchor constraintEqualToConstant:58].active = YES;
    [logo.heightAnchor constraintEqualToConstant:58].active = YES;
    NSTextField *brand =
        LTLabel(_store.privateMode ? @"A private space." : @"A little room to think.", 29,
                NSFontWeightMedium);
    NSTextField *hint =
        LTLabel(_store.privateMode ? @"History and cookies from this window stay temporary."
                                   : @"Your tabs, your Spaces. Everything in its place.",
                13, NSFontWeightRegular);
    hint.textColor = NSColor.secondaryLabelColor;
    NSButton *start = [NSButton buttonWithTitle:@"Search or enter URL     ⌘T"
                                         target:self
                                         action:@selector(newTab:)];
    start.bezelStyle = NSBezelStyleRounded;
    start.controlSize = NSControlSizeLarge;
    NSStackView *welcome =
        LTStack(@[ logo, brand, hint, start ], NSUserInterfaceLayoutOrientationVertical, 18);
    welcome.alignment = NSLayoutAttributeCenterX;
    welcome.translatesAutoresizingMaskIntoConstraints = NO;
    [_landing addSubview:welcome];
    [NSLayoutConstraint activateConstraints:@[
        [welcome.centerXAnchor constraintEqualToAnchor:_landing.centerXAnchor],
        [welcome.centerYAnchor constraintEqualToAnchor:_landing.centerYAnchor constant:-24]
    ]];
    _error = LTLabel(@"", 12, NSFontWeightMedium);
    _error.textColor = NSColor.systemRedColor;
    _error.maximumNumberOfLines = 2;
    _error.hidden = YES;
    _error.translatesAutoresizingMaskIntoConstraints = NO;
    [_content addSubview:_error];
    [NSLayoutConstraint activateConstraints:@[
        [_error.leadingAnchor constraintEqualToAnchor:_content.leadingAnchor constant:20],
        [_error.trailingAnchor constraintEqualToAnchor:_content.trailingAnchor constant:-20],
        [_error.topAnchor constraintEqualToAnchor:_content.topAnchor constant:12]
    ]];
    _find = [NSSearchField new];
    _find.placeholderString = @"Find in page";
    _find.delegate = self;
    _find.target = self;
    _find.action = @selector(findNext:);
    [_find.widthAnchor constraintEqualToConstant:220].active = YES;
    _findBar = LTStack(
        @[
            _find, LTButton(@"chevron.up", @"Previous match", self, @selector(findPrevious:)),
            LTButton(@"chevron.down", @"Next match", self, @selector(findNext:)),
            LTButton(@"xmark", @"Close find", self, @selector(closeFind:))
        ],
        NSUserInterfaceLayoutOrientationHorizontal, 5);
    _findBar.hidden = YES;
    _findBar.wantsLayer = YES;
    _findBar.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
    _findBar.layer.cornerRadius = 8;
    _findBar.edgeInsets = NSEdgeInsetsMake(6, 8, 6, 8);
    _findBar.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_findBar];
    [NSLayoutConstraint activateConstraints:@[
        [_layout.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_layout.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_layout.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_layout.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_findBar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-16],
        [_findBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24]
    ]];
    [root layoutSubtreeIfNeeded];
    [self updateSidebarPresentation];
    root.pointerChanged = ^(NSPoint point) {
      [weak sidebarPointerMoved:point];
    };
    _mouseMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged |
                                             NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
                                             NSEventMaskKeyDown
                                     handler:^NSEvent *(NSEvent *event) {
                                       LTWindow *owner = weak;
                                       if (owner && event.window == owner.window &&
                                           event.type == NSEventTypeKeyDown) {
                                           if (event.keyCode == 53 && !owner->_findBar.hidden &&
                                               !owner.window.attachedSheet) {
                                               [owner closeFind:nil];
                                               return nil;
                                           }
                                           return event;
                                       }
                                       if (owner && event.window == owner.window)
                                           [owner sidebarPointerMoved:
                                                      [owner.window.contentView
                                                          convertPoint:event.locationInWindow
                                                              fromView:nil]];
                                       return event;
                                     }];
}
- (void)commit:(void (^)(LTProfile *))block {
    NSError *e = nil;
    if (![_store commit:block error:&e])
        LTAlert(self.window, @"Could not save", e.localizedDescription);
}
- (void)storeChanged:(NSNotification *)note {
    if (!_metadataChange)
        [self refresh];
}
- (void)refresh {
    if (![_store.profile space:_spaceID])
        _spaceID = _store.profile.activeSpaceID;
    if (!_mini && ![_store.profile node:_activeID])
        _activeID = [_store.profile space:_spaceID].selectedID;
    if (!_mini && ![_store.profile node:_secondaryID])
        _secondaryID = @"";
    [_sidebar refreshSpace:_spaceID selected:_activeID];
    [self displayPages];
}
- (LTPage *)pageFor:(NSString *)identifier {
    if (!identifier.length)
        return nil;
    LTPage *p = _pageMap[identifier];
    if (p)
        return p;
    LTNode *n = [_store.profile node:identifier];
    if (!n || [n.kind isEqual:@"folder"])
        return nil;
    p = [[LTPage alloc] initWithID:identifier url:n.url context:_context];
    p.title = n.displayTitle;
    p.delegate = self;
    _pageMap[identifier] = p;
    return p;
}
- (LTPage *)activePage {
    return _pageMap[([_focusedID isEqual:_activeID] || [_focusedID isEqual:_secondaryID])
                        ? _focusedID
                        : _activeID];
}
- (void)displayPages {
    for (LTPage *p in self.pages) {
        BOOL visible = [p.identifier isEqual:_activeID] || [_secondaryID isEqual:p.identifier];
        p.visible = visible;
        if (!visible && p.container.superview != _parking) {
            [p.container removeFromSuperview];
            [_parking addSubview:p.container];
        }
    }
    NSArray *wanted =
        _secondaryID.length ? @[ _activeID ?: @"", _secondaryID ] : @[ _activeID ?: @"" ];
    NSMutableArray *views = [NSMutableArray new];
    for (NSString *identifier in wanted) {
        LTPage *p = [self pageFor:identifier];
        if (p) {
            p.visible = YES;
            [views addObject:p.container];
        }
    }
    if (!views.count)
        [views addObject:_landing];
    if (![_webSplit.subviews isEqual:views]) {
        for (NSView *v in [_webSplit.subviews copy])
            [v removeFromSuperview];
        for (NSView *v in views)
            [_webSplit addSubview:v];
        _webSplit.vertical = _verticalSplit;
        [_webSplit adjustSubviews];
        if (views.count == 2)
            [_webSplit setPosition:(_verticalSplit ? _webSplit.bounds.size.width
                                                   : _webSplit.bounds.size.height) *
                                   _splitRatio
                  ofDividerAtIndex:0];
    }
    for (NSString *identifier in wanted)
        [[self pageFor:identifier] loadIfNeeded];
    [self updateNavigation];
}
- (void)selectTab:(NSString *)identifier {
    LTNode *n = [_store.profile node:identifier];
    if (!n)
        return;
    if (_splitPending) {
        _splitPending = NO;
        [self splitWith:identifier vertical:_verticalSplit];
        return;
    }
    if (![n.kind isEqual:@"favorite"] && ![n.spaceID isEqual:_spaceID]) {
        _spaceID = n.spaceID;
        _secondaryID = @"";
    }
    if (![_secondaryID isEqual:identifier])
        _activeID = identifier;
    _focusedID = identifier;
    _metadataChange = YES;
    [self commit:^(LTProfile *p) {
      p.activeSpaceID = self->_spaceID;
      [p space:self->_spaceID].selectedID = identifier;
      [p node:identifier].lastUsed = NSDate.date.timeIntervalSince1970;
    }];
    _metadataChange = NO;
    [self refresh];
    [[self activePage] focus];
    [self scheduleSave];
}
- (void)selectSpace:(NSString *)identifier {
    if (![_store.profile space:identifier])
        return;
    _spaceID = identifier;
    _activeID = [_store.profile space:identifier].selectedID;
    _secondaryID = @"";
    [self commit:^(LTProfile *p) {
      p.activeSpaceID = identifier;
    }];
    [self scheduleSave];
}
- (void)openURL:(NSString *)url {
    if (!LTValidURL(url))
        url = LTURLFromInput(url, _store.profile.settings[@"search"]);
    if (_mini) {
        NSString *identifier = _activeID.length ? _activeID : LTUUID();
        if (!_pageMap[identifier]) {
            LTPage *p = [[LTPage alloc] initWithID:identifier url:url context:_context];
            p.delegate = self;
            _pageMap[identifier] = p;
        }
        _activeID = identifier;
        [_pageMap[identifier] navigate:url];
        [self displayPages];
        return;
    }
    __block NSString *identifier;
    [self commit:^(LTProfile *p) {
      identifier = [p addNode:@"temporary"
                        title:[NSURL URLWithString:url].host ?: @"New Tab"
                          url:url
                        space:self->_spaceID
                       parent:@""]
                       .identifier;
    }];
    [self selectTab:identifier];
}
- (void)updateNavigation {
    LTPage *p = [self activePage];
    _back.enabled = p.canBack;
    _forward.enabled = p.canForward;
    _reload.image = [NSImage imageWithSystemSymbolName:p.loading ? @"xmark" : @"arrow.clockwise"
                              accessibilityDescription:p.loading ? @"Stop" : @"Reload"];
    NSString *host = [NSURL URLWithString:p.url].host;
    _address.title = p ? host ?: p.url : @"Search or enter URL";
    _address.image = p.secure ? [NSImage imageWithSystemSymbolName:@"lock.fill"
                                          accessibilityDescription:@"Encrypted connection"]
                              : nil;
    _address.imagePosition = NSImageLeft;
    _address.toolTip = p.url;
    BOOL playing = NO;
    for (LTPage *source in self.pages)
        playing |= source.audible || source.pictureInPicture;
    _media.hidden = !playing;
    _error.stringValue = p.errorText ?: @"";
    _error.hidden = !p.errorText.length;
    self.window.title =
        [NSString stringWithFormat:@"%@%@%@", _mini ? @"Mini Lite" : @"Lite",
                                   _store.privateMode ? @" — Private" : @"",
                                   p.title.length ? [@" — " stringByAppendingString:p.title] : @""];
}
- (void)faviconChanged:(NSNotification *)notification {
    for (LTNode *node in _store.profile.nodes)
        if ([LTFaviconOrigin(node.url) isEqual:notification.userInfo[@"origin"]])
            [_sidebar updateItem:node.identifier];
}
- (void)pageChanged:(LTPage *)page {
    if (page.favicon)
        [_icons storeImage:page.favicon forURL:page.url];
    if (!_mini) {
        LTNode *n = [_store.profile node:page.identifier];
        if (n &&
            (![n.url isEqual:page.url] || (page.title.length && ![n.title isEqual:page.title])) &&
            LTValidURL(page.url)) {
            _metadataChange = YES;
            [self commit:^(LTProfile *p) {
              LTNode *n = [p node:page.identifier];
              n.url = page.url;
              if (page.title.length)
                  n.title = page.title;
            }];
            _metadataChange = NO;
        }
    }
    NSString *visit = [page.url stringByAppendingString:page.title];
    if (!page.loading && !page.errorText.length && ![_visitKeys[page.identifier] isEqual:visit]) {
        [_store recordVisit:page.url title:page.title];
        _visitKeys[page.identifier] = visit;
    }
    [_sidebar updateItem:page.identifier];
    [self updateNavigation];
}
- (void)pageClosed:(LTPage *)page {
    if ([_pendingClose containsObject:page.identifier]) {
        [_pendingClose removeObject:page.identifier];
        [self completeClose:page.identifier];
    }
    if (_closingWindow) {
        BOOL alive = NO;
        for (LTPage *p in self.pages)
            alive |= p.alive;
        if (!alive)
            [self.window close];
    }
    [_sidebar updateItem:page.identifier];
}
- (void)pageCloseCanceled:(LTPage *)page {
    [_pendingClose removeObject:page.identifier];
    _closingWindow = NO;
}
- (void)page:(LTPage *)page openURL:(NSString *)url {
    [self openURL:url];
}
- (void)page:(LTPage *)page downloadChanged:(NSDictionary *)download {
    _downloadRows[download[@"id"]] = download;
    [_library updateDownloads:_downloadRows.allValues];
}
- (void)pageFocused:(NSNotification *)n {
    LTPage *p = n.object;
    if (p != [self activePage] &&
        ([_activeID isEqual:p.identifier] || [_secondaryID isEqual:p.identifier])) {
        _focusedID = p.identifier;
        [self updateNavigation];
        [_sidebar refreshSpace:_spaceID selected:p.identifier];
    }
}
- (void)showCommand:(NSString *)initial {
    _command = [[LTCommandPanel alloc] initWithStore:_store
                                             openIDs:[NSSet setWithArray:_pageMap.allKeys]];
    __weak typeof(self) weak = self;
    _command.selected = ^(NSDictionary *r) {
      LTWindow *self = weak;
      if (!self)
          return;
      NSString *type = r[@"type"], *value = r[@"value"];
      if ([type isEqual:@"url"]) {
          if (self->_addressMode && [self activePage]) {
              [[self activePage] navigate:value];
              self->_addressMode = NO;
          } else
              [self openURL:value];
      } else if ([type isEqual:@"tab"])
          [self selectTab:value];
      else if ([type isEqual:@"space"])
          [self selectSpace:value];
      else
          [self performCommand:value];
    };
    [_command presentForWindow:self.window initial:initial];
}
- (void)performCommand:(NSString *)command {
    [self command:command item:[self activePage].identifier ?: _activeID ?: @""];
}
- (void)command:(NSString *)command item:(NSString *)identifier {
    LTNode *node = [_store.profile node:identifier];
    if ([command isEqual:@"newTab"]) {
        _addressMode = NO;
        [self showCommand:@""];
    } else if ([command isEqual:@"address"]) {
        _addressMode = YES;
        [self showCommand:[self activePage].url ?: @""];
    } else if ([command isEqual:@"newWindow"] || [command isEqual:@"newPrivate"]) {
        [NSNotificationCenter.defaultCenter postNotificationName:@"LTAppCommand" object:command];
    } else if ([command isEqual:@"newSpace"]) {
        LTAskName(self.window, @"New Space", @"", ^(NSString *name) {
          __block NSString *sid;
          [self commit:^(LTProfile *p) {
            sid = [p addSpace:name].identifier;
          }];
          [self selectSpace:sid];
        });
    } else if ([command isEqual:@"githubFolder"] || [command isEqual:@"editGitHubFolder"]) {
        [self configureGitHubFolder:[command isEqual:@"editGitHubFolder"] ? identifier : nil];
    } else if ([command isEqual:@"refreshGitHubFolder"]) {
        [_github refreshFolder:identifier];
    } else if ([command isEqual:@"stopGitHubFolder"]) {
        [self commit:^(LTProfile *profile) {
            NSMutableDictionary *folders = [profile.settings[@"githubLiveFolders"] mutableCopy];
            [folders removeObjectForKey:identifier];
            profile.settings[@"githubLiveFolders"] = folders ?: @{};
        }];
    } else if ([command isEqual:@"taskManager"] || [command isEqual:@"shortcuts"]) {
        [NSNotificationCenter.defaultCenter postNotificationName:@"LTAppCommand" object:command];
    } else if ([command isEqual:@"applePasswords"]) {
        NSURL *app = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.apple.Passwords"];
        if (app) [NSWorkspace.sharedWorkspace openURL:app];
        else [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Passwords-Settings.extension"]];
    } else if ([command isEqual:@"renameSpace"]) {
        LTAskName(self.window, @"Rename Space", [_store.profile space:_spaceID].name,
                  ^(NSString *name) {
                    [self commit:^(LTProfile *p) {
                      [p space:self->_spaceID].name = name;
                    }];
                  });
    } else if ([command isEqual:@"deleteSpace"]) {
        if (_store.profile.spaces.count <= 1) {
            LTAlert(self.window, @"Keep one Space",
                    @"Create another Space before deleting this one.");
            return;
        }
        LTConfirm(self.window, @"Delete this Space?",
                  @"Its pinned tabs, folders, and temporary tabs will be removed.", @"Delete Space",
                  ^{
                    NSString *sid = self->_spaceID;
                    for (LTNode *n in self->_store.profile.nodes)
                        if ([n.spaceID isEqual:sid]) {
                            LTPage *p = self->_pageMap[n.identifier];
                            p.visible = NO;
                            [p close];
                        }
                    [self commit:^(LTProfile *p) {
                      [p removeSpace:sid];
                    }];
                  });
    } else if ([command isEqual:@"newFolder"] || [command isEqual:@"folderInside"]) {
        NSString *parent = [command isEqual:@"folderInside"] ? identifier : @"";
        LTAskName(self.window, @"New Folder", @"", ^(NSString *name) {
          [self commit:^(LTProfile *p) {
            [p addNode:@"folder" title:name url:@"" space:self->_spaceID parent:parent];
          }];
        });
    } else if ([command isEqual:@"pinTab"] && node) {
        [self commit:^(LTProfile *p) {
          LTNode *n = [p node:identifier];
          if ([n.kind isEqual:@"favorite"])
              return;
          BOOL pin = ![n.kind isEqual:@"pinned"];
          n.kind = pin ? @"pinned" : @"temporary";
          if (pin)
              n.pinnedURL = n.url;
          else
              n.parentID = @"";
        }];
    } else if ([command isEqual:@"rename"] && node) {
        LTAskName(self.window, @"Rename", node.displayTitle, ^(NSString *name) {
          [self commit:^(LTProfile *p) {
            LTNode *n = [p node:identifier];
            if ([n.kind isEqual:@"folder"])
                n.title = name;
            else
                n.customTitle = name;
          }];
        });
    } else if ([command isEqual:@"favorite"] && node) {
        [self commit:^(LTProfile *p) {
          [p addNode:@"favorite" title:node.displayTitle url:node.url space:@"" parent:@""];
        }];
    } else if ([command isEqual:@"duplicate"] && node)
        [self openURL:node.url];
    else if ([command isEqual:@"resetPinned"] && node.pinnedURL.length)
        [[self pageFor:identifier] navigate:node.pinnedURL];
    else if ([command isEqual:@"copyURL"] && node) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:node.url forType:NSPasteboardTypeString];
    } else if ([command isEqual:@"keepAwake"]) {
        LTPage *p = [self pageFor:identifier];
        p.keepAwake = !p.keepAwake;
    } else if ([command isEqual:@"moveTab"] || [command isEqual:@"moveFolder"]) {
        [self moveItem:identifier folder:[command isEqual:@"moveFolder"]];
    } else if ([command isEqual:@"openAll"]) {
        for (LTNode *n in [_store.profile children:identifier space:_spaceID kind:nil]) {
            if ([n.kind isEqual:@"folder"])
                [self command:@"openAll" item:n.identifier];
            else
                [[self pageFor:n.identifier] loadIfNeeded];
        }
    } else if ([command isEqual:@"deleteNode"]) {
        LTConfirm(self.window, @"Delete this folder?",
                  @"The folder and its pinned tabs will be removed.", @"Delete", ^{
                    [self commit:^(LTProfile *p) {
                      [p removeNode:identifier];
                    }];
                  });
    } else if ([command isEqual:@"closeTab"])
        [self closeTabID:identifier];
    else if ([command isEqual:@"reopenTab"]) {
        NSDictionary *j = _closed.lastObject;
        if (j) {
            [_closed removeLastObject];
            LTNode *n = [LTNode fromJSON:j];
            n.parentID = @"";
            n.spaceID = _spaceID;
            if ([_store.profile node:n.identifier])
                n.identifier = LTUUID();
            [self commit:^(LTProfile *p) {
              [p.nodes addObject:n];
            }];
            [self selectTab:n.identifier];
        }
    } else if ([command isEqual:@"splitRight"] || [command isEqual:@"splitDown"]) {
        if (!_activeID.length)
            return;
        _verticalSplit = [command isEqual:@"splitRight"];
        _splitPending = YES;
        [self showCommand:@""];
    } else if ([command isEqual:@"splitTab"])
        [self splitWith:identifier vertical:YES];
    else if ([command isEqual:@"closeSplit"]) {
        _secondaryID = @"";
        [self displayPages];
        [self scheduleSave];
    } else if ([command isEqual:@"swapSplit"]) {
        if (_secondaryID.length) {
            NSString *old = _activeID;
            _activeID = _secondaryID;
            _secondaryID = old;
            [self displayPages];
            [self scheduleSave];
        }
    } else if ([command isEqual:@"focusSplit"]) {
        [[_pageMap objectForKey:_secondaryID] focus];
    } else if ([command isEqual:@"nextSpace"] || [command isEqual:@"previousSpace"]) {
        NSInteger i = [_store.profile.spaces indexOfObject:[_store.profile space:_spaceID]],
                  count = _store.profile.spaces.count;
        [self
            selectSpace:_store.profile
                            .spaces[(i + ([command isEqual:@"nextSpace"] ? 1 : count - 1)) % count]
                            .identifier];
    } else if ([command isEqual:@"nextTab"] || [command isEqual:@"previousTab"]) {
        NSMutableArray *tabs = [NSMutableArray new];
        for (LTNode *n in _store.profile.nodes)
            if ([n.spaceID isEqual:_spaceID] && ![n.kind isEqual:@"folder"])
                [tabs addObject:n];
        if (tabs.count) {
            NSInteger i = [tabs indexOfObject:[_store.profile node:_activeID]];
            if (i == NSNotFound)
                i = 0;
            [self selectTab:((LTNode *)
                                 tabs[(i + ([command isEqual:@"nextTab"] ? 1 : tabs.count - 1)) %
                                      tabs.count])
                                .identifier];
        }
    } else if ([command isEqual:@"toggleSidebar"])
        [self toggleSidebar:nil];
    else if ([command isEqual:@"downloads"] || [command isEqual:@"history"] ||
             [command isEqual:@"settings"])
        [_library showMode:command owner:self.window downloads:_downloadRows.allValues];
    else if ([command isEqual:@"importArc"])
        [self importArc];
    else if ([command isEqual:@"importBookmarks"])
        [self importBookmarks];
    else if ([command isEqual:@"saveLogin"] || [command isEqual:@"fillLogin"] ||
             [command isEqual:@"passwords"]) {
        if (!_passwords)
            LTAlert(self.window, @"Logins are unavailable in private windows",
                    @"Use a regular Lite window to save, fill, or manage logins.");
        else if ([command isEqual:@"saveLogin"])
            [_passwords saveForPage:[self activePage] window:self.window];
        else if ([command isEqual:@"fillLogin"])
            [_passwords fillForPage:[self activePage] window:self.window];
        else
            [_passwords manageForWindow:self.window];
    } else if ([command isEqual:@"googlePasswords"])
        [self openURL:@"https://passwords.google.com/"];
    else if ([command isEqual:@"clearData"]) {
        LTConfirm(self.window, @"Clear cookies, cache, and history?",
                  @"You will be signed out of websites. Sidebar organization will be kept. Site "
                  @"storage such as IndexedDB can be cleared in Developer Tools.",
                  @"Clear Data", ^{
                    [self->_context clearData];
                    [self->_store clearHistorySince:0];
                  });
    } else if ([command isEqual:@"extensions"]) {
        LTAlert(self.window, @"Chromium compatibility",
                @"Lite uses Chromium 154 with native embedded pages. Chrome Web Store extensions "
                @"and licensed DRM are not enabled in this build. HTML, "
                @"JavaScript, WebGL, WebRTC, and Chromium storage are provided by the engine. No "
                @"unsupported extension API is emulated.");
    } else if ([command isEqual:@"defaultBrowser"]) {
        [NSWorkspace.sharedWorkspace
            setDefaultApplicationAtURL:NSBundle.mainBundle.bundleURL
                  toOpenURLsWithScheme:@"http"
                     completionHandler:^(NSError *e) {
                       if (e)
                           dispatch_async(dispatch_get_main_queue(), ^{
                             LTAlert(self.window, @"Default browser", e.localizedDescription);
                           });
                     }];
        [NSWorkspace.sharedWorkspace setDefaultApplicationAtURL:NSBundle.mainBundle.bundleURL
                                           toOpenURLsWithScheme:@"https"
                                              completionHandler:nil];
    } else if ([command isEqual:@"fullScreen"])
        [self.window toggleFullScreen:nil];
    else if ([command isEqual:@"back"])
        [[self activePage] back];
    else if ([command isEqual:@"forward"])
        [[self activePage] forward];
    else if ([command isEqual:@"reload"])
        [[self pageFor:identifier] reload];
    else if ([command isEqual:@"find"]) {
        _findBar.hidden = NO;
        [self.window.contentView addSubview:_findBar positioned:NSWindowAbove relativeTo:nil];
        [self.window makeFirstResponder:_find];
    } else if ([command isEqual:@"print"])
        [[self activePage] print];
    else if ([command isEqual:@"save"])
        [[self activePage] save];
    else if ([command isEqual:@"zoomIn"])
        [[self activePage] zoom:0.5];
    else if ([command isEqual:@"zoomOut"])
        [[self activePage] zoom:-0.5];
    else if ([command isEqual:@"zoomReset"])
        [[self activePage] resetZoom];
    else if ([command isEqual:@"devTools"])
        [[self activePage] showDevTools];
    else if ([command isEqual:@"pip"])
        [[self activePage] enterPictureInPicture];
}
- (void)configureGitHubFolder:(NSString *)identifier {
    if (_store.privateMode || !_github) {
        LTAlert(self.window, @"Live Folders are unavailable here", @"Use a regular Lite window to connect GitHub.");
        return;
    }
    NSDictionary *existing = _store.profile.settings[@"githubLiveFolders"][identifier ?: @""] ?: @{};
    NSAlert *alert = [NSAlert new];
    alert.messageText = identifier ? @"Edit GitHub Live Folder" : @"New GitHub Live Folder";
    alert.informativeText = @"Open pull requests refresh every five minutes. Public results need no token. For private repositories, add a GitHub token with access to those repositories; it stays in Apple Keychain.";
    NSTextField *user = [NSTextField new], *repo = [NSTextField new];
    user.placeholderString = @"GitHub username";
    user.stringValue = existing[@"username"] ?: @"";
    repo.placeholderString = @"owner/repository (optional)";
    repo.stringValue = existing[@"repository"] ?: @"";
    NSPopUpButton *mode = [NSPopUpButton new], *draft = [NSPopUpButton new];
    NSArray *modes = @[@"authored", @"review", @"assigned", @"repository"], *drafts = @[@"all", @"ready", @"draft"];
    [mode addItemsWithTitles:@[@"Authored by this user", @"Review requested from this user", @"Assigned to this user", @"All open PRs in repository"]];
    [draft addItemsWithTitles:@[@"Include drafts", @"Ready for review only", @"Drafts only"]];
    NSUInteger selectedMode = [modes indexOfObject:existing[@"mode"] ?: @"authored"];
    NSUInteger selectedDraft = [drafts indexOfObject:existing[@"draft"] ?: @"all"];
    [mode selectItemAtIndex:selectedMode == NSNotFound ? 0 : selectedMode];
    [draft selectItemAtIndex:selectedDraft == NSNotFound ? 0 : selectedDraft];
    NSSecureTextField *token = [NSSecureTextField new];
    token.placeholderString = @"Optional token; leave blank to keep the saved token";
    NSButton *forget = [NSButton checkboxWithTitle:@"Forget the saved GitHub token (all Live Folders)" target:nil action:nil];
    NSTextField *status = [NSTextField wrappingLabelWithString:identifier ? [_github statusForFolder:identifier] : @"Only github.com is supported. Closing a pull request removes it from this folder; an open tab stays available."];
    status.font = [NSFont systemFontOfSize:11];
    NSStackView *form = LTStack(@[LTLabel(@"Account", 12, NSFontWeightMedium), user,
        LTLabel(@"Repository", 12, NSFontWeightMedium), repo, mode, draft,
        LTLabel(@"GitHub API token", 12, NSFontWeightMedium), token, forget, status],
        NSUserInterfaceLayoutOrientationVertical, 8);
    form.frame = NSMakeRect(0, 0, 430, 345);
    for (NSView *view in @[user, repo, mode, draft, token, status])
        [view.widthAnchor constraintEqualToConstant:430].active = YES;
    alert.accessoryView = form;
    [alert addButtonWithTitle:identifier ? @"Save and Refresh" : @"Create Folder"];
    [alert addButtonWithTitle:@"Cancel"];
    NSString *space = _spaceID;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        NSString *secret = token.stringValue;
        token.stringValue = @"";
        if (response != NSAlertFirstButtonReturn) return;
        NSCharacterSet *spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
        NSMutableDictionary *configuration = [@{
            @"username": [user.stringValue stringByTrimmingCharactersInSet:spaces],
            @"repository": [repo.stringValue stringByTrimmingCharactersInSet:spaces],
            @"mode": modes[mode.indexOfSelectedItem], @"draft": drafts[draft.indexOfSelectedItem]
        } mutableCopy];
        NSError *error = nil;
        if (!LTGitHubQuery(configuration, &error)) {
            LTAlert(self.window, @"Check GitHub folder settings", error.localizedDescription);
            return;
        }
        if ((secret.length || forget.state == NSControlStateValueOn) &&
            ![self.github.logins setGitHubToken:secret error:&error]) {
            LTAlert(self.window, @"Could not save GitHub token", error.localizedDescription);
            return;
        }
        __block NSString *folderID = identifier;
        BOOL saved = [self.store commit:^(LTProfile *profile) {
            if (identifier && ![profile node:identifier]) return;
            if (!folderID) {
                LTNode *folder = [profile addNode:@"folder" title:@"GitHub Pull Requests" url:@"" space:space parent:@""];
                folder.expanded = YES;
                folderID = folder.identifier;
            }
            NSDictionary *previous = profile.settings[@"githubLiveFolders"][folderID];
            if (previous[@"items"]) configuration[@"items"] = previous[@"items"];
            NSMutableDictionary *folders = [profile.settings[@"githubLiveFolders"] mutableCopy] ?: [NSMutableDictionary new];
            folders[folderID] = configuration;
            profile.settings[@"githubLiveFolders"] = folders;
        } error:&error];
        if (!saved) LTAlert(self.window, @"Could not save Live Folder", error.localizedDescription);
        else [self.github refreshFolder:folderID];
    }];
    [alert.window makeFirstResponder:user];
}
- (void)closeTabID:(NSString *)identifier {
    if (_mini) {
        [self.window performClose:nil];
        return;
    }
    LTNode *n = [_store.profile node:identifier];
    if (!n)
        return;
    LTPage *page = _pageMap[identifier];
    if (page.dirty) {
        LTConfirm(self.window, @"Close this edited page?", @"Unsaved form changes may be lost.",
                  @"Close Tab", ^{
                    page.dirty = NO;
                    [self closeTabID:identifier];
                  });
        return;
    }
    if (page.alive) {
        [_pendingClose addObject:identifier];
        [page close];
    } else
        [self completeClose:identifier];
}
- (void)completeClose:(NSString *)identifier {
    LTNode *n = [_store.profile node:identifier];
    if (!n)
        return;
    if ([n.kind isEqual:@"temporary"]) {
        [_closed addObject:n.JSON];
        if (_closed.count > 30)
            [_closed removeObjectAtIndex:0];
    }
    _pageMap[identifier].visible = NO;
    if ([_activeID isEqual:identifier]) {
        _activeID = _secondaryID.length ? _secondaryID : @"";
        _secondaryID = @"";
    } else if ([_secondaryID isEqual:identifier])
        _secondaryID = @"";
    [self commit:^(LTProfile *p) {
      if ([n.kind isEqual:@"temporary"])
          [p removeNode:identifier];
      [p space:self->_spaceID].selectedID = self->_activeID;
    }];
    if ([n.kind isEqual:@"temporary"])
        [_pageMap removeObjectForKey:identifier];
    [self displayPages];
    [self scheduleSave];
}
- (void)splitWith:(NSString *)identifier vertical:(BOOL)vertical {
    if ([identifier isEqual:_activeID] || !_activeID.length)
        return;
    LTNode *n = [_store.profile node:identifier];
    if (!n || [n.kind isEqual:@"folder"])
        return;
    _secondaryID = identifier;
    _verticalSplit = vertical;
    _splitRatio = .5;
    [self displayPages];
    [self scheduleSave];
}
- (void)moveItem:(NSString *)identifier folder:(BOOL)folder {
    LTNode *node = [_store.profile node:identifier];
    if (!node)
        return;
    NSAlert *a = [NSAlert new];
    a.messageText = folder ? @"Move to Folder" : @"Move to Space";
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 300, 30)];
    NSMutableArray *ids = [NSMutableArray new];
    if (folder) {
        [popup addItemWithTitle:@"Pinned Tabs (top level)"];
        [ids addObject:@""];
        for (LTNode *n in _store.profile.nodes)
            if ([n.kind isEqual:@"folder"] && [n.spaceID isEqual:_spaceID] &&
                ![n.identifier isEqual:identifier]) {
                [popup addItemWithTitle:n.displayTitle];
                [ids addObject:n.identifier];
            }
    } else
        for (LTSpace *s in _store.profile.spaces) {
            [popup addItemWithTitle:s.name];
            [ids addObject:s.identifier];
        }
    a.accessoryView = popup;
    [a addButtonWithTitle:@"Move"];
    [a addButtonWithTitle:@"Cancel"];
    [a beginSheetModalForWindow:self.window
              completionHandler:^(NSModalResponse r) {
                if (r == NSAlertFirstButtonReturn) {
                    NSString *destination = ids[popup.indexOfSelectedItem];
                    NSError *e = nil;
                    BOOL ok = [self->_store
                        commit:^(LTProfile *p) {
                          LTNode *n = [p node:identifier];
                          if (folder && [n.kind isEqual:@"temporary"]) {
                              n.kind = @"pinned";
                              n.pinnedURL = n.url;
                          }
                          [p moveNode:identifier
                                space:folder ? self->_spaceID : destination
                               parent:folder ? destination : @""
                                index:NSIntegerMax
                                error:nil];
                        }
                         error:&e];
                    if (!ok)
                        LTAlert(self.window, @"Move failed", e.localizedDescription);
                }
              }];
}
- (void)previewImport:(LTImportResult *)result {
    NSAlert *a = [NSAlert new];
    a.messageText = @"Ready to import into Lite";
    a.informativeText = [result.summary
        stringByAppendingFormat:@"\n\n%@\nYour source data will remain unchanged.",
                                result.warnings.count
                                    ? [result.warnings componentsJoinedByString:@"\n"]
                                    : @"Folder hierarchy and ordering have been validated."];
    [a addButtonWithTitle:@"Import"];
    [a addButtonWithTitle:@"Cancel"];
    [a beginSheetModalForWindow:self.window
              completionHandler:^(NSModalResponse r) {
                if (r != NSAlertFirstButtonReturn)
                    return;
                [self commit:^(LTProfile *p) {
                  [LTImporter merge:result into:p];
                }];
                [self selectSpace:result.profile.activeSpaceID];
              }];
}
- (void)readArc:(NSURL *)url {
    NSError *e = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&e];
    LTImportResult *r = data ? [LTImporter parseArcData:data error:&e] : nil;
    if (r)
        [self previewImport:r];
    else
        LTAlert(self.window, @"Import could not be completed",
                e.localizedDescription
                    ?: @"The file could not be read. Try selecting another JSON file or importing "
                       @"HTML bookmarks in Settings.");
}
- (void)importArc {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowedContentTypes = @[ UTTypeJSON ];
    p.message = @"Choose an Arc StorableSidebar.json file. It will only be read.";
    NSArray *found = [LTImporter discoverArcFiles];
    if (found.count)
        p.directoryURL = [found.firstObject URLByDeletingLastPathComponent];
    [p beginSheetModalForWindow:self.window
              completionHandler:^(NSModalResponse r) {
                if (r == NSModalResponseOK)
                    [self readArc:p.URL];
              }];
}
- (void)importBookmarks {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.message =
        @"Choose an HTML bookmarks export, Chromium Bookmarks JSON, or Safari Bookmarks.plist.";
    [p beginSheetModalForWindow:self.window
              completionHandler:^(NSModalResponse response) {
                if (response != NSModalResponseOK)
                    return;
                NSError *e = nil;
                NSData *d = [NSData dataWithContentsOfURL:p.URL options:0 error:&e];
                NSString *ext = p.URL.pathExtension.lowercaseString;
                NSString *format = [ext isEqual:@"plist"]                            ? @"plist"
                                   : ([ext isEqual:@"html"] || [ext isEqual:@"htm"]) ? @"html"
                                                                                     : @"json";
                LTImportResult *r = d ? [LTImporter parseBookmarks:d format:format error:&e] : nil;
                if (r)
                    [self previewImport:r];
                else
                    LTAlert(self.window, @"Import failed", e.localizedDescription);
              }];
}
- (void)showOnboarding {
    if (_mini || _store.privateMode || [_store.profile.settings[@"onboarded"] boolValue])
        return;
    NSArray *files = [LTImporter discoverArcFiles];
    NSAlert *a = [NSAlert new];
    a.messageText = @"Welcome to Lite";
    a.informativeText =
        files.count ? @"We found your Arc browser data. Bring your Spaces, Favorites, pinned tabs, "
                      @"and nested folders into Lite. You can review the import before saving."
                    : @"A focused browser with a place for every tab. Press ⌘T to browse, ⌘D to "
                      @"pin a tab, or create a Space for your next project.";
    [a addButtonWithTitle:files.count ? @"Preview Arc Import" : @"Start Browsing"];
    [a addButtonWithTitle:files.count ? @"Start Fresh" : @"Import a Sidebar File…"];
    [a beginSheetModalForWindow:self.window
              completionHandler:^(NSModalResponse r) {
                if (files.count && r == NSAlertFirstButtonReturn)
                    [self readArc:files.firstObject];
                else if (!files.count && r == NSAlertSecondButtonReturn)
                    [self importArc];
                else
                    [self commit:^(LTProfile *p) {
                      p.settings[@"onboarded"] = @YES;
                    }];
              }];
}
- (NSDictionary *)restorationState {
    return @{
        @"space" : _spaceID ?: @"",
        @"active" : _activeID ?: @"",
        @"secondary" : _secondaryID ?: @"",
        @"vertical" : @(_verticalSplit),
        @"ratio" : @(_splitRatio),
        @"sidebarCollapsed" : @(_sidebarCollapsed),
        @"sidebarWidth" : @(_sidebarWidth),
        @"frame" : NSStringFromRect(self.window.frame)
    };
}
- (void)scheduleSave {
    if (_mini || _store.privateMode)
        return;
    [_saveTimer invalidate];
    __weak typeof(self) weak = self;
    _saveTimer = [NSTimer scheduledTimerWithTimeInterval:.4
                                                 repeats:NO
                                                   block:^(NSTimer *t) {
                                                     [NSNotificationCenter.defaultCenter
                                                         postNotificationName:@"LTWindowsChanged"
                                                                       object:weak];
                                                   }];
}
- (BOOL)windowShouldClose:(NSWindow *)sender {
    BOOL alive = NO;
    for (LTPage *p in self.pages)
        alive |= p.alive;
    if (!alive)
        return YES;
    _closingWindow = YES;
    for (LTPage *p in self.pages) {
        p.visible = NO;
        [p close];
    }
    return NO;
}
- (void)windowWillClose:(NSNotification *)n {
    [_command close];
    [_library close];
    [_saveTimer invalidate];
    [_sidebarHideTimer invalidate];
    if (_mouseMonitor) {
        [NSEvent removeMonitor:_mouseMonitor];
        _mouseMonitor = nil;
    }
    if (_didClose)
        _didClose(self);
}
- (void)windowDidResize:(NSNotification *)n {
    [self scheduleSave];
}
- (void)windowDidMove:(NSNotification *)n {
    [self scheduleSave];
}
- (CGFloat)splitView:(NSSplitView *)v
    constrainMinCoordinate:(CGFloat)p
               ofSubviewAt:(NSInteger)index {
    return v == _layout ? 238 : 120;
}
- (CGFloat)splitView:(NSSplitView *)v
    constrainMaxCoordinate:(CGFloat)p
               ofSubviewAt:(NSInteger)index {
    return v == _layout ? 340 : p - 120;
}
- (BOOL)splitView:(NSSplitView *)v canCollapseSubview:(NSView *)subview {
    return NO;
}
- (BOOL)splitView:(NSSplitView *)v shouldAdjustSizeOfSubview:(NSView *)subview {
    return v != _layout || subview == _content;
}
- (void)splitViewDidResizeSubviews:(NSNotification *)n {
    if (n.object == _layout && _mouseMonitor && !_updatingSidebar && !_sidebarCollapsed) {
        _sidebarWidth = MIN(340, MAX(238, _sidebarHost.frame.size.width));
        [self scheduleSave];
    }
    if (n.object == _webSplit && _webSplit.subviews.count == 2) {
        NSView *first = _webSplit.subviews.firstObject;
        double total = _verticalSplit ? _webSplit.bounds.size.width : _webSplit.bounds.size.height;
        if (total > 0)
            _splitRatio =
                (_verticalSplit ? first.frame.size.width : first.frame.size.height) / total;
        [self scheduleSave];
    }
}
- (void)newTab:(id)s {
    [self performCommand:@"newTab"];
}
- (void)address:(id)s {
    [self performCommand:@"address"];
}
- (void)back:(id)s {
    [[self activePage] back];
}
- (void)forward:(id)s {
    [[self activePage] forward];
}
- (void)reload:(id)s {
    LTPage *p = [self activePage];
    if (p.loading)
        [p stop];
    else
        [p reload];
}
- (void)toggleSidebar:(id)s {
    _sidebarCollapsed = !_sidebarCollapsed;
    _sidebarRevealed = NO;
    [_sidebarHideTimer invalidate];
    [self updateSidebarPresentation];
    [self scheduleSave];
}
- (void)updateSidebarPresentation {
    _updatingSidebar = YES;
    NSView *root = self.window.contentView;
    BOOL visible = !_sidebarCollapsed || _sidebarRevealed;
    BOOL animated =
        self.window.visible && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    NSUInteger generation = ++_sidebarAnimationGeneration;
    // Resume from the visible position when the pointer reverses a transition.
    CALayer *sidebarPresentation = _sidebarHost.layer.presentationLayer ?: _sidebarHost.layer;
    CGFloat previousX =
        _sidebarHost.superview ? CGRectGetMinX(sidebarPresentation.frame) : -_sidebarWidth;
    CALayer *contentPresentation = _content.layer.presentationLayer ?: _content.layer;
    CGPoint previousPosition = contentPresentation.position;
    CGRect previousBounds = contentPresentation.bounds;
    [_sidebarHost.layer removeAnimationForKey:@"sidebarSlide"];
    [_content.layer removeAnimationForKey:@"sidebarContent"];
    if (_sidebarCollapsed) {
        if (_sidebarHost.superview == _layout) {
            [_sidebarHost removeFromSuperview];
            [_layout adjustSubviews];
        }
        if (visible || animated) {
            if (_sidebarHost.superview != root)
                [root addSubview:_sidebarHost positioned:NSWindowAbove relativeTo:_layout];
            _sidebarHost.frame =
                NSMakeRect(visible ? 0 : -_sidebarWidth, 0, _sidebarWidth, root.bounds.size.height);
            _sidebarHost.autoresizingMask = NSViewHeightSizable;
        } else
            [_sidebarHost removeFromSuperview];
    } else {
        if (_sidebarHost.superview != _layout) {
            [_sidebarHost removeFromSuperview];
            [_layout addSubview:_sidebarHost positioned:NSWindowBelow relativeTo:_content];
        }
        [_layout adjustSubviews];
        [_layout setPosition:_sidebarWidth ofDividerAtIndex:0];
    }
    for (NSNumber *kind in
         @[ @(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton) ])
        [self.window standardWindowButton:(NSWindowButton)kind.unsignedIntegerValue].hidden =
            !visible;
    if (animated) {
        [root layoutSubtreeIfNeeded];
        [CATransaction begin];
        [CATransaction setAnimationDuration:.28];
        [CATransaction
            setAnimationTimingFunction:[CAMediaTimingFunction functionWithControlPoints:
                                                                                    .22:1:.36:1]];
        __weak typeof(self) weak = self;
        [CATransaction setCompletionBlock:^{
          LTWindow *owner = weak;
          if (owner && generation == owner->_sidebarAnimationGeneration &&
              owner->_sidebarCollapsed && !owner->_sidebarRevealed)
              [owner->_sidebarHost removeFromSuperview];
        }];
        CABasicAnimation *slide =
            [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
        slide.duration = .28;
        slide.fromValue = @(previousX - NSMinX(_sidebarHost.frame));
        slide.toValue = @0;
        [_sidebarHost.layer addAnimation:slide forKey:@"sidebarSlide"];
        CABasicAnimation *position = [CABasicAnimation animationWithKeyPath:@"position"];
        position.duration = .28;
        position.fromValue = [NSValue valueWithPoint:previousPosition];
        position.toValue = [NSValue valueWithPoint:_content.layer.position];
        CABasicAnimation *bounds = [CABasicAnimation animationWithKeyPath:@"bounds"];
        bounds.duration = .28;
        bounds.fromValue = [NSValue valueWithRect:previousBounds];
        bounds.toValue = [NSValue valueWithRect:_content.layer.bounds];
        CAAnimationGroup *content = [CAAnimationGroup animation];
        content.duration = .28;
        content.animations = @[ position, bounds ];
        [_content.layer addAnimation:content forKey:@"sidebarContent"];
        [CATransaction commit];
    }
    _updatingSidebar = NO;
}
- (void)sidebarPointerMoved:(NSPoint)point {
    if (!_sidebarCollapsed || _closingWindow)
        return;
    BOOL inside = NSPointInRect(point, self.window.contentView.bounds);
    CGFloat revealEdge = 3;
    if (_sidebarHost.superview && _sidebarHost.layer.presentationLayer)
        revealEdge = MAX(revealEdge, CGRectGetMaxX(_sidebarHost.layer.presentationLayer.frame));
    if (inside && point.x <= (_sidebarRevealed ? _sidebarWidth + 6 : revealEdge)) {
        [_sidebarHideTimer invalidate];
        _sidebarHideTimer = nil;
        if (!_sidebarRevealed) {
            _sidebarRevealed = YES;
            [self updateSidebarPresentation];
        }
    } else if (_sidebarRevealed && !_sidebarHideTimer.isValid) {
        __weak typeof(self) weak = self;
        _sidebarHideTimer =
            [NSTimer scheduledTimerWithTimeInterval:.18
                                            repeats:NO
                                              block:^(NSTimer *timer) {
                                                LTWindow *owner = weak;
                                                if (!owner || owner.window.attachedSheet ||
                                                    owner->_command.window.visible ||
                                                    owner.window.inLiveResize)
                                                    return;
                                                owner->_sidebarRevealed = NO;
                                                [owner updateSidebarPresentation];
                                              }];
    }
}
- (void)split:(id)s {
    [self performCommand:_secondaryID.length ? @"closeSplit" : @"splitRight"];
}
- (void)share:(NSButton *)s {
    LTPage *p = [self activePage];
    if (!p)
        return;
    NSSharingServicePicker *picker =
        [[NSSharingServicePicker alloc] initWithItems:@[ [NSURL URLWithString:p.url] ]];
    [picker showRelativeToRect:s.bounds ofView:s preferredEdge:NSRectEdgeMinY];
}
- (void)siteInfo:(id)s {
    LTPage *p = [self activePage];
    if (!p)
        return;
    LTAlert(self.window,
            p.secure ? @"Connection is encrypted" : @"Connection is not verified as secure",
            [NSString stringWithFormat:
                          @"%@\n\n%@\nPermissions are requested when a site needs access. Lite "
                          @"never overrides certificate errors.",
                          [NSURL URLWithString:p.url].host ?: p.url,
                          p.capturing
                              ? @"Camera or microphone access is active. Close this tab to end it."
                              : @"No camera or microphone access is active."]);
}
- (void)findNext:(id)s {
    [[self activePage] find:_find.stringValue forward:YES next:YES];
}
- (void)findPrevious:(id)s {
    [[self activePage] find:_find.stringValue forward:NO next:YES];
}
- (void)closeFind:(id)s {
    _findBar.hidden = YES;
    [[self activePage] stopFinding];
    [[self activePage] focus];
}
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView
    doCommandBySelector:(SEL)selector {
    if (control == _find && selector == @selector(cancelOperation:)) {
        [self closeFind:nil];
        return YES;
    }
    return NO;
}
- (void)searchFieldDidEndSearching:(NSSearchField *)sender {
    if (NSApp.currentEvent.type == NSEventTypeKeyDown) {
        [[self activePage] stopFinding];
        return;
    }
    [self closeFind:nil];
}
- (void)media:(NSButton *)s {
    NSMenu *m = [NSMenu new];
    for (LTPage *page in self.pages) {
        if (!page.audible && !page.pictureInPicture)
            continue;
        NSMenuItem *heading = [[NSMenuItem alloc] initWithTitle:page.title
                                                         action:nil
                                                  keyEquivalent:@""];
        [m addItem:heading];
        for (NSArray *a in @[
                 @[ @"Return to Tab", @"return" ], @[ @"Play / Pause", @"play" ],
                 @[ @"Mute / Unmute", @"mute" ], @[ @"Picture in Picture", @"pip" ]
             ]) {
            NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:a[0]
                                                       action:@selector(mediaAction:)
                                                keyEquivalent:@""];
            i.target = self;
            i.representedObject = @[ page.identifier, a[1] ];
            [m addItem:i];
        }
    }
    [m popUpMenuPositioningItem:nil atLocation:NSZeroPoint inView:s];
}
- (void)mediaAction:(NSMenuItem *)i {
    LTPage *p = _pageMap[i.representedObject[0]];
    NSString *action = i.representedObject[1];
    if ([action isEqual:@"play"])
        [p togglePlayback];
    else if ([action isEqual:@"mute"])
        [p toggleMute];
    else if ([action isEqual:@"return"])
        [self selectTab:p.identifier];
    else
        [p enterPictureInPicture];
}
- (void)promote:(NSButton *)s {
    NSMenu *m = [NSMenu new];
    for (LTSpace *space in _store.profile.spaces) {
        NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:space.name
                                                   action:@selector(promoteSpace:)
                                            keyEquivalent:@""];
        i.target = self;
        i.representedObject = space.identifier;
        [m addItem:i];
    }
    [m popUpMenuPositioningItem:nil atLocation:NSZeroPoint inView:s];
}
- (void)promoteSpace:(NSMenuItem *)i {
    if (_promote)
        _promote([self activePage].url, i.representedObject);
    [self.window performClose:nil];
}
@end
