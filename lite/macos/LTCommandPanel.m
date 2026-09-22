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
}
- (instancetype)initWithStore:(LTStore *)store openIDs:(NSSet *)ids {
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
        panel.delegate = self;
        NSVisualEffectView *root = [NSVisualEffectView new];
        root.material = NSVisualEffectMaterialPopover;
        root.state = NSVisualEffectStateActive;
        panel.contentView = root;
        _field = [NSSearchField new];
        _field.placeholderString = @"Search tabs, enter a URL, or type a command";
        _field.font = [NSFont systemFontOfSize:20 weight:NSFontWeightRegular];
        ((NSSearchFieldCell *)_field.cell).searchButtonCell = nil;
        _field.bordered = NO;
        _field.focusRingType = NSFocusRingTypeNone;
        _field.delegate = self;
        _field.accessibilityLabel = @"Search or enter address";
        NSImageView *searchIcon =
            [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"magnifyingglass"
                                                      accessibilityDescription:nil]];
        searchIcon.contentTintColor = NSColor.secondaryLabelColor;
        [searchIcon.widthAnchor constraintEqualToConstant:22].active = YES;
        [searchIcon.heightAnchor constraintEqualToConstant:22].active = YES;
        NSStackView *searchRow =
            LTStack(@[ searchIcon, _field ], NSUserInterfaceLayoutOrientationHorizontal, 12);
        [_field setContentCompressionResistancePriority:250
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
        _table = [NSTableView new];
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:@"result"];
        [_table addTableColumn:c];
        _table.headerView = nil;
        _table.rowHeight = 50;
        _table.intercellSpacing = NSMakeSize(0, 2);
        _table.backgroundColor = NSColor.clearColor;
        _table.style = NSTableViewStyleFullWidth;
        _table.delegate = self;
        _table.dataSource = self;
        _table.target = self;
        _table.doubleAction = @selector(choose:);
        _table.accessibilityLabel = @"Command results";
        NSScrollView *scroll = [NSScrollView new];
        scroll.documentView = _table;
        scroll.hasVerticalScroller = YES;
        scroll.drawsBackground = NO;
        NSTextField *hint =
            LTLabel(@"↑ ↓ to navigate     ↵ to open     esc to dismiss", 11, NSFontWeightRegular);
        hint.textColor = NSColor.secondaryLabelColor;
        NSStackView *stack =
            LTStack(@[ searchRow, scroll, hint ], NSUserInterfaceLayoutOrientationVertical, 14);
        stack.edgeInsets = NSEdgeInsetsMake(12, 12, 8, 12);
        LTPin(stack, root, 14);
        [searchRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-24].active = YES;
        [searchRow.heightAnchor constraintEqualToConstant:40].active = YES;
        [_field.heightAnchor constraintEqualToConstant:28].active = YES;
        [scroll.widthAnchor constraintEqualToAnchor:searchRow.widthAnchor].active = YES;
    }
    return self;
}
- (void)presentForWindow:(NSWindow *)window initial:(NSString *)text {
    _owner = window;
    NSRect frame = window.frame;
    [self.window setFrameOrigin:NSMakePoint(NSMidX(frame) - 325, NSMaxY(frame) - 520)];
    [window addChildWindow:self.window ordered:NSWindowAbove];
    _field.stringValue = text;
    [self refresh];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:_field];
    [_field selectText:nil];
}
- (void)refresh {
    NSString *query = [_field.stringValue
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    _results = LTCommandResults(query, _store.profile,
                                [_store history:query limit:30 exact:query.length > 0], _openIDs);
    [_table reloadData];
    if (_results.count)
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
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
    [icon.widthAnchor constraintEqualToConstant:24].active = YES;
    NSTextField *title = LTLabel(r[@"title"], 13, NSFontWeightMedium),
                *detail = LTLabel(r[@"detail"], 11, NSFontWeightRegular);
    detail.textColor = NSColor.secondaryLabelColor;
    NSStackView *text = LTStack(@[ title, detail ], NSUserInterfaceLayoutOrientationVertical, 3);
    NSStackView *v = LTStack(@[ icon, text ], NSUserInterfaceLayoutOrientationHorizontal, 12);
    v.edgeInsets = NSEdgeInsetsMake(4, 10, 4, 10);
    [title.widthAnchor constraintLessThanOrEqualToConstant:520].active = YES;
    [detail.widthAnchor constraintLessThanOrEqualToConstant:520].active = YES;
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
    [_owner removeChildWindow:self.window];
    [self.window orderOut:nil];
    [_owner makeKeyWindow];
}
- (void)windowDidResignKey:(NSNotification *)n {
    [self close];
}
@end
