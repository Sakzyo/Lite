#import "LTWindow.h"
#import "../browser/LTContentBlocker.h"
#import "../migration/LTExporter.h"
#import "../migration/LTImporter.h"
#import "../model/LTFilterUpdates.h"
#import "../model/LTGitHub.h"
#import "LTCommandPanel.h"
#import "LTDownloadHistory.h"
#import "LTExtensionsPanel.h"
#import "LTFaviconCache.h"
#import "LTLibraryPanel.h"
#import "LTPasswords.h"
#import "LTSidebar.h"
#import "LTTheme.h"
#import "LTUI.h"
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface LTWindowSurface : LTBackdrop
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

// Transparent gutter around the web cards; the tinted window frame doubles as a drag handle.
@interface LTContentSurface : NSView
@end
@implementation LTContentSurface
- (void)mouseDown:(NSEvent *)event {
    [self.window performWindowDragWithEvent:event];
}
@end

@interface LTLayoutSplit : NSSplitView
@end
@implementation LTLayoutSplit
- (CGFloat)dividerThickness {
    return 1;
}
- (void)drawDividerInRect:(NSRect)rect {
}
@end

// Address field pill; secondary page actions appear while the pointer is over it.
@interface LTAddressPill : NSBox
@property (nonatomic, copy) NSArray<NSView *> *hoverViews;
@end
@implementation LTAddressPill {
    NSTrackingArea *_tracking;
    BOOL _hovered;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.boxType = NSBoxCustom;
        self.titlePosition = NSNoTitle;
        self.borderWidth = 0;
        self.cornerRadius = 10;
        self.contentViewMargins = NSZeroSize;
        [self applyFill];
    }
    return self;
}
- (void)applyFill {
    BOOL hovered = _hovered;
    self.fillColor = [NSColor colorWithName:nil
                              dynamicProvider:^NSColor *(NSAppearance *appearance) {
                                BOOL dark = LTAppearanceIsDark(appearance);
                                return [NSColor colorWithWhite:1
                                                         alpha:dark ? (hovered ? .12 : .08)
                                                                    : (hovered ? .72 : .55)];
                              }];
    for (NSView *v in _hoverViews)
        v.hidden = !hovered;
}
- (void)setHoverViews:(NSArray<NSView *> *)views {
    _hoverViews = [views copy];
    [self applyFill];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking)
        [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingInVisibleRect | NSTrackingMouseEnteredAndExited |
                     NSTrackingActiveInKeyWindow
               owner:self
            userInfo:nil];
    [self addTrackingArea:_tracking];
}
- (void)mouseEntered:(NSEvent *)event {
    _hovered = YES;
    [self applyFill];
}
- (void)mouseExited:(NSEvent *)event {
    _hovered = NO;
    [self applyFill];
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
- (CGFloat)dividerThickness {
    return 8;
}
- (void)drawDividerInRect:(NSRect)rect {
}
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
    __weak NSTextField *_filterStatus;
    __weak NSButton *_filterCheck;
    id _filterObserver;
    LTBrowserContext *_context;
    NSMutableDictionary<NSString *, LTPage *> *_pageMap;
    NSString *_spaceID;
    NSString *_activeID;
    NSString *_secondaryID;
    NSString *_focusedID;
    NSSplitView *_layout;
    LTContentSplit *_webSplit;
    NSArray<NSLayoutConstraint *> *_webInsets;
    BOOL _fullScreen;
    NSArray<LTCard *> *_cards;
    NSButton *_sidebarToggle;
    NSImageView *_logo;
    NSLayoutConstraint *_miniHeaderTop;
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
    NSButton *_address, *_back, *_forward, *_reload, *_media, *_shield, *_security, *_extensionsButton;
    NSTextField *_error;
    NSSearchField *_find;
    NSVisualEffectView *_findBar;
    LTCommandPanel *_command;
    LTSearchSuggestions *_suggestions;
    LTLibraryPanel *_library;
    LTFaviconCache *_icons;
    LTPasswords *_passwords;
    LTDownloadHistory *_downloadHistory;
    NSMutableDictionary *_sessions;
    BOOL _deferPages, _confirmingClose, _closedWindow;
    NSMutableDictionary *_visitKeys;
    BOOL _closingWindow, _restoring, _splitPending, _addressMode;
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
        if (store.privateMode) [self setDownloadHistory:[[LTDownloadHistory alloc] initWithPath:nil contextIdentifier:_context.contextIdentifier]];
        [_context updateBlockingPreferences:store.profile.settings[@"contentBlocking"]];
        _pageMap = [NSMutableDictionary new];
        _sessions = [state[@"sessions"] mutableCopy] ?: [NSMutableDictionary new];
        _deferPages = [state[@"deferPages"] boolValue];
        _splitRatio = 0.5;
        _verticalSplit = YES;
        _spaceID =
            [store.profile space:state[@"space"]] ? state[@"space"] : store.profile.activeSpaceID;
        _activeID = state[@"active"] ?: [store.profile space:_spaceID].selectedID;
        _secondaryID = state[@"secondary"] ?: @"";
        if (_deferPages) { _activeID = @""; _secondaryID = @""; }
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
          [owner->_downloadHistory performAction:a download:d];
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
- (void)setDownloadHistory:(LTDownloadHistory *)history {
    if (_downloadHistory) [NSNotificationCenter.defaultCenter removeObserver:self name:LTDownloadHistoryChanged object:_downloadHistory];
    _downloadHistory = history;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(downloadHistoryChanged:)
        name:LTDownloadHistoryChanged object:history];
}
- (void)downloadHistoryChanged:(NSNotification *)note {
    [_library updateDownloads:_downloadHistory.rows];
}
- (void)buildUI {
    LTWindowSurface *root = [LTWindowSurface new];
    root.wantsLayer = YES;
    root.layer.masksToBounds = YES;
    self.window.contentView = root;
    _back = LTButton(@"chevron.left", @"Back", self, @selector(back:));
    _forward = LTButton(@"chevron.right", @"Forward", self, @selector(forward:));
    _reload = LTButton(@"arrow.clockwise", @"Reload", self, @selector(reload:));
    _address = [NSButton buttonWithTitle:@"Search or enter address"
                                  target:self
                                  action:@selector(address:)];
    _address.bordered = NO;
    _address.font = [NSFont systemFontOfSize:13];
    _address.contentTintColor = NSColor.labelColor;
    _address.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _address.alignment = NSTextAlignmentLeft;
    _address.accessibilityLabel = @"Address";
    [_address setContentCompressionResistancePriority:250
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_address setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    _media = LTButton(@"play.rectangle", @"Media controls", self, @selector(media:));
    _shield = LTButton(@"shield.lefthalf.filled", @"Content blocking", self, @selector(contentBlocking:));
    _security =
        LTButton(@"info.circle", @"Site information and permissions", self, @selector(siteInfo:));
    _extensionsButton = LTButton(@"puzzlepiece.extension", @"Extensions", self, @selector(extensionsMenu:));
    _extensionsButton.hidden = !_extensions;
    NSButton *splitButton = LTButton(@"rectangle.split.2x1", @"Split View", self, @selector(split:));
    NSButton *shareButton = LTButton(@"square.and.arrow.up", @"Share page", self, @selector(share:));
    // Leave room for the traffic lights, then keep page navigation on the same line like Arc.
    NSView *lights = [NSView new];
    [lights.widthAnchor constraintEqualToConstant:66].active = YES;
    NSView *navigationSpace = [NSView new];
    [navigationSpace setContentHuggingPriority:1
                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSMutableArray *top = [NSMutableArray arrayWithObject:lights];
    if (!_mini) {
        _sidebarToggle = LTButton(@"sidebar.left", @"Hide sidebar", self, @selector(toggleSidebar:));
        [top addObject:_sidebarToggle];
    }
    [top addObject:navigationSpace];
    if (_store.privateMode) {
        NSTextField *badge = LTLabel(@"Private", 11, NSFontWeightSemibold);
        NSBox *capsule = [NSBox new];
        capsule.boxType = NSBoxCustom;
        capsule.titlePosition = NSNoTitle;
        capsule.borderWidth = 0;
        capsule.cornerRadius = 9;
        capsule.fillColor = [LTPaletteColor(@"Private") colorWithAlphaComponent:.35];
        capsule.contentViewMargins = NSZeroSize;
        badge.translatesAutoresizingMaskIntoConstraints = NO;
        [capsule.contentView addSubview:badge];
        [NSLayoutConstraint activateConstraints:@[
            [badge.leadingAnchor constraintEqualToAnchor:capsule.contentView.leadingAnchor constant:8],
            [badge.trailingAnchor constraintEqualToAnchor:capsule.contentView.trailingAnchor constant:-8],
            [badge.centerYAnchor constraintEqualToAnchor:capsule.contentView.centerYAnchor],
            [capsule.heightAnchor constraintEqualToConstant:18]
        ]];
        [top addObject:capsule];
    }
    [top addObjectsFromArray:@[ _back, _forward, _reload ]];
    NSStackView *navigation = LTStack(top, NSUserInterfaceLayoutOrientationHorizontal, 2);
    LTWindowDragArea *dragArea = [LTWindowDragArea new];
    LTPin(navigation, dragArea, 0);
    [dragArea.heightAnchor constraintEqualToConstant:28].active = YES;
    NSStackView *addressRow = LTStack(@[ _security, _address, _media, splitButton, shareButton, _shield, _extensionsButton ],
                                      NSUserInterfaceLayoutOrientationHorizontal, 0);
    addressRow.edgeInsets = NSEdgeInsetsMake(0, 4, 0, 4);
    LTAddressPill *addressWell = [LTAddressPill new];
    LTPin(addressRow, addressWell.contentView, 0);
    addressWell.hoverViews = @[ splitButton, shareButton ];
    NSStackView *header =
        LTStack(@[ dragArea, addressWell ], NSUserInterfaceLayoutOrientationVertical, 6);
    [dragArea.widthAnchor constraintEqualToAnchor:header.widthAnchor].active = YES;
    [addressWell.widthAnchor constraintEqualToAnchor:header.widthAnchor].active = YES;
    [addressWell.heightAnchor constraintEqualToConstant:36].active = YES;
    [_address.heightAnchor constraintEqualToConstant:28].active = YES;
    _layout = [[LTLayoutSplit alloc] initWithFrame:NSZeroRect];
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
        LTBackdrop *miniSidebar = [LTBackdrop new];
        miniSidebar.drawsBackdrop = NO;
        _sidebarHost = miniSidebar;
        NSButton *promote = [NSButton buttonWithTitle:@"Open in Lite ↗"
                                               target:self
                                               action:@selector(promote:)];
        promote.bezelStyle = NSBezelStyleRecessed;
        [header addArrangedSubview:promote];
        header.translatesAutoresizingMaskIntoConstraints = NO;
        [miniSidebar addSubview:header];
        _miniHeaderTop = [header.topAnchor constraintEqualToAnchor:miniSidebar.topAnchor constant:2];
        _miniHeaderTop.active = YES;
        [header.leadingAnchor constraintEqualToAnchor:miniSidebar.leadingAnchor constant:8]
            .active = YES;
        [header.trailingAnchor constraintEqualToAnchor:miniSidebar.trailingAnchor constant:-8]
            .active = YES;
    }
    _sidebarHost.accessibilityLabel = @"Browser sidebar";
    _sidebarHost.wantsLayer = YES;
    [_layout addSubview:_sidebarHost];
    _content = [LTContentSurface new];
    [_layout addSubview:_content];
    _content.wantsLayer = YES;
    _webSplit = [[LTContentSplit alloc] initWithFrame:NSZeroRect];
    _webSplit.vertical = _verticalSplit;
    _webSplit.delegate = self;
    _webSplit.translatesAutoresizingMaskIntoConstraints = NO;
    [_content addSubview:_webSplit];
    _webInsets = @[
        [_webSplit.leadingAnchor constraintEqualToAnchor:_content.leadingAnchor constant:8],
        [_content.trailingAnchor constraintEqualToAnchor:_webSplit.trailingAnchor constant:8],
        [_webSplit.topAnchor constraintEqualToAnchor:_content.topAnchor constant:8],
        [_content.bottomAnchor constraintEqualToAnchor:_webSplit.bottomAnchor constant:8]
    ];
    [NSLayoutConstraint activateConstraints:_webInsets];
    _cards = @[ [LTCard new], [LTCard new] ];
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
    logo.contentTintColor = NSColor.controlAccentColor;
    logo.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:40
                                                                              weight:NSFontWeightRegular];
    _logo = logo;
    [logo.widthAnchor constraintEqualToConstant:58].active = YES;
    [logo.heightAnchor constraintEqualToConstant:58].active = YES;
    NSTextField *brand =
        LTLabel(_store.privateMode ? @"A private space." : @"A little room to think.", 28,
                NSFontWeightSemibold);
    brand.alignment = NSTextAlignmentCenter;
    brand.maximumNumberOfLines = 2;
    brand.lineBreakMode = NSLineBreakByWordWrapping;
    NSTextField *hint =
        LTLabel(_store.privateMode ? @"History and cookies from this window stay temporary."
                                   : @"Your tabs, your Spaces. Everything in its place.",
                13, NSFontWeightRegular);
    hint.textColor = NSColor.secondaryLabelColor;
    hint.alignment = NSTextAlignmentCenter;
    hint.maximumNumberOfLines = 2;
    hint.lineBreakMode = NSLineBreakByWordWrapping;
    NSButton *start = [NSButton buttonWithTitle:@"Search or Enter Address"
                                         target:self
                                         action:@selector(newTab:)];
    start.bezelStyle = NSBezelStyleRounded;
    start.controlSize = NSControlSizeLarge;
    start.image = [NSImage imageWithSystemSymbolName:@"magnifyingglass"
                          accessibilityDescription:nil];
    start.imagePosition = NSImageLeft;
    NSStackView *welcome =
        LTStack(@[ logo, brand, hint, start ], NSUserInterfaceLayoutOrientationVertical, 16);
    welcome.alignment = NSLayoutAttributeCenterX;
    welcome.translatesAutoresizingMaskIntoConstraints = NO;
    [_landing addSubview:welcome];
    [NSLayoutConstraint activateConstraints:@[
        [welcome.centerXAnchor constraintEqualToAnchor:_landing.centerXAnchor],
        [welcome.centerYAnchor constraintEqualToAnchor:_landing.centerYAnchor constant:-24],
        [welcome.widthAnchor constraintLessThanOrEqualToAnchor:_landing.widthAnchor constant:-48],
        [brand.widthAnchor constraintLessThanOrEqualToAnchor:welcome.widthAnchor],
        [hint.widthAnchor constraintLessThanOrEqualToAnchor:welcome.widthAnchor]
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
    NSStackView *findControls = LTStack(
        @[
            _find, LTButton(@"chevron.up", @"Previous match", self, @selector(findPrevious:)),
            LTButton(@"chevron.down", @"Next match", self, @selector(findNext:)),
            LTButton(@"xmark", @"Close find", self, @selector(closeFind:))
        ],
        NSUserInterfaceLayoutOrientationHorizontal, 5);
    _findBar = [NSVisualEffectView new];
    _findBar.material = NSVisualEffectMaterialPopover;
    _findBar.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    _findBar.state = NSVisualEffectStateFollowsWindowActiveState;
    _findBar.hidden = YES;
    _findBar.wantsLayer = YES;
    _findBar.layer.cornerRadius = 10;
    _findBar.layer.masksToBounds = YES;
    findControls.edgeInsets = NSEdgeInsetsMake(8, 10, 8, 10);
    LTPin(findControls, _findBar, 0);
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
// Saves are queued, and `block` runs on the writer. Capture what it needs before calling; never read
// `self` or AppKit state inside it. Use then: for anything that needs the saved result in the model.
- (void)commit:(LTProfileChange)block {
    [_store commit:block completion:nil];
}
- (void)commit:(LTProfileChange)block then:(void (^)(void))next {
    LTStore *store = _store;
    __weak typeof(self) weak = self;
    [store commit:block completion:^(NSError *error) {
      if (error) {
          [store reportWriteFailure:error];
          return;
      }
      typeof(self) owner = weak;
      if (owner && !owner->_closedWindow) next();
    }];
}
- (void)storeChanged:(NSNotification *)note {
    if (_closedWindow) return;
    [_context updateBlockingPreferences:_store.profile.settings[@"contentBlocking"]];
    if (note.userInfo[LTStoreChangeQuietObserverKey] != self)
        [self refresh];
}
- (void)refresh {
    if (_closedWindow) return;
    if (![_store.profile space:_spaceID])
        _spaceID = _store.profile.activeSpaceID;
    if (!_mini && !_deferPages && ![_store.profile node:_activeID])
        _activeID = [_store.profile space:_spaceID].selectedID;
    if (!_mini && ![_store.profile node:_secondaryID])
        _secondaryID = @"";
    [_sidebar refreshSpace:_spaceID selected:_activeID];
    [self updateTheme];
    [self displayPages];
}
- (void)updateTheme {
    NSColor *tint = LTSpaceTint(_store.profile.settings, _spaceID, _store.privateMode);
    BOOL animated = self.window.visible;
    [(LTBackdrop *)self.window.contentView setTint:tint animated:animated];
    [(LTBackdrop *)_sidebarHost setTint:tint animated:animated && _sidebarHost.window];
    _logo.contentTintColor = tint;
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
    p.sessionState = _sessions[identifier];
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
    NSMutableArray *cards = [NSMutableArray new];
    for (NSUInteger i = 0; i < views.count; i++) {
        [_cards[i] host:views[i]];
        [cards addObject:_cards[i]];
    }
    if (![_webSplit.subviews isEqual:cards]) {
        for (NSView *v in [_webSplit.subviews copy])
            [v removeFromSuperview];
        for (NSView *v in cards)
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
    LTPage *previous = [self activePage];
    if (previous && ![previous.identifier isEqual:identifier])
        [previous captureSessionState:^{ [self scheduleSave]; }];
    _deferPages = NO;
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
    NSString *spaceID = _spaceID;
    double used = NSDate.date.timeIntervalSince1970;
    [_store commit:^(LTProfile *p) {
      // A write queued ahead of this one may have removed either of them.
      LTNode *selected = [p node:identifier];
      if (!selected || ![p space:spaceID])
          return;
      p.activeSpaceID = spaceID;
      [p space:spaceID].selectedID = identifier;
      selected.lastUsed = used;
    } quietFor:self completion:nil];
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
      if ([p space:identifier])
          p.activeSpaceID = identifier;
    }];
    [self scheduleSave];
}
- (void)openURL:(NSString *)url {
    [self openURL:url then:nil];
}
- (void)openURL:(NSString *)url then:(void (^)(void))next {
    if (!LTValidURL(url))
        url = LTURLFromInput(url, _store.profile.settings);
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
        if (next)
            next();
        return;
    }
    __block NSString *identifier;
    NSString *spaceID = _spaceID;
    NSString *title = [NSURL URLWithString:url].host ?: @"New Tab";
    [self commit:^(LTProfile *p) {
      identifier = [p addNode:@"temporary" title:title url:url space:spaceID parent:@""].identifier;
    } then:^{
      [self selectTab:identifier];
      if (next)
          next();
    }];
}
- (void)updateNavigation {
    LTPage *p = [self activePage];
    _back.enabled = p.canBack;
    _forward.enabled = p.canForward;
    _reload.image = [NSImage imageWithSystemSymbolName:p.loading ? @"xmark" : @"arrow.clockwise"
                              accessibilityDescription:p.loading ? @"Stop" : @"Reload"];
    _reload.toolTip = p.loading ? @"Stop loading" : @"Reload";
    _reload.accessibilityLabel = _reload.toolTip;
    _reload.enabled = p != nil;
    NSString *host = [NSURL URLWithString:p.url].host;
    _address.title = p ? host ?: p.url : @"Search or enter address";
    _security.image = [NSImage imageWithSystemSymbolName:p.secure ? @"lock.fill" : @"info.circle"
                              accessibilityDescription:@"Site information and permissions"];
    _security.enabled = p != nil;
    _address.toolTip = p.url.length ? p.url : @"Search or enter address";
    LTBlockingPolicy *policy = [LTBlockingPolicy new];
    [policy updatePreferences:_store.profile.settings[@"contentBlocking"]];
    BOOL blockingEnabled = [LTContentBlocker shared] && [policy enabledForURL:p.url ?: @""];
    _shield.image = [NSImage imageWithSystemSymbolName:blockingEnabled ? @"shield.lefthalf.filled" : @"shield.slash"
                           accessibilityDescription:@"Content blocking"];
    _shield.toolTip = blockingEnabled ? @"Content blocking on. Click to view blocked requests."
                                     : @"Content blocking off. Click to configure.";
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
- (void)page:(LTPage *)page submittedLogin:(NSDictionary *)login {
    if (_passwords && page == [self activePage] && !page.closing)
        [_passwords offerLogin:login window:self.window];
}
- (void)pageChanged:(LTPage *)page {
    if (_closedWindow) return;
    if (page.favicon)
        [_icons storeImage:page.favicon forURL:page.url];
    if (!_mini) {
        LTNode *n = [_store.profile node:page.identifier];
        if (n &&
            (![n.url isEqual:page.url] || (page.title.length && ![n.title isEqual:page.title])) &&
            LTValidURL(page.url)) {
            NSString *identifier = page.identifier, *url = page.url, *title = page.title;
            LTStore *store = _store;
            __weak typeof(self) weak = self;
            [store commit:^(LTProfile *p) {
              LTNode *n = [p node:identifier];
              n.url = url;
              if (title.length)
                  n.title = title;
            } quietFor:self completion:^(NSError *error) {
              typeof(self) owner = weak;
              if (error)
                  [store reportWriteFailure:error];
              else if (owner && !owner->_closedWindow)
                  [owner->_sidebar updateItem:identifier];
            }];
        }
    }
    // A new URL in a tab is a visit. The same URL with a new title, such as an unread count in a
    // mail page, only renames it, so it does not inflate the URL's frecency.
    NSArray *visit = @[ page.url ?: @"", page.title ?: @"" ];
    NSArray *last = _visitKeys[page.identifier];
    if (!page.loading && !page.errorText.length && ![last isEqual:visit]) {
        if ([last.firstObject isEqual:visit.firstObject])
            [_store updateVisitTitle:page.title url:page.url];
        else
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
    [self displayPages];
}
- (void)page:(LTPage *)page openURL:(NSString *)url {
    [self openURL:url];
}
- (void)page:(LTPage *)page downloadChanged:(NSDictionary *)download {
    // Shared history receives the engine notification, including popup downloads.
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
    // Created when suggestions are first wanted, and never for a private window.
    if (!_suggestions && !_store.privateMode && [_store.profile.settings[@"searchSuggestions"] isEqual:@YES])
        _suggestions = [LTSearchSuggestions new];
    _command = [[LTCommandPanel alloc] initWithStore:_store
                                             openIDs:[NSSet setWithArray:_pageMap.allKeys]
                                         suggestions:_suggestions];
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
    if ([command isEqual:@"contentBlocking"]) {
        [self contentBlocking:nil];
    } else if ([command isEqual:@"newTab"]) {
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
          } then:^{
            [self selectSpace:sid];
          }];
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
                    NSString *sid = self->_spaceID;
                    [self commit:^(LTProfile *p) {
                      [p space:sid].name = name;
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
                      NSDictionary *themes = p.settings[@"spaceThemes"];
                      if ([themes isKindOfClass:NSDictionary.class] && themes[sid]) {
                          NSMutableDictionary *kept = [themes mutableCopy];
                          [kept removeObjectForKey:sid];
                          p.settings[@"spaceThemes"] = kept;
                      }
                    }];
                  });
    } else if ([command isEqual:@"newFolder"] || [command isEqual:@"folderInside"]) {
        NSString *parent = [command isEqual:@"folderInside"] ? identifier : @"";
        LTAskName(self.window, @"New Folder", @"", ^(NSString *name) {
          NSString *sid = self->_spaceID;
          [self commit:^(LTProfile *p) {
            [p addNode:@"folder" title:name url:@"" space:sid parent:parent];
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
        NSString *title = node.displayTitle, *url = node.url;
        [self commit:^(LTProfile *p) {
          [p addNode:@"favorite" title:title url:url space:@"" parent:@""];
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
    else if ([command isEqual:@"reopenTab"])
        [self reopenClosedTab];
    else if ([command isEqual:@"reopenWindow"])
        [NSNotificationCenter.defaultCenter postNotificationName:@"LTAppCommand" object:command];
    else if ([command isEqual:@"splitRight"] || [command isEqual:@"splitDown"]) {
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
        NSString *target = [[self activePage].identifier isEqual:_secondaryID] ? _activeID : _secondaryID;
        [_pageMap[target] focus];
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
             [command isEqual:@"settings"]) {
        [_library showMode:command owner:self.window downloads:_downloadHistory.rows];
        if ([command isEqual:@"downloads"] && _downloadHistory.saveError.length)
            LTAlert(_library.window, @"Download history could not be saved", _downloadHistory.saveError);
    } else if ([command isEqual:@"importArc"])
        [self importArc];
    else if ([command isEqual:@"importBookmarks"])
        [self importBookmarks];
    else if ([command isEqual:@"exportBookmarks"] || [command isEqual:@"exportOrganization"])
        [self exportData:[command isEqual:@"exportBookmarks"]];
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
        if (_store.privateMode) {
            LTConfirm(self.window, @"Clear this private window’s website data?", @"This closes every page and popup using this private context, ends downloads and capture, and discards unsaved website work. A fresh private window opens with separate, empty storage. Regular windows and other private windows are unchanged.", @"Clear Private Data", ^{
                self->_closingWindow = YES;
                [self->_context closeAllBrowsersConfirmed];
                BOOL alive = NO;
                for (LTPage *page in self.pages) alive |= page.alive;
                if (!alive) [self.window close];
                [NSNotificationCenter.defaultCenter postNotificationName:@"LTAppCommand" object:@"newPrivate"];
            });
        } else [NSNotificationCenter.defaultCenter postNotificationName:@"LTClearAllWebsiteData" object:self];
    } else if ([command isEqual:@"extensions"]) {
        if (_extensions)
            [NSNotificationCenter.defaultCenter postNotificationName:@"LTAppCommand" object:command];
        else
            LTAlert(self.window, @"Extensions are off in private windows",
                    @"Extensions run only in regular windows, so they cannot see private browsing. "
                    @"Manage them from a regular Lite window.");
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
        [self.store commit:^(LTProfile *profile) {
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
        } completion:^(NSError *saveError) {
            if (saveError) LTAlert(self.window, @"Could not save Live Folder", saveError.localizedDescription);
            else [self.github refreshFolder:folderID];
        }];
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
        LTConfirm(self.window, @"Close this page?", @"This page may contain unsaved work that will be lost.",
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
// Reopens the most recently closed tab into this window's Space. The list is shared by every regular
// window and survives quitting; a private window has its own, which ends with the window.
- (void)reopenClosedTab {
    NSDictionary *entry = [_store.profile latestClosed:@"tab"];
    if (!entry) {
        NSBeep();
        return;
    }
    NSString *entryID = entry[@"id"], *spaceID = _spaceID;
    __block NSString *reopened = nil;
    [self commit:^(LTProfile *p) {
      // Another window, or a quick second press, may have taken it first.
      if (![p space:spaceID]) return;
      NSDictionary *taken = [p takeClosed:entryID];
      if (!taken) return;
      LTNode *n = [LTNode fromJSON:taken[@"node"]];
      n.parentID = @"";
      n.spaceID = spaceID;
      if ([p node:n.identifier])
          n.identifier = LTUUID();
      [p.nodes addObject:n];
      reopened = n.identifier;
    } then:^{
      if (reopened) [self selectTab:reopened];
    }];
}
- (void)completeClose:(NSString *)identifier {
    LTNode *n = [_store.profile node:identifier];
    if (!n)
        return;
    _pageMap[identifier].visible = NO;
    if ([_activeID isEqual:identifier]) {
        _activeID = _secondaryID.length ? _secondaryID : @"";
        _secondaryID = @"";
    } else if ([_secondaryID isEqual:identifier])
        _secondaryID = @"";
    BOOL temporary = [n.kind isEqual:@"temporary"];
    NSString *spaceID = _spaceID, *activeID = _activeID;
    double closedAt = NSDate.date.timeIntervalSince1970;
    [self commit:^(LTProfile *p) {
      if (temporary) {
          // Read on the writer, so the tab is recorded at the address its last queued save gave it.
          LTNode *closed = [p node:identifier];
          if (closed) [p noteClosedTab:closed time:closedAt];
          [p removeNode:identifier];
      }
      if (!activeID.length || [p node:activeID])
          [p space:spaceID].selectedID = activeID;
    }];
    if (temporary)
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
                    NSString *spaceID = self->_spaceID;
                    [self->_store
                        commit:^(LTProfile *p) {
                          LTNode *n = [p node:identifier];
                          if (folder && [n.kind isEqual:@"temporary"]) {
                              n.kind = @"pinned";
                              n.pinnedURL = n.url;
                          }
                          [p moveNode:identifier
                                space:folder ? spaceID : destination
                               parent:folder ? destination : @""
                                index:NSIntegerMax
                                error:nil];
                        }
                        completion:^(NSError *e) {
                          if (e)
                              LTAlert(self.window, @"Move failed", e.localizedDescription);
                        }];
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
                } then:^{
                  [self selectSpace:result.profile.activeSpaceID];
                }];
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
    p.message = @"Choose an HTML bookmarks export, Chromium Bookmarks JSON, Safari Bookmarks.plist, "
                @"or a Lite organization file.";
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
// Writes the committed sidebar to a file the user chooses: a bookmarks file other browsers import,
// or a Lite organization file. The profile is an immutable snapshot, so it is written off the main
// thread.
- (void)exportData:(BOOL)bookmarks {
    if (_store.privateMode) {
        LTAlert(self.window, @"Export from a regular window",
                @"This private window has its own temporary sidebar. Open a regular Lite window to "
                @"export your bookmarks and organization.");
        return;
    }
    NSDateFormatter *day = [NSDateFormatter new];
    day.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    day.dateFormat = @"yyyy-MM-dd";
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[ bookmarks ? UTTypeHTML : UTTypeJSON ];
    panel.nameFieldStringValue =
        [NSString stringWithFormat:@"Lite %@ %@.%@", bookmarks ? @"Bookmarks" : @"Organization",
                                   [day stringFromDate:NSDate.date], bookmarks ? @"html" : @"json"];
    panel.message = bookmarks ? @"Favorites and each Space’s folders and pinned tabs, for Safari, "
                                @"Chrome, Firefox and other browsers. Temporary tabs are not included."
                              : @"Spaces, their colors, folders, pinned tabs and Favorites, to import "
                                @"into Lite on this or another Mac. Temporary tabs are not included.";
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
                    if (response != NSModalResponseOK)
                        return;
                    NSURL *url = panel.URL;
                    LTProfile *profile = self->_store.profile;
                    NSDate *now = NSDate.date;
                    __weak LTWindow *weak = self;
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                      NSData *data = bookmarks ? [LTExporter bookmarksHTML:profile]
                                               : [LTExporter organizationJSON:profile date:now];
                      NSError *e = nil;
                      if ([data writeToURL:url options:NSDataWritingAtomic error:&e])
                          return;
                      dispatch_async(dispatch_get_main_queue(), ^{
                        LTAlert(weak.window, @"Export failed",
                                e.localizedDescription ?: @"The file could not be written.");
                      });
                    });
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
    for (LTPage *page in self.pages) {
        if (page.sessionState && (_sessions[page.identifier] || _sessions.count < 128)) _sessions[page.identifier] = page.sessionState;
        else if (!page.sessionState) [_sessions removeObjectForKey:page.identifier];
    }
    for (NSString *identifier in [_sessions.allKeys copy])
        if (![_store.profile node:identifier]) [_sessions removeObjectForKey:identifier];
    return @{
        @"space" : _spaceID ?: @"",
        @"active" : _activeID ?: @"",
        @"secondary" : _secondaryID ?: @"",
        @"vertical" : @(_verticalSplit),
        @"ratio" : @(_splitRatio),
        @"sidebarCollapsed" : @(_sidebarCollapsed),
        @"sidebarWidth" : @(_sidebarWidth),
        @"frame" : NSStringFromRect(self.window.frame),
        @"sessions" : [_sessions copy]
    };
}
- (void)captureSessionStates:(void (^)(void))completion {
    NSArray<LTPage *> *pages = self.pages;
    if (!pages.count) { completion(); return; }
    __block NSUInteger remaining = pages.count;
    for (LTPage *page in pages) [page captureSessionState:^{ if (--remaining == 0) completion(); }];
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
    NSUInteger alive = 0;
    for (LTPage *p in self.pages)
        alive += p.alive;
    if (!alive)
        return YES;
    if (_closingWindow || _confirmingClose) return NO;
    if (alive > 1 || [self.pages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(LTPage *page, NSDictionary *bindings) { return page.downloading || page.capturing; }]].count) {
        _confirmingClose = YES;
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Close every page in this window?";
        alert.informativeText = [NSString stringWithFormat:@"This closes %lu loaded pages and ends their downloads, media and capture. Unsaved page work will be lost. Cancel keeps every page open.", (unsigned long)alive];
        [alert addButtonWithTitle:@"Cancel"];
        [alert addButtonWithTitle:@"Close All Pages"];
        [alert beginSheetModalForWindow:sender completionHandler:^(NSModalResponse result) {
            self->_confirmingClose = NO;
            if (result != NSAlertSecondButtonReturn) return;
            [self captureSessionStates:^{
                self->_closingWindow = YES;
                for (LTPage *page in self.pages) [page closeConfirmed];
            }];
        }];
        return NO;
    }
    _closingWindow = YES;
    for (LTPage *p in self.pages) {
        p.visible = NO;
        [p close];
    }
    return NO;
}
- (void)windowWillClose:(NSNotification *)n {
    _closedWindow = YES;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_downloadHistory flush];
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
- (void)windowWillEnterFullScreen:(NSNotification *)n {
    [self setFullScreenChrome:YES];
}
- (void)windowWillExitFullScreen:(NSNotification *)n {
    [self setFullScreenChrome:NO];
}
// Transitions can fail or be cut short (for example when the app deactivates midway),
// so settle on the window's actual state once AppKit reports the outcome.
- (void)windowDidEnterFullScreen:(NSNotification *)n {
    [self syncFullScreenChrome];
}
- (void)windowDidFailToEnterFullScreen:(NSWindow *)window {
    [self syncFullScreenChrome];
}
- (void)windowDidExitFullScreen:(NSNotification *)n {
    [self syncFullScreenChrome];
}
- (void)windowDidFailToExitFullScreen:(NSWindow *)window {
    [self syncFullScreenChrome];
}
- (void)syncFullScreenChrome {
    [self setFullScreenChrome:(self.window.styleMask & NSWindowStyleMaskFullScreen) != 0];
}
// Full screen drops the tinted frame so pages run edge to edge.
- (void)setFullScreenChrome:(BOOL)fullScreen {
    _fullScreen = fullScreen;
    for (NSLayoutConstraint *inset in _webInsets)
        inset.constant = fullScreen ? 0 : 8;
    for (LTCard *card in _cards)
        card.flush = fullScreen;
    [self updateWindowButtons];
}
// Collapsed sidebars hide the traffic lights with the header row. In full screen the
// system titlebar reveals them on demand, so they must stay available there.
- (void)updateWindowButtons {
    BOOL hidden = !_fullScreen && _sidebarCollapsed && !_sidebarRevealed;
    for (NSNumber *kind in
         @[ @(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton) ])
        [self.window standardWindowButton:(NSWindowButton)kind.unsignedIntegerValue].hidden =
            hidden;
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
- (NSRect)splitView:(NSSplitView *)v
         effectiveRect:(NSRect)proposed
          forDrawnRect:(NSRect)drawn
      ofDividerAtIndex:(NSInteger)index {
    return v == _layout ? NSInsetRect(drawn, -4, 0) : proposed;
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
    // Collapsed sidebars float as an inset panel, Arc-style, and slide fully off-screen.
    CGFloat hiddenX = -(_sidebarWidth + 16);
    CGFloat previousX =
        _sidebarHost.superview ? CGRectGetMinX(sidebarPresentation.frame) : hiddenX;
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
            _sidebarHost.frame = NSMakeRect(visible ? 6 : hiddenX, 6, _sidebarWidth,
                                            MAX(0, root.bounds.size.height - 12));
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
    ((LTBackdrop *)_sidebarHost).floating = _sidebarCollapsed;
    _miniHeaderTop.constant = _sidebarCollapsed ? -4 : 2;
    _sidebarToggle.toolTip = _sidebarCollapsed ? @"Keep sidebar open" : @"Hide sidebar";
    _sidebarToggle.accessibilityLabel = _sidebarToggle.toolTip;
    [self updateWindowButtons];
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
    if (inside && point.x <= (_sidebarRevealed ? _sidebarWidth + 12 : revealEdge)) {
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
- (void)setExtensions:(LTExtensions *)extensions {
    _extensions = extensions;
    _extensionsButton.hidden = !extensions;
}
- (void)extensionsMenu:(NSButton *)sender {
    NSMenu *menu = [NSMenu new];
    NSMenuItem *(^add)(NSString *, NSArray *) = ^NSMenuItem *(NSString *title, NSArray *action) {
        NSMenuItem *item = [menu addItemWithTitle:title action:action ? @selector(extensionItem:) : nil keyEquivalent:@""];
        item.target = self;
        item.representedObject = action;
        item.keyEquivalentModifierMask = 0;
        return item;
    };
    NSString *storeID = LTWebStoreExtensionID([self activePage].url ?: @"");
    if (storeID && ![_extensions extensionWithIdentifier:storeID]) {
        add(@"Add This Extension to Lite…", @[ @"install", storeID ]);
        [menu addItem:NSMenuItem.separatorItem];
    }
    for (LTExtension *extension in _extensions.launched) {
        NSString *kind = extension.popup ? @"popup" : extension.options ? @"options" : nil;
        NSMenuItem *item = add(extension.name, kind ? @[ kind, extension.identifier ] : nil);
        item.image = LTExtensionIcon(extension);
        if (!kind) item.toolTip = @"This extension has no popup or options page.";
        if (extension.popup && extension.options) {
            NSMenuItem *options = add([extension.name stringByAppendingString:@" Options"], @[ @"options", extension.identifier ]);
            options.image = item.image;
            options.alternate = YES;
            options.keyEquivalentModifierMask = NSEventModifierFlagOption;
        }
    }
    if (!_extensions.launched.count) add(@"No Extensions Running", nil);
    [menu addItem:NSMenuItem.separatorItem];
    if (_extensions.restartRequired) add(@"Restart to Apply Extension Changes…", @[ @"restart" ]);
    add(@"Manage Extensions…", @[ @"manage" ]);
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height + 4) inView:sender];
}
- (void)extensionItem:(NSMenuItem *)item {
    NSArray *action = item.representedObject;
    NSString *kind = action.firstObject;
    // Running extensions keep their launch-time pages until restart, even if removed or updated since.
    LTExtension *extension = nil;
    for (LTExtension *launched in _extensions.launched)
        if (action.count > 1 && [launched.identifier isEqual:action[1]]) extension = launched;
    if ([kind isEqual:@"install"])
        [NSNotificationCenter.defaultCenter postNotificationName:@"LTAppCommand" object:@"extensions"
                                                        userInfo:@{@"install" : action[1]}];
    else if ([kind isEqual:@"manage"])
        [NSNotificationCenter.defaultCenter postNotificationName:@"LTAppCommand" object:@"extensions"];
    else if ([kind isEqual:@"restart"])
        [NSNotificationCenter.defaultCenter postNotificationName:@"LTRestart" object:nil];
    else if ([kind isEqual:@"popup"] && extension.popup)
        [self showExtensionPopup:extension];
    else if ([kind isEqual:@"options"] && extension.options)
        [self openURL:[extension URLForPage:extension.options]];
}
- (NSPopover *)showExtensionPopup:(LTExtension *)extension {
    __weak typeof(self) weak = self;
    return LTShowExtensionPopup(extension, _context, _extensionsButton, ^(NSString *url) { [weak openURL:url]; });
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
    NSString *pageURL = [p.url copy];
    NSURLComponents *parts = [NSURLComponents componentsWithString:p.url];
    parts.user = nil; parts.password = nil; parts.path = @""; parts.query = nil; parts.fragment = nil;
    NSString *origin = parts.host.length ? parts.string : p.url;
    NSMutableString *details = [NSMutableString stringWithFormat:@"%@%@\n\nSaved site permissions apply until revoked. Camera and microphone grants apply to the capture request. macOS privacy controls still apply.\n", origin, _store.privateMode ? @"\nPrivate window" : @""];
    for (NSDictionary *grant in p.permissionGrants)
        [details appendFormat:@"\n%@: %@", grant[@"origin"], [grant[@"capabilities"] componentsJoinedByString:@", "]];
    if (!p.permissionGrants.count) [details appendString:@"\nNo active grants."];
    NSAlert *alert = [NSAlert new];
    alert.messageText = p.secure ? @"Connection is encrypted" : @"Connection is not verified as secure";
    alert.informativeText = details;
    [alert addButtonWithTitle:@"Done"];
    [alert addButtonWithTitle:@"Revoke Permissions"];
    [alert addButtonWithTitle:@"Clear This Site’s Data…"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if ((result == NSAlertSecondButtonReturn || result == NSAlertThirdButtonReturn) && ![p.url isEqual:pageURL]) {
            LTAlert(self.window, @"The page changed", @"Open Site Information again for the current page. No permissions or website data were changed.");
            return;
        }
        if (result == NSAlertSecondButtonReturn) [p revokePermissions];
        if (result == NSAlertThirdButtonReturn) {
            LTConfirm(self.window, @"Clear this origin’s website data?", [NSString stringWithFormat:@"%@\nThis removes cookies, local storage, IndexedDB, service workers and Cache Storage for this origin, and resets its grants. Shared HTTP cache is also cleared. Reload open pages afterward to drop in-memory data. Saved passwords and bookmarks are kept.", origin], @"Clear Site Data", ^{
                if (![p.url isEqual:pageURL]) {
                    LTAlert(self.window, @"The page changed", @"No website data was changed. Open Site Information again for the current page.");
                    return;
                }
                [p clearSiteDataWithCompletion:^(BOOL success, NSString *message) {
                    LTAlert(self.window, success ? @"Website data cleared" : @"Could not finish clearing website data", message);
                }];
            });
        }
    }];
}
- (void)contentBlocking:(id)sender {
    LTContentBlocker *blocker = [LTContentBlocker shared];
    if (!blocker) {
        LTAlert(self.window, @"Content blocking is unavailable", @"The bundled filter data could not be loaded. Rebuild Lite to restore it.");
        return;
    }
    LTPage *page = [self activePage];
    NSURL *url = [NSURL URLWithString:page.url ?: @""];
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    NSDictionary *prefs = _store.profile.settings[@"contentBlocking"] ?: @{};
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Content blocking";
    alert.informativeText = [NSString stringWithFormat:
        @"%@\n%lu requests blocked on this page.\n\nUses %lu native rules from uBlock Origin Lite %@%@. "
        @"Changes apply to new page loads; Apply reloads this page. Custom Filters saves these switches before opening the editor.%@",
        host.length ? host : @"No website selected", (unsigned long)page.blockedRequests,
        (unsigned long)[blocker.provenance[@"networkRules"] unsignedIntegerValue], blocker.provenance[@"version"],
        LTFilterSerialDate(blocker.serial) ? [@", published " stringByAppendingString:LTFilterSerialDate(blocker.serial)] : @"",
        _store.privateMode ? @" Private-window settings are temporary." : @""];
    NSButton *enabled = [NSButton checkboxWithTitle:@"Block ads and trackers" target:nil action:nil];
    enabled.state = ![prefs[@"disabled"] boolValue];
    NSButton *cosmetic = [NSButton checkboxWithTitle:@"Hide advertising elements" target:nil action:nil];
    cosmetic.state = ![prefs[@"cosmeticDisabled"] boolValue];
    NSButton *site = [NSButton checkboxWithTitle:@"Pause blocking on this hostname" target:nil action:nil];
    site.state = [prefs[@"disabledSites"] containsObject:host];
    site.enabled = host.length && ([@[@"http", @"https"] containsObject:url.scheme.lowercaseString]);
    LTFilterUpdater *updater = LTFilterUpdater.shared;
    NSTextField *details = LTLabel([@"Built-in filters: uBlock, EasyList, EasyPrivacy, Peter Lowe’s,\nuBlock Badware, and URLhaus.\n\nThis native subset excludes scriptlets, redirects, regex rules,\nheader changes, and procedural cosmetic filters."
        stringByAppendingString:updater ? @"" : @"\nThis build updates filters only with new versions of Lite."], 11, NSFontWeightRegular);
    details.maximumNumberOfLines = 0;
    details.textColor = NSColor.secondaryLabelColor;
    NSMutableArray *rows = [@[enabled, cosmetic, site] mutableCopy];
    NSButton *automatic = nil;
    if (updater) {
        automatic = [NSButton checkboxWithTitle:@"Update filters automatically" target:nil action:nil];
        automatic.state = ![prefs[@"updatesDisabled"] boolValue];
        // Updates are shared by every window, so only a regular window's profile decides them.
        automatic.enabled = !_store.privateMode;
        NSButton *check = [NSButton buttonWithTitle:@"Check Now" target:self action:@selector(checkFilterUpdates:)];
        check.enabled = !updater.checking;
        NSTextField *status = LTLabel([self filterStatusText], 11, NSFontWeightRegular);
        status.maximumNumberOfLines = 0;
        status.textColor = NSColor.secondaryLabelColor;
        status.accessibilityLabel = @"Filter update status";
        _filterStatus = status;
        _filterCheck = check;
        [rows addObject:automatic];
        [rows addObject:LTStack(@[status, check], NSUserInterfaceLayoutOrientationHorizontal, 10)];
        __weak LTWindow *weak = self;
        if (_filterObserver) [NSNotificationCenter.defaultCenter removeObserver:_filterObserver];
        _filterObserver = [NSNotificationCenter.defaultCenter addObserverForName:LTFilterUpdatesChanged object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                LTWindow *strong = weak;
                if (!strong) return;
                strong->_filterStatus.stringValue = [strong filterStatusText];
                strong->_filterCheck.enabled = YES;
            }];
    }
    [rows addObject:details];
    NSStackView *options = LTStack(rows, NSUserInterfaceLayoutOrientationVertical, 12);
    options.frame = NSMakeRect(0, 0, 440, updater ? 260 : 200);
    [options.widthAnchor constraintEqualToConstant:440].active = YES;
    alert.accessoryView = options;
    [alert addButtonWithTitle:@"Apply and Reload"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Custom Filters…"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        BOOL siteSettable = site.enabled, siteDisabled = site.state == NSControlStateValueOn;
        BOOL blockingOn = enabled.state == NSControlStateValueOn, cosmeticOn = cosmetic.state == NSControlStateValueOn;
        BOOL updatesSettable = automatic.enabled, updatesOn = automatic.state == NSControlStateValueOn;
        if (self->_filterObserver) [NSNotificationCenter.defaultCenter removeObserver:self->_filterObserver];
        self->_filterObserver = nil;
        BOOL editFilters = response == NSAlertThirdButtonReturn;
        if (response != NSAlertFirstButtonReturn && !editFilters) return; // Cancel changes nothing and does not reload.
        [self commit:^(LTProfile *profile) {
            NSMutableDictionary *updated = [profile.settings[@"contentBlocking"] mutableCopy] ?: [NSMutableDictionary new];
            NSMutableSet *sites = [NSMutableSet setWithArray:updated[@"disabledSites"] ?: @[]];
            if (siteSettable) {
                if (siteDisabled) [sites addObject:host];
                else [sites removeObject:host];
            }
            updated[@"disabled"] = @(!blockingOn);
            updated[@"cosmeticDisabled"] = @(!cosmeticOn);
            updated[@"disabledSites"] = [sites.allObjects sortedArrayUsingSelector:@selector(compare:)];
            if (updatesSettable) updated[@"updatesDisabled"] = @(!updatesOn);
            profile.settings[@"contentBlocking"] = updated;
        } then:^{
            if (editFilters)
                [self editCustomFilters:self->_store.profile.settings[@"contentBlocking"][@"customFilters"] ?: @"" problem:nil];
            else [page reload];
        }];
    }];
}
- (void)editCustomFilters:(NSString *)draft problem:(NSString *)problem {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Custom network filters";
    alert.informativeText = [NSString stringWithFormat:@"%@One URL pattern per line. Use ||ads.example^ to block a host’s requests, "
        @"@@||ads.example/needed.js to allow a request, and ! for comments. *, ^, and | anchors are supported; "
        @"options, regexes and cosmetic filters are not. Page navigation is not blocked.\n\n"
        @"Up to 1,000 rules, 2,048 characters per line and 256 KiB total.%@",
        problem.length ? [problem stringByAppendingString:@"\n\n"] : @"",
        _store.privateMode ? @" Changes stay in this private window." : @" Saved locally in your profile."];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 480, 180)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSTextView *editor = [[NSTextView alloc] initWithFrame:scroll.bounds];
    editor.richText = NO;
    editor.automaticQuoteSubstitutionEnabled = NO;
    editor.automaticDashSubstitutionEnabled = NO;
    editor.automaticTextReplacementEnabled = NO;
    editor.automaticSpellingCorrectionEnabled = NO;
    editor.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    editor.textContainerInset = NSMakeSize(8, 8);
    editor.autoresizingMask = NSViewWidthSizable;
    editor.textContainer.widthTracksTextView = YES;
    editor.accessibilityLabel = @"Custom network filters";
    editor.string = draft;
    scroll.documentView = editor;
    alert.accessoryView = scroll;
    [alert addButtonWithTitle:@"Apply and Reload"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSString *text = [editor.string copy];
        NSError *error = nil;
        if (!LTValidateCustomFilters(text, &error)) {
            // Keep the draft available for correction as well as preserving the saved rules.
            [self editCustomFilters:text problem:error.localizedDescription];
            return;
        }
        LTPage *page = [self activePage];
        [self commit:^(LTProfile *profile) {
            NSMutableDictionary *preferences = [profile.settings[@"contentBlocking"] mutableCopy] ?: [NSMutableDictionary new];
            preferences[@"customFilters"] = text;
            profile.settings[@"contentBlocking"] = preferences;
        } then:^{ [page reload]; }];
    }];
    [alert.window makeFirstResponder:editor];
}
- (NSString *)filterStatusText {
    LTFilterUpdater *updater = LTFilterUpdater.shared;
    if (updater.checking) return @"Checking for filter updates…";
    if (updater.lastCheck <= 0) return @"Not checked yet.";
    NSString *when = [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:updater.lastCheck]
                                                    dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
    return [NSString stringWithFormat:@"Last checked %@: %@", when, updater.lastResult];
}
- (void)checkFilterUpdates:(NSButton *)sender {
    sender.enabled = NO;
    [LTFilterUpdater.shared updateFilters];
    _filterStatus.stringValue = [self filterStatusText];
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
