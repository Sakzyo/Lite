#import "LTSidebar.h"
#import "LTUI.h"

static BOOL Dark(NSView *view) {
    return LTAppearanceIsDark(view.effectiveAppearance);
}
static NSColor *Wash(NSView *view, CGFloat light, CGFloat dark) {
    return [NSColor colorWithWhite:1 alpha:Dark(view) ? dark : light];
}
static NSTrackingArea *Track(NSView *view, NSTrackingArea *old) {
    if (old)
        [view removeTrackingArea:old];
    NSTrackingArea *area = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingInVisibleRect | NSTrackingMouseEnteredAndExited |
                     NSTrackingActiveInActiveApp
               owner:view
            userInfo:nil];
    [view addTrackingArea:area];
    return area;
}
static void FillRounded(NSRect rect, CGFloat radius, NSColor *color, BOOL lifted) {
    [NSGraphicsContext saveGraphicsState];
    if (lifted) {
        NSShadow *shadow = [NSShadow new];
        shadow.shadowColor = [NSColor colorWithWhite:0 alpha:.14];
        shadow.shadowBlurRadius = 2;
        shadow.shadowOffset = NSMakeSize(0, -.5);
        [shadow set];
    }
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
    [NSGraphicsContext restoreGraphicsState];
}

@interface LTSidebarCell : NSTableCellView
@property NSButton *closeButton;
@property NSLayoutConstraint *closeWidth;
@property BOOL accessoryAlwaysVisible;
@end
@implementation LTSidebarCell
@end

// Arc-style rows: a rounded, lifted card for the selected tab and a soft hover wash.
@interface LTSidebarRowView : NSTableRowView
@property (nonatomic) BOOL hovered;
@property (nonatomic) BOOL hoverable;
@property (nonatomic) CGFloat pillTop;
- (void)updateAccessory;
@end
@implementation LTSidebarRowView {
    NSTrackingArea *_tracking;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    _tracking = Track(self, _tracking);
}
- (void)mouseEntered:(NSEvent *)event {
    self.hovered = YES;
}
- (void)mouseExited:(NSEvent *)event {
    self.hovered = NO;
}
- (void)setHovered:(BOOL)hovered {
    if (_hovered == hovered)
        return;
    _hovered = hovered;
    self.needsDisplay = YES;
    [self updateAccessory];
}
- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    [self updateAccessory];
}
- (void)didAddSubview:(NSView *)subview {
    [super didAddSubview:subview];
    [self updateAccessory];
}
- (void)updateAccessory {
    for (LTSidebarCell *cell in self.subviews)
        if ([cell isKindOfClass:LTSidebarCell.class])
            cell.closeButton.alphaValue =
                cell.accessoryAlwaysVisible || _hovered || self.selected ? 1 : 0;
}
- (NSBackgroundStyle)interiorBackgroundStyle {
    return NSBackgroundStyleNormal;
}
- (NSRect)pill {
    NSRect rect = NSInsetRect(self.bounds, 0, 1);
    rect.size.height -= _pillTop;
    if (self.isFlipped)
        rect.origin.y += _pillTop;
    return rect;
}
- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    if (_hovered && _hoverable && !self.selected)
        FillRounded(self.pill, 8, Wash(self, .45, .07), NO);
}
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    FillRounded(self.pill, 8, Wash(self, .92, .15), !Dark(self));
}
@end

// Plain outline that keeps top-level tabs flush and hides disclosure triangles.
@interface LTSidebarOutline : NSOutlineView
@end
@implementation LTSidebarOutline
- (NSRect)frameOfOutlineCellAtRow:(NSInteger)row {
    return NSZeroRect;
}
- (NSRect)frameOfCellAtColumn:(NSInteger)column row:(NSInteger)row {
    NSRect frame = [super frameOfCellAtColumn:column row:row];
    CGFloat x = MAX(0, [self levelForRow:row] - 1) * self.indentationPerLevel;
    return NSMakeRect(x, frame.origin.y, MAX(0, NSWidth(self.bounds) - x), frame.size.height);
}
@end

@interface LTFavoriteTile : LTDropButton
@property (nonatomic) BOOL hovered;
@end
@implementation LTFavoriteTile {
    NSTrackingArea *_tracking;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    _tracking = Track(self, _tracking);
}
- (void)mouseEntered:(NSEvent *)event {
    self.hovered = YES;
    self.needsDisplay = YES;
}
- (void)mouseExited:(NSEvent *)event {
    self.hovered = NO;
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    BOOL on = self.state == NSControlStateValueOn;
    NSRect tile = NSInsetRect(self.bounds, .5, 1.5);
    NSColor *fill = on             ? Wash(self, .95, .20)
                    : self.hovered ? Wash(self, .72, .13)
                                   : Wash(self, .45, .07);
    FillRounded(tile, 10, fill, on && !Dark(self));
    NSImage *image = self.image;
    if (image.isTemplate) {
        NSImage *symbol = image;
        image = [NSImage imageWithSize:symbol.size
                               flipped:NO
                        drawingHandler:^BOOL(NSRect rect) {
                          [symbol drawInRect:rect];
                          [NSColor.secondaryLabelColor set];
                          NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop);
                          return YES;
                        }];
    }
    [image drawInRect:NSMakeRect(round(NSMidX(tile) - 9), round(NSMidY(tile) - 9), 18, 18)
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:self.cell.isHighlighted ? .7 : 1
       respectFlipped:YES
                hints:nil];
}
@end

@interface LTSpaceDot : LTDropButton
@property (nonatomic) BOOL hovered;
@property (nonatomic, strong) NSColor *tint;
@end
@implementation LTSpaceDot {
    NSTrackingArea *_tracking;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    _tracking = Track(self, _tracking);
}
- (void)mouseEntered:(NSEvent *)event {
    self.hovered = YES;
    self.needsDisplay = YES;
}
- (void)mouseExited:(NSEvent *)event {
    self.hovered = NO;
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    BOOL on = self.state == NSControlStateValueOn;
    NSRect dot = NSMakeRect(NSMidX(self.bounds) - 11, NSMidY(self.bounds) - 11, 22, 22);
    if (on || self.hovered) {
        [(on ? self.tint : Wash(self, .55, .12)) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
    }
    NSDictionary *attributes = @{
        NSFontAttributeName : [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName : on ? NSColor.whiteColor : NSColor.secondaryLabelColor
    };
    NSSize size = [self.title sizeWithAttributes:attributes];
    [self.title drawAtPoint:NSMakePoint(NSMidX(dot) - size.width / 2, NSMidY(dot) - size.height / 2)
             withAttributes:attributes];
}
@end

@interface LTSidebar () <NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate>
@end
@implementation LTSidebar {
    LTStore *_store;
    NSOutlineView *_tree;
    NSStackView *_favorites;
    NSStackView *_spaces;
    NSTextField *_spaceName;
    NSString *_spaceID;
    NSString *_selectedID;
    NSLayoutConstraint *_stackTop, *_stackTrailing, *_stackBottom;
    BOOL _refreshing;
}
- (instancetype)initWithStore:(LTStore *)store header:(NSView *)header {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _store = store;
        self.drawsBackdrop = NO;
        _favorites = LTStack(@[], NSUserInterfaceLayoutOrientationVertical, 8);
        _spaceName = LTLabel(@"Personal", 12, NSFontWeightSemibold);
        _spaceName.textColor = NSColor.secondaryLabelColor;
        NSButton *more = LTButton(@"ellipsis", @"Space actions", self, @selector(spaceMenu:));
        NSView *spacer = [NSView new];
        NSStackView *heading =
            LTStack(@[ _spaceName, spacer, more ], NSUserInterfaceLayoutOrientationHorizontal, 4);
        heading.edgeInsets = NSEdgeInsetsMake(0, 10, 0, 0);
        [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        _tree = [LTSidebarOutline new];
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"sidebar"];
        column.width = 210;
        [_tree addTableColumn:column];
        _tree.outlineTableColumn = column;
        _tree.headerView = nil;
        _tree.rowHeight = 34;
        _tree.intercellSpacing = NSMakeSize(0, 2);
        _tree.backgroundColor = NSColor.clearColor;
        _tree.indentationPerLevel = 14;
        // Indentation is applied inside the column; growing it would push rows past the edge.
        _tree.autoresizesOutlineColumn = NO;
        _tree.style = NSTableViewStylePlain;
        _tree.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
        _tree.floatsGroupRows = NO;
        _tree.focusRingType = NSFocusRingTypeNone;
        _tree.delegate = self;
        _tree.dataSource = self;
        _tree.target = self;
        _tree.action = @selector(choose:);
        _tree.accessibilityLabel = @"Sidebar tabs and folders";
        [_tree registerForDraggedTypes:@[
            @"app.lite.sidebar-item", NSPasteboardTypeURL, NSPasteboardTypeString
        ]];
        [_tree setDraggingSourceOperationMask:NSDragOperationMove | NSDragOperationCopy
                                     forLocal:YES];
        [_tree setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
        NSMenu *menu = [NSMenu new];
        menu.delegate = self;
        _tree.menu = menu;
        NSScrollView *scroll = [NSScrollView new];
        NSMenu *backgroundMenu = [NSMenu new];
        NSMenuItem *newFolder = [[NSMenuItem alloc] initWithTitle:@"New Folder…"
                                                        action:@selector(contextAction:)
                                                 keyEquivalent:@""];
        newFolder.target = self;
        newFolder.representedObject = @[ @"newFolder", @"" ];
        [backgroundMenu addItem:newFolder];
        scroll.menu = backgroundMenu;
        scroll.documentView = _tree;
        scroll.hasVerticalScroller = YES;
        scroll.autohidesScrollers = YES;
        scroll.horizontalScrollElasticity = NSScrollElasticityNone;
        scroll.drawsBackground = NO;
        _spaces = LTStack(@[], NSUserInterfaceLayoutOrientationHorizontal, 2);
        NSView *leading = [NSView new], *trailing = [NSView new];
        for (NSView *v in @[ leading, trailing ])
            [v setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *bar = LTStack(
            @[
                LTButton(@"books.vertical", @"Library", self, @selector(libraryMenu:)), leading,
                _spaces, trailing, LTButton(@"plus", @"New Space", self, @selector(newSpace:))
            ],
            NSUserInterfaceLayoutOrientationHorizontal, 4);
        [leading.widthAnchor constraintEqualToAnchor:trailing.widthAnchor].active = YES;
        [bar.heightAnchor constraintEqualToConstant:30].active = YES;
        NSArray *views = @[ header, _favorites, heading, scroll, bar ];
        NSStackView *stack = LTStack(views, NSUserInterfaceLayoutOrientationVertical, 12);
        [stack setCustomSpacing:2 afterView:heading];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:stack];
        _stackTop = [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:2];
        _stackTrailing = [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor];
        _stackBottom = [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8];
        [NSLayoutConstraint activateConstraints:@[
            _stackTop, _stackTrailing, _stackBottom,
            [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8]
        ]];
        for (NSView *v in views)
            [v.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    }
    return self;
}
- (void)setFloating:(BOOL)floating {
    [super setFloating:floating];
    // Floating panels are inset from the window; keep the header on the traffic-light line.
    _stackTop.constant = floating ? -4 : 2;
    _stackTrailing.constant = floating ? -8 : 0;
    _stackBottom.constant = floating ? -6 : -8;
}
- (void)layout {
    [super layout];
    [_tree sizeLastColumnToFit];
}
- (void)commit:(void (^)(LTProfile *))block {
    NSError *e = nil;
    if (![_store commit:block error:&e])
        LTAlert(self.window, @"Could not save", e.localizedDescription);
}
- (void)refreshSpace:(NSString *)spaceID selected:(NSString *)selectedID {
    BOOL selectionChanged = ![_selectedID isEqual:selectedID];
    _refreshing = YES;
    _spaceID = spaceID;
    _selectedID = selectedID;
    _spaceName.stringValue = [_store.profile space:spaceID].name ?: @"Space";
    for (NSView *v in [_favorites.arrangedSubviews copy]) {
        [_favorites removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSArray *favorites = [_store.profile children:@"" space:@"" kind:@"favorite"];
    NSStackView *row = nil;
    for (NSUInteger i = 0; i < favorites.count; i++) {
        LTNode *n = favorites[i];
        if (i % 4 == 0) {
            row = LTStack(@[], NSUserInterfaceLayoutOrientationHorizontal, 8);
            row.distribution = NSStackViewDistributionFillEqually;
            [_favorites addArrangedSubview:row];
            [row.widthAnchor constraintEqualToAnchor:_favorites.widthAnchor].active = YES;
        }
        LTFavoriteTile *b = [[LTFavoriteTile alloc] initWithFrame:NSZeroRect];
        b.itemID = n.identifier;
        b.image = self.pageState(n.identifier)[@"favicon"]
                      ?: [NSImage imageWithSystemSymbolName:@"globe"
                                   accessibilityDescription:n.displayTitle];
        b.title = @"";
        b.bordered = NO;
        b.imagePosition = NSImageOnly;
        b.buttonType = NSButtonTypePushOnPushOff;
        b.state = [n.identifier isEqual:selectedID] ? NSControlStateValueOn : NSControlStateValueOff;
        b.toolTip = n.displayTitle;
        b.accessibilityLabel = n.displayTitle;
        b.target = self;
        b.action = @selector(favorite:);
        b.identifier = n.identifier;
        [b.heightAnchor constraintEqualToConstant:44].active = YES;
        __weak typeof(self) weak = self;
        b.drop = ^(NSString *identifier) {
          [weak commit:^(LTProfile *p) {
            LTNode *drag = [p node:identifier];
            if (![drag.kind isEqual:@"favorite"])
                return;
            [p moveNode:identifier space:@"" parent:@"" index:i error:nil];
          }];
        };
        [row addArrangedSubview:b];
        NSMenu *menu = [NSMenu new];
        NSMenuItem *remove = [[NSMenuItem alloc] initWithTitle:@"Remove Favorite"
                                                        action:@selector(removeFavorite:)
                                                 keyEquivalent:@""];
        remove.target = self;
        remove.representedObject = n.identifier;
        [menu addItem:remove];
        b.menu = menu;
    }
    // Pad the last row so tiles keep a consistent width.
    while (row && row.arrangedSubviews.count < 4)
        [row addArrangedSubview:[NSView new]];
    _favorites.hidden = favorites.count == 0;
    for (NSView *v in [_spaces.arrangedSubviews copy]) {
        [_spaces removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    for (LTSpace *s in _store.profile.spaces) {
        LTSpaceDot *b = [[LTSpaceDot alloc] initWithFrame:NSZeroRect];
        NSString *name = s.name.length ? s.name : @"Space";
        b.title = [[name substringWithRange:[name rangeOfComposedCharacterSequenceAtIndex:0]]
            uppercaseString];
        b.tint = LTSpaceTint(_store.profile.settings, s.identifier, _store.privateMode);
        b.bordered = NO;
        b.buttonType = NSButtonTypePushOnPushOff;
        b.state = [s.identifier isEqual:spaceID] ? NSControlStateValueOn : NSControlStateValueOff;
        b.toolTip = s.name;
        b.accessibilityLabel = s.name;
        b.identifier = s.identifier;
        b.target = self;
        b.action = @selector(switchSpace:);
        [b.widthAnchor constraintEqualToConstant:26].active = YES;
        [b.heightAnchor constraintEqualToConstant:28].active = YES;
        __weak typeof(self) weak = self;
        b.drop = ^(NSString *identifier) {
          [weak commit:^(LTProfile *p) {
            if ([[p node:identifier].kind isEqual:@"favorite"])
                return;
            [p moveNode:identifier space:s.identifier parent:@"" index:NSIntegerMax error:nil];
          }];
        };
        [_spaces addArrangedSubview:b];
    }
    [_tree reloadData];
    [_tree expandItem:@"Pinned"];
    [_tree expandItem:@"Today"];
    for (LTNode *n in _store.profile.nodes)
        if ([n.kind isEqual:@"folder"] && n.expanded && [n.spaceID isEqual:spaceID])
            [_tree expandItem:n];
    NSInteger rowIndex = [_tree rowForItem:[_store.profile node:selectedID]];
    if (rowIndex >= 0) {
        [_tree selectRowIndexes:[NSIndexSet indexSetWithIndex:rowIndex] byExtendingSelection:NO];
        if (selectionChanged)
            [_tree scrollRowToVisible:rowIndex];
    } else
        [_tree deselectAll:nil];
    _refreshing = NO;
}
- (void)updateItem:(NSString *)identifier {
    for (NSStackView *row in _favorites.arrangedSubviews)
        for (NSButton *button in row.arrangedSubviews)
            if ([button isKindOfClass:NSButton.class] && [button.identifier isEqual:identifier]) {
                button.image = self.pageState(identifier)[@"favicon"]
                                   ?: [NSImage imageWithSystemSymbolName:@"globe"
                                                accessibilityDescription:nil];
                button.needsDisplay = YES;
            }
    for (NSInteger row = 0; row < _tree.numberOfRows; row++) {
        id item = [_tree itemAtRow:row];
        if ([item isKindOfClass:LTNode.class] && [((LTNode *)item).identifier isEqual:identifier]) {
            [_tree reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
                             columnIndexes:[NSIndexSet indexSetWithIndex:0]];
            break;
        }
    }
}
- (NSArray *)children:(id)item {
    if (!item)
        return @[ @"Pinned", @"Today" ];
    if ([item isKindOfClass:NSString.class]) {
        NSArray *all = [_store.profile children:@"" space:_spaceID kind:nil];
        NSMutableArray *a = [NSMutableArray new];
        for (LTNode *n in all)
            if ([item isEqual:@"Today"] ? [n.kind isEqual:@"temporary"]
                                        : ![n.kind isEqual:@"temporary"])
                [a addObject:n];
        return a;
    }
    return [_store.profile children:((LTNode *)item).identifier space:_spaceID kind:nil];
}
- (NSInteger)outlineView:(NSOutlineView *)view numberOfChildrenOfItem:(id)item {
    return [self children:item].count;
}
- (id)outlineView:(NSOutlineView *)view child:(NSInteger)index ofItem:(id)item {
    return [self children:item][index];
}
- (BOOL)outlineView:(NSOutlineView *)view isItemExpandable:(id)item {
    return [item isKindOfClass:NSString.class] || [((LTNode *)item).kind isEqual:@"folder"];
}
- (BOOL)outlineView:(NSOutlineView *)view isGroupItem:(id)item {
    return [item isKindOfClass:NSString.class];
}
- (BOOL)outlineView:(NSOutlineView *)view shouldSelectItem:(id)item {
    return [item isKindOfClass:LTNode.class];
}
- (CGFloat)outlineView:(NSOutlineView *)view heightOfRowByItem:(id)item {
    if ([item isKindOfClass:NSString.class])
        return [item isEqual:@"Pinned"] ? 4 : 44;
    return 34;
}
- (BOOL)outlineView:(NSOutlineView *)view shouldShowOutlineCellForItem:(id)item {
    // NSOutlineView refuses to collapse items without an outline cell, so folders keep one;
    // LTSidebarOutline gives it a zero frame. Pinned/Today stay permanently expanded.
    return [item isKindOfClass:LTNode.class];
}
- (NSTableRowView *)outlineView:(NSOutlineView *)view rowViewForItem:(id)item {
    LTSidebarRowView *row = [LTSidebarRowView new];
    row.hoverable = ![item isEqual:@"Pinned"];
    row.pillTop = [item isEqual:@"Today"] ? 10 : 0;
    return row;
}
- (NSView *)newTabRow {
    NSView *row = [NSView new];
    NSBox *line = [NSBox new];
    line.boxType = NSBoxCustom;
    line.titlePosition = NSNoTitle;
    line.borderWidth = 0;
    line.fillColor = NSColor.separatorColor;
    line.hidden = [self children:@"Pinned"].count == 0;
    NSImageView *icon =
        [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"plus"
                                                  accessibilityDescription:nil]];
    icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12
                                                                              weight:NSFontWeightMedium];
    icon.contentTintColor = NSColor.secondaryLabelColor;
    NSTextField *title = LTLabel(@"New Tab", 13, NSFontWeightRegular);
    title.textColor = NSColor.secondaryLabelColor;
    NSButton *button = [NSButton buttonWithTitle:@"" target:self action:@selector(search:)];
    button.bordered = NO;
    button.accessibilityLabel = @"New Tab";
    button.toolTip = @"New Tab";
    for (NSView *v in @[ line, icon, title, button ]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
        [line.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:10],
        [line.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
        [line.topAnchor constraintEqualToAnchor:row.topAnchor constant:5],
        [line.heightAnchor constraintEqualToConstant:1],
        [button.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [button.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-1],
        [button.heightAnchor constraintEqualToConstant:32],
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:10],
        [icon.widthAnchor constraintEqualToConstant:16],
        [icon.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:9],
        [title.centerYAnchor constraintEqualToAnchor:button.centerYAnchor]
    ]];
    return row;
}
- (NSView *)outlineView:(NSOutlineView *)view
     viewForTableColumn:(NSTableColumn *)column
                   item:(id)item {
    if ([item isKindOfClass:NSString.class]) {
        if ([item isEqual:@"Today"])
            return [self newTabRow];
        NSView *pinned = [NSView new];
        pinned.accessibilityElement = YES;
        pinned.accessibilityRole = NSAccessibilityGroupRole;
        pinned.accessibilityLabel = @"Pinned";
        return pinned;
    }
    LTNode *n = [_store.profile node:((LTNode *)item).identifier] ?: item;
    NSDictionary *state = self.pageState(n.identifier);
    NSString *symbol = state[@"liveStatus"] ? @"arrow.triangle.branch"
                       : [n.kind isEqual:@"folder"] ? @"folder"
                       : state[@"error"]          ? @"exclamationmark.circle"
                       : state[@"audio"]          ? @"speaker.wave.2"
                       : state[@"frozen"]         ? @"moon.zzz"
                                                  : @"globe";
    LTSidebarCell *cell = [view makeViewWithIdentifier:@"row" owner:self];
    if (!cell) {
        cell = [LTSidebarCell new];
        cell.identifier = @"row";
        NSImageView *icon = [NSImageView new];
        NSTextField *title = LTLabel(@"", 13, NSFontWeightRegular);
        NSButton *close = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark"
                                                           accessibilityDescription:@"Close tab"]
                                           target:self action:@selector(closeTab:)];
        close.bordered = NO;
        close.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:9
                                                                                  weight:NSFontWeightSemibold];
        close.contentTintColor = NSColor.secondaryLabelColor;
        cell.closeButton = close;
        cell.imageView = icon;
        cell.textField = title;
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        title.translatesAutoresizingMaskIntoConstraints = NO;
        close.translatesAutoresizingMaskIntoConstraints = NO;
        [title setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [cell addSubview:icon];
        [cell addSubview:title];
        [cell addSubview:close];
        cell.closeWidth = [close.widthAnchor constraintEqualToConstant:20];
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:16],
            [icon.heightAnchor constraintEqualToConstant:16],
            [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:9],
            [title.trailingAnchor constraintEqualToAnchor:close.leadingAnchor constant:-4],
            [title.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [close.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6],
            [close.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [close.heightAnchor constraintEqualToConstant:22],
            cell.closeWidth
        ]];
    }
    BOOL folder = [n.kind isEqual:@"folder"];
    cell.accessoryAlwaysVisible = folder;
    cell.closeButton.identifier = n.identifier;
    cell.closeButton.action = folder ? @selector(toggleFolder:) : @selector(closeTab:);
    cell.closeButton.contentTintColor =
        folder ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor;
    if (folder)
        [self updateFolderAccessory:cell expanded:[view isItemExpanded:item]];
    else {
        cell.closeButton.image = [NSImage imageWithSystemSymbolName:@"xmark"
                                           accessibilityDescription:@"Close tab"];
        cell.closeButton.toolTip = [@"Close " stringByAppendingString:n.displayTitle];
        cell.closeButton.accessibilityLabel = cell.closeButton.toolTip;
    }
    cell.closeButton.alphaValue = folder ? 1 : 0;
    if ([cell.superview isKindOfClass:LTSidebarRowView.class])
        [(LTSidebarRowView *)cell.superview updateAccessory];
    cell.imageView.image = state[@"favicon"]
                               ?: [NSImage imageWithSystemSymbolName:symbol
                                            accessibilityDescription:nil];
    cell.imageView.contentTintColor = state[@"favicon"] ? nil : NSColor.secondaryLabelColor;
    cell.textField.stringValue =
        [NSString stringWithFormat:@"%@%@", state[@"loading"] ? @"◌  " : @"", n.displayTitle];
    cell.toolTip = state[@"liveStatus"] ?: n.url;
    cell.accessibilityLabel = n.displayTitle;
    return cell;
}
- (void)updateFolderAccessory:(LTSidebarCell *)cell expanded:(BOOL)expanded {
    cell.closeButton.image =
        [NSImage imageWithSystemSymbolName:expanded ? @"chevron.down" : @"chevron.right"
                  accessibilityDescription:nil];
    cell.closeButton.toolTip = expanded ? @"Collapse folder" : @"Expand folder";
    cell.closeButton.accessibilityLabel = cell.closeButton.toolTip;
}
- (void)closeTab:(NSButton *)sender {
    LTNode *node = [_store.profile node:sender.identifier];
    if (node && ![node.kind isEqual:@"folder"])
        self.command(@"closeTab", node.identifier);
}
- (void)toggleFolder:(NSButton *)sender {
    LTNode *node = [_store.profile node:sender.identifier];
    if ([node.kind isEqual:@"folder"])
        [self toggleItem:node];
}
- (void)toggleItem:(id)item {
    if ([_tree isItemExpanded:item])
        [_tree collapseItem:item];
    else
        [_tree expandItem:item];
}
- (void)choose:(id)sender {
    NSInteger row = _tree.clickedRow >= 0 ? _tree.clickedRow : _tree.selectedRow;
    id item = [_tree itemAtRow:row];
    if (![item isKindOfClass:LTNode.class])
        return;
    if ([((LTNode *)item).kind isEqual:@"folder"]) {
        // Folders open in place like Arc; keep the active tab highlighted.
        if (_tree.clickedRow >= 0)
            [self toggleItem:item];
        NSInteger selected = [_tree rowForItem:[_store.profile node:_selectedID]];
        if (selected >= 0)
            [_tree selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];
        else
            [_tree deselectAll:nil];
        return;
    }
    self.selected(((LTNode *)item).identifier);
}
- (void)outlineViewItemDidExpand:(NSNotification *)n {
    [self expansion:n expanded:YES];
}
- (void)outlineViewItemDidCollapse:(NSNotification *)n {
    [self expansion:n expanded:NO];
}
- (void)expansion:(NSNotification *)n expanded:(BOOL)expanded {
    LTNode *item = n.userInfo[@"NSObject"];
    if (![item isKindOfClass:LTNode.class])
        return;
    NSInteger row = [_tree rowForItem:item];
    LTSidebarCell *cell = row >= 0 ? [_tree viewAtColumn:0 row:row makeIfNecessary:NO] : nil;
    if ([cell isKindOfClass:LTSidebarCell.class])
        [self updateFolderAccessory:cell expanded:expanded];
    if (_refreshing)
        return;
    NSString *identifier = item.identifier;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self commit:^(LTProfile *p) {
        [p node:identifier].expanded = expanded;
      }];
    });
}
- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)view pasteboardWriterForItem:(id)item {
    if (![item isKindOfClass:LTNode.class])
        return nil;
    LTNode *n = item;
    NSPasteboardItem *p = [NSPasteboardItem new];
    [p setString:n.identifier forType:@"app.lite.sidebar-item"];
    if (n.url.length) {
        [p setString:n.url forType:NSPasteboardTypeURL];
        [p setString:n.url forType:NSPasteboardTypeString];
    }
    return p;
}
- (NSDragOperation)outlineView:(NSOutlineView *)v
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item
            proposedChildIndex:(NSInteger)index {
    if ([item isKindOfClass:LTNode.class] && ![((LTNode *)item).kind isEqual:@"folder"])
        return NSDragOperationNone;
    return [info.draggingPasteboard stringForType:@"app.lite.sidebar-item"] ? NSDragOperationMove
                                                                            : NSDragOperationCopy;
}
- (BOOL)outlineView:(NSOutlineView *)v
         acceptDrop:(id<NSDraggingInfo>)info
               item:(id)item
         childIndex:(NSInteger)index {
    NSString *identifier = [info.draggingPasteboard stringForType:@"app.lite.sidebar-item"];
    NSString *parent = [item isKindOfClass:LTNode.class] ? ((LTNode *)item).identifier : @"";
    BOOL temporary = [item isEqual:@"Today"];
    if (identifier) {
        [self commit:^(LTProfile *p) {
          LTNode *n = [p node:identifier];
          if ([n.kind isEqual:@"favorite"])
              return;
          if (temporary && [n.kind isEqual:@"folder"])
              return;
          if (![n.kind isEqual:@"folder"]) {
              n.kind = temporary ? @"temporary" : @"pinned";
              if (!temporary && !n.pinnedURL.length)
                  n.pinnedURL = n.url;
          }
          [p moveNode:identifier
                space:self->_spaceID
               parent:parent
                index:index < 0 ? NSIntegerMax : index
                error:nil];
        }];
        return YES;
    }
    NSString *url = [info.draggingPasteboard stringForType:NSPasteboardTypeURL]
                        ?: [info.draggingPasteboard stringForType:NSPasteboardTypeString];
    if (!LTValidURL(url))
        return NO;
    [self commit:^(LTProfile *p) {
      [p addNode:temporary ? @"temporary" : @"pinned"
           title:[NSURL URLWithString:url].host ?: url
             url:url
           space:self->_spaceID
          parent:parent];
    }];
    return YES;
}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSMenuItem *newFolder = [[NSMenuItem alloc] initWithTitle:@"New Folder…"
                                                    action:@selector(contextAction:)
                                             keyEquivalent:@""];
    newFolder.target = self;
    newFolder.representedObject = @[ @"newFolder", @"" ];
    [menu addItem:newFolder];
    LTNode *n = [_tree itemAtRow:_tree.clickedRow];
    if (![n isKindOfClass:LTNode.class])
        return;
    [menu addItem:NSMenuItem.separatorItem];
    NSArray *actions=[n.kind isEqual:@"folder"]?@[@[@"Rename",@"rename"],@[@"New Folder Inside",@"folderInside"],@[@"Open All",@"openAll"],@[@"Move to Space…",@"moveTab"],@[@"Delete Folder…",@"deleteNode"]]:@[@[[n.kind isEqual:@"pinned"]?@"Unpin Tab":@"Pin Tab",@"pinTab"],@[@"Rename",@"rename"],@[@"Duplicate",@"duplicate"],@[@"Reload",@"reload"],@[@"Return to Pinned URL",@"resetPinned"],@[@"Move to Space…",@"moveTab"],@[@"Move to Folder…",@"moveFolder"],@[@"Add to Favorites",@"favorite"],@[@"Open in Split",@"splitTab"],@[@"Keep Tab Awake",@"keepAwake"],@[@"Copy URL",@"copyURL"],@[@"Close",@"closeTab"]];
    for (NSArray *a in actions) {
        NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:a[0]
                                                   action:@selector(contextAction:)
                                            keyEquivalent:@""];
        i.target = self;
        i.representedObject = @[ a[1], n.identifier ];
        [menu addItem:i];
    }
    if (_store.profile.settings[@"githubLiveFolders"][n.identifier]) {
        [menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *status = [[NSMenuItem alloc] initWithTitle:self.pageState(n.identifier)[@"liveStatus"] ?: @"GitHub Live Folder" action:nil keyEquivalent:@""];
        status.enabled = NO;
        [menu addItem:status];
        for (NSArray *action in @[@[@"Refresh Pull Requests", @"refreshGitHubFolder"],
                                 @[@"Edit Live Folder…", @"editGitHubFolder"],
                                 @[@"Stop Updating (Keep Tabs)", @"stopGitHubFolder"]]) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:action[0] action:@selector(contextAction:) keyEquivalent:@""];
            item.target = self;
            item.representedObject = @[action[1], n.identifier];
            [menu addItem:item];
        }
    }
}
- (void)contextAction:(NSMenuItem *)item {
    self.command(item.representedObject[0], item.representedObject[1]);
}
- (void)favorite:(NSButton *)b {
    self.selected(b.identifier);
}
- (void)removeFavorite:(NSMenuItem *)i {
    [self commit:^(LTProfile *p) {
      [p removeNode:i.representedObject];
    }];
}
- (void)switchSpace:(NSButton *)b {
    self.spaceSelected(b.identifier);
}
- (void)spaceMenu:(NSButton *)sender {
    NSMenu *m = [NSMenu new];
    for (NSArray *a in @[
             @[ @"Rename Space", @"renameSpace" ], @[ @"New Space", @"newSpace" ],
             @[ @"Delete Space…", @"deleteSpace" ]
         ]) {
        NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:a[0]
                                                   action:@selector(contextAction:)
                                            keyEquivalent:@""];
        i.target = self;
        i.representedObject = @[ a[1], _spaceID ];
        [m addItem:i];
    }
    if (!_store.privateMode) {
        NSDictionary *themes = _store.profile.settings[@"spaceThemes"];
        NSString *current = [themes isKindOfClass:NSDictionary.class] ? themes[_spaceID] : nil;
        if (![LTPaletteNames() containsObject:current])
            current = nil;
        NSMenu *colors = [NSMenu new];
        NSMenuItem *automatic = [[NSMenuItem alloc] initWithTitle:@"Automatic"
                                                           action:@selector(spaceColor:)
                                                    keyEquivalent:@""];
        automatic.target = self;
        automatic.representedObject = @"";
        automatic.state = current ? NSControlStateValueOff : NSControlStateValueOn;
        [colors addItem:automatic];
        [colors addItem:NSMenuItem.separatorItem];
        for (NSString *name in LTPaletteNames()) {
            NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:name
                                                       action:@selector(spaceColor:)
                                                keyEquivalent:@""];
            i.target = self;
            i.representedObject = name;
            i.state = [name isEqual:current] ? NSControlStateValueOn : NSControlStateValueOff;
            NSColor *color = LTPaletteColor(name);
            i.image = [NSImage imageWithSize:NSMakeSize(12, 12)
                                     flipped:NO
                              drawingHandler:^BOOL(NSRect rect) {
                                [color setFill];
                                [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, .5, .5)]
                                    fill];
                                return YES;
                              }];
            [colors addItem:i];
        }
        NSMenuItem *color = [[NSMenuItem alloc] initWithTitle:@"Space Color"
                                                       action:nil
                                                keyEquivalent:@""];
        color.submenu = colors;
        [m addItem:NSMenuItem.separatorItem];
        [m addItem:color];
    }
    [m popUpMenuPositioningItem:nil
                     atLocation:NSMakePoint(0, sender.bounds.size.height)
                         inView:sender];
}
- (void)spaceColor:(NSMenuItem *)item {
    NSString *spaceID = _spaceID, *name = item.representedObject;
    if (!spaceID.length)
        return;
    [self commit:^(LTProfile *p) {
      NSDictionary *saved = p.settings[@"spaceThemes"];
      NSMutableDictionary *themes = [saved isKindOfClass:NSDictionary.class]
                                        ? [saved mutableCopy]
                                        : [NSMutableDictionary new];
      if (name.length)
          themes[spaceID] = name;
      else
          [themes removeObjectForKey:spaceID];
      if (themes.count)
          p.settings[@"spaceThemes"] = themes;
      else
          [p.settings removeObjectForKey:@"spaceThemes"];
    }];
}
- (void)libraryMenu:(NSButton *)sender {
    NSMenu *m = [NSMenu new];
    for (NSArray *a in @[
             @[ @"Downloads", @"downloads", @"arrow.down.circle" ],
             @[ @"History", @"history", @"clock" ], @[ @"Settings", @"settings", @"gearshape" ]
         ]) {
        NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:a[0]
                                                   action:@selector(contextAction:)
                                            keyEquivalent:@""];
        i.target = self;
        i.representedObject = @[ a[1], @"" ];
        i.image = [NSImage imageWithSystemSymbolName:a[2] accessibilityDescription:nil];
        [m addItem:i];
    }
    [m popUpMenuPositioningItem:nil
                     atLocation:NSMakePoint(0, sender.bounds.size.height)
                         inView:sender];
}
- (void)search:(id)s {
    self.command(@"newTab", @"");
}
- (void)newSpace:(id)s {
    self.command(@"newSpace", @"");
}
@end
