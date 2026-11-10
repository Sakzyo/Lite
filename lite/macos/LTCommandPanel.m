#import "LTCommandPanel.h"
#import "../model/LTCommandIndex.h"
#import "LTUI.h"
@interface LTCommandPanel () <NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate,
                              NSWindowDelegate>
@end
@implementation LTCommandPanel {
    LTStore *_store;
    NSSet *_openIDs;
    NSSearchField *_field;
    NSTableView *_table;
    NSArray *_results;
    __weak NSWindow *_owner;
    LTSearchSuggestions *_suggester;
    NSArray<NSString *> *_suggestions;
}
- (instancetype)initWithStore:(LTStore *)store
                      openIDs:(NSSet *)ids
                  suggestions:(LTSearchSuggestions *)suggestions {
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 650, 430)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.titleVisibility = NSWindowTitleHidden;
    panel.titlebarAppearsTransparent = YES;
    panel.movableByWindowBackground = YES;
    panel.level = NSFloatingWindowLevel;
    panel.title = @"Lite Command Bar";
    if ((self = [super initWithWindow:panel])) {
        _store = store;
        _openIDs = ids;
        _suggester = store.privateMode ? nil : suggestions;
        panel.delegate = self;
        NSVisualEffectView *root = [NSVisualEffectView new];
        root.material = NSVisualEffectMaterialPopover;
        root.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        root.state = NSVisualEffectStateActive;
        panel.contentView = root;
        _field = [NSSearchField new];
        _field.placeholderString = @"Search tabs, enter a URL, or type a command";
        _field.font = [NSFont systemFontOfSize:19 weight:NSFontWeightRegular];
        ((NSSearchFieldCell *)_field.cell).searchButtonCell = nil;
        _field.bordered = NO;
        _field.focusRingType = NSFocusRingTypeNone;
        _field.delegate = self;
        _field.accessibilityLabel = @"Search or enter address";
        NSImageView *searchIcon =
            [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"magnifyingglass"
                                                      accessibilityDescription:nil]];
        searchIcon.contentTintColor = NSColor.secondaryLabelColor;
        searchIcon.symbolConfiguration =
            [NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightRegular];
        [searchIcon.widthAnchor constraintEqualToConstant:22].active = YES;
        [searchIcon.heightAnchor constraintEqualToConstant:22].active = YES;
        NSStackView *searchRow =
            LTStack(@[ searchIcon, _field ], NSUserInterfaceLayoutOrientationHorizontal, 12);
        searchRow.edgeInsets = NSEdgeInsetsMake(0, 6, 0, 6);
        [_field setContentCompressionResistancePriority:250
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
        _table = [NSTableView new];
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:@"result"];
        [_table addTableColumn:c];
        _table.headerView = nil;
        _table.rowHeight = 52;
        _table.intercellSpacing = NSMakeSize(0, 4);
        _table.backgroundColor = NSColor.clearColor;
        _table.style = NSTableViewStyleInset;
        _table.delegate = self;
        _table.dataSource = self;
        _table.target = self;
        _table.doubleAction = @selector(choose:);
        _table.accessibilityLabel = @"Command results";
        NSScrollView *scroll = [NSScrollView new];
        scroll.documentView = _table;
        scroll.hasVerticalScroller = YES;
        scroll.autohidesScrollers = YES;
        scroll.borderType = NSNoBorder;
        scroll.drawsBackground = NO;
        NSTextField *hint =
            LTLabel(@"↑↓ Navigate     ↵ Open     Esc Close", 11, NSFontWeightRegular);
        hint.textColor = NSColor.secondaryLabelColor;
        NSStackView *stack =
            LTStack(@[ searchRow, scroll, hint ], NSUserInterfaceLayoutOrientationVertical, 12);
        LTPin(stack, root, 16);
        [searchRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
        [searchRow.heightAnchor constraintEqualToConstant:44].active = YES;
        [_field.heightAnchor constraintEqualToConstant:28].active = YES;
        [scroll.widthAnchor constraintEqualToAnchor:searchRow.widthAnchor].active = YES;
    }
    return self;
}
- (void)presentForWindow:(NSWindow *)window initial:(NSString *)text {
    _owner = window;
    NSRect frame = window.frame;
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    NSRect available = NSInsetRect(screen.visibleFrame, 16, 16);
    NSSize size = NSMakeSize(MIN(650, MIN(NSWidth(frame) - 32, NSWidth(available))),
                            MIN(430, MIN(NSHeight(frame) - 32, NSHeight(available))));
    NSPoint origin = NSMakePoint(NSMidX(frame) - size.width / 2,
                                MAX(NSMinY(frame) + 16, NSMaxY(frame) - 80 - size.height));
    origin.x = MAX(NSMinX(available), MIN(origin.x, NSMaxX(available) - size.width));
    origin.y = MAX(NSMinY(available), MIN(origin.y, NSMaxY(available) - size.height));
    [self.window setFrame:NSMakeRect(origin.x, origin.y, size.width, size.height) display:NO];
    [window addChildWindow:self.window ordered:NSWindowAbove];
    _field.stringValue = text;
    [self refresh];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:_field];
    [_field selectText:nil];
}
- (NSString *)query {
    return [_field.stringValue
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
// Rebuilds the rows. `keep` is the row to leave selected when it is still listed, so suggestions
// that arrive late do not move the selection; otherwise the first row is selected.
- (void)reloadKeeping:(NSDictionary *)keep {
    NSString *query = [self query];
    _results = LTCommandResults(query, _store.profile, [_store searchHistory:query limit:30], _openIDs,
                                _suggestions);
    [_table reloadData];
    NSUInteger row = !keep ? 0 : [_results indexOfObjectPassingTest:^BOOL(NSDictionary *r, NSUInteger i, BOOL *stop) {
        return [r[@"type"] isEqual:keep[@"type"]] && [r[@"value"] isEqual:keep[@"value"]] &&
               [r[@"title"] isEqual:keep[@"title"]];
    }];
    if (_results.count) {
        row = row == NSNotFound ? 0 : row;
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [_table scrollRowToVisible:row];
    }
}
- (void)refresh {
    NSString *query = [self query], *typed = query.lowercaseString;
    NSDictionary *settings = _store.profile.settings;
    // Suggestions that still begin with the text stay listed until the engine answers again.
    NSMutableArray *kept = [NSMutableArray new];
    for (NSString *suggestion in _suggestions)
        if (typed.length && suggestion.length > typed.length && [suggestion.lowercaseString hasPrefix:typed])
            [kept addObject:suggestion];
    _suggestions = kept;
    __weak typeof(self) weak = self;
    __block BOOL asking = YES;
    // A private window has no fetcher, so nothing typed in it is sent.
    BOOL asked = [_suggester suggest:query settings:settings completion:^(NSArray<NSString *> *suggestions) {
        LTCommandPanel *panel = weak;
        if (!panel || ![[panel query] isEqual:query])
            return;
        panel->_suggestions = suggestions;
        if (!asking) {
            NSInteger row = panel->_table.selectedRow;
            [panel reloadKeeping:row >= 0 && row < (NSInteger)panel->_results.count ? panel->_results[row] : nil];
        }
    }];
    asking = NO;
    if (!asked)
        _suggestions = @[];
    [self reloadKeeping:nil];
}
- (void)controlTextDidChange:(NSNotification *)n {
    [self refresh];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table {
    return _results.count;
}
- (NSView *)tableView:(NSTableView *)table
    viewForTableColumn:(NSTableColumn *)column
                   row:(NSInteger)row {
    NSDictionary *r = _results[row];
    NSImageView *icon =
        [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:r[@"icon"]
                                                  accessibilityDescription:nil]];
    icon.contentTintColor = NSColor.secondaryLabelColor;
    icon.symbolConfiguration =
        [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightRegular];
    [icon.widthAnchor constraintEqualToConstant:20].active = YES;
    [icon.heightAnchor constraintEqualToConstant:20].active = YES;
    NSTextField *title = LTLabel(r[@"title"], 13, NSFontWeightMedium),
                *detail = LTLabel(r[@"detail"], 12, NSFontWeightRegular);
    detail.textColor = NSColor.secondaryLabelColor;
    NSStackView *text = LTStack(@[ title, detail ], NSUserInterfaceLayoutOrientationVertical, 3);
    NSStackView *v = LTStack(@[ icon, text ], NSUserInterfaceLayoutOrientationHorizontal, 12);
    v.edgeInsets = NSEdgeInsetsMake(6, 8, 6, 8);
    [text.widthAnchor constraintEqualToAnchor:v.widthAnchor constant:-48].active = YES;
    [title.widthAnchor constraintEqualToAnchor:text.widthAnchor].active = YES;
    [detail.widthAnchor constraintEqualToAnchor:text.widthAnchor].active = YES;
    return v;
}
- (BOOL)control:(NSControl *)control textView:(NSTextView *)view doCommandBySelector:(SEL)selector {
    if (selector == @selector(moveDown:) || selector == @selector(moveUp:)) {
        NSInteger i = MAX(0, MIN((NSInteger)_results.count - 1,
                                 _table.selectedRow + (selector == @selector(moveDown:) ? 1 : -1)));
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
        [_table scrollRowToVisible:i];
        return YES;
    }
    if (selector == @selector(insertNewline:)) {
        [self choose:nil];
        return YES;
    }
    if (selector == @selector(cancelOperation:)) {
        [self close];
        return YES;
    }
    return NO;
}
- (void)choose:(id)sender {
    NSInteger row = _table.selectedRow;
    if (row < 0 || row >= (NSInteger)_results.count)
        return;
    NSDictionary *result = _results[row];
    [self close];
    if (_selected)
        _selected(result);
}
- (void)close {
    [_suggester forget];
    [_owner removeChildWindow:self.window];
    [self.window orderOut:nil];
    [_owner makeKeyWindow];
}
- (void)windowDidResignKey:(NSNotification *)n {
    [self close];
}
@end
