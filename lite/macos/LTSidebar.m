#import "LTSidebar.h"
#import "LTUI.h"
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
    BOOL _refreshing;
}
- (instancetype)initWithStore:(LTStore *)store header:(NSView *)header {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _store = store;
        self.material = NSVisualEffectMaterialSidebar;
        self.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        self.state = NSVisualEffectStateFollowsWindowActiveState;
        _favorites = LTStack(@[], NSUserInterfaceLayoutOrientationVertical, 6);
        _spaceName = LTLabel(@"Personal", 13, NSFontWeightSemibold);
        NSButton *more = LTButton(@"ellipsis", @"Space actions", self, @selector(spaceMenu:));
        NSView *spacer = [NSView new];
        NSStackView *heading =
            LTStack(@[ _spaceName, spacer, more ], NSUserInterfaceLayoutOrientationHorizontal, 4);
        [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        _tree = [NSOutlineView new];
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"sidebar"];
        column.width = 210;
        [_tree addTableColumn:column];
        _tree.outlineTableColumn = column;
        _tree.headerView = nil;
        _tree.rowHeight = 32;
        _tree.intercellSpacing = NSMakeSize(0, 2);
        _tree.backgroundColor = NSColor.clearColor;
        _tree.indentationPerLevel = 14;
        _tree.style = NSTableViewStyleSourceList;
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
        scroll.documentView = _tree;
        scroll.hasVerticalScroller = YES;
        scroll.drawsBackground = NO;
        NSButton *newTab = [NSButton buttonWithTitle:@"＋  New Tab"
                                              target:self
                                              action:@selector(search:)];
        newTab.bordered = NO;
        newTab.alignment = NSTextAlignmentLeft;
        newTab.font = [NSFont systemFontOfSize:12];
        newTab.contentTintColor = NSColor.secondaryLabelColor;
        _spaces = LTStack(@[], NSUserInterfaceLayoutOrientationHorizontal, 4);
        NSStackView *utilities = LTStack(
            @[
                LTButton(@"sidebar.left", @"Hide sidebar", self, @selector(toggle:)),
                LTButton(@"arrow.down.circle", @"Downloads", self, @selector(downloads:)),
                LTButton(@"clock", @"History", self, @selector(history:)),
                LTButton(@"gearshape", @"Settings", self, @selector(settings:))
            ],
            NSUserInterfaceLayoutOrientationHorizontal, 14);
        NSBox *line = [NSBox new];
        line.boxType = NSBoxSeparator;
        NSStackView *stack =
            LTStack(@[ header, _favorites, heading, scroll, newTab, line, _spaces, utilities ],
                    NSUserInterfaceLayoutOrientationVertical, 12);
        stack.edgeInsets = NSEdgeInsetsMake(10, 12, 10, 12);
        LTPin(stack, self, 0);
        for (NSView *v in @[ header, _favorites, heading, scroll, newTab, line, _spaces ])
            [v.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-24].active = YES;
        [utilities.heightAnchor constraintEqualToConstant:30].active = YES;
    }
    return self;
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
            row = LTStack(@[], NSUserInterfaceLayoutOrientationHorizontal, 6);
            [_favorites addArrangedSubview:row];
        }
        LTDropButton *b = [[LTDropButton alloc] initWithFrame:NSZeroRect];
        b.itemID = n.identifier;
        b.image = self.pageState(n.identifier)[@"favicon"]
                      ?: [NSImage imageWithSystemSymbolName:@"globe"
                                   accessibilityDescription:n.displayTitle];
        b.imageScaling = NSImageScaleProportionallyDown;
        b.bezelStyle = NSBezelStyleTexturedRounded;
        b.toolTip = n.displayTitle;
        b.accessibilityLabel = n.displayTitle;
        b.target = self;
        b.action = @selector(favorite:);
        b.identifier = n.identifier;
        [b.widthAnchor constraintEqualToConstant:46].active = YES;
        [b.heightAnchor constraintEqualToConstant:40].active = YES;
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
    _favorites.hidden = favorites.count == 0;
    for (NSView *v in [_spaces.arrangedSubviews copy]) {
        [_spaces removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    for (LTSpace *s in _store.profile.spaces) {
        LTDropButton *b = [[LTDropButton alloc] initWithFrame:NSZeroRect];
        b.title = [s.name substringToIndex:MIN((NSUInteger)2, s.name.length)];
        b.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        b.bezelStyle = NSBezelStyleRecessed;
        b.buttonType = NSButtonTypePushOnPushOff;
        b.state = [s.identifier isEqual:spaceID] ? NSControlStateValueOn : NSControlStateValueOff;
        b.toolTip = s.name;
        b.accessibilityLabel = s.name;
        b.identifier = s.identifier;
        b.target = self;
        b.action = @selector(switchSpace:);
        [b.widthAnchor constraintEqualToConstant:32].active = YES;
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
    [_spaces addArrangedSubview:LTButton(@"plus", @"New Space", self, @selector(newSpace:))];
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
            if ([button.identifier isEqual:identifier])
                button.image = self.pageState(identifier)[@"favicon"]
                                   ?: [NSImage imageWithSystemSymbolName:@"globe"
                                                accessibilityDescription:nil];
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
    return [item isKindOfClass:NSString.class] ? 25 : 32;
}
- (NSView *)outlineView:(NSOutlineView *)view
     viewForTableColumn:(NSTableColumn *)column
                   item:(id)item {
    if ([item isKindOfClass:NSString.class]) {
        NSTextField *t =
            LTLabel([item isEqual:@"Pinned"] ? @"PINNED" : @"TABS", 10, NSFontWeightSemibold);
        t.textColor = NSColor.tertiaryLabelColor;
        return t;
    }
    LTNode *n = [_store.profile node:((LTNode *)item).identifier] ?: item;
    NSDictionary *state = self.pageState(n.identifier);
    NSString *symbol = state[@"liveStatus"] ? @"arrow.triangle.branch"
                       : [n.kind isEqual:@"folder"] ? @"folder"
                       : state[@"error"]          ? @"exclamationmark.circle"
                       : state[@"audio"]          ? @"speaker.wave.2"
                       : state[@"frozen"]         ? @"moon.zzz"
                                                  : @"globe";
    NSTableCellView *cell = [view makeViewWithIdentifier:@"row" owner:self];
    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = @"row";
        NSImageView *icon = [NSImageView new];
        NSTextField *title = LTLabel(@"", 12, NSFontWeightRegular);
        cell.imageView = icon;
        cell.textField = title;
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        title.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:icon];
        [cell addSubview:title];
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:16],
            [icon.heightAnchor constraintEqualToConstant:16],
            [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:9],
            [title.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6],
            [title.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
        ]];
    }
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
- (void)choose:(id)sender {
    id item = [_tree itemAtRow:_tree.selectedRow];
    if ([item isKindOfClass:LTNode.class] && ![((LTNode *)item).kind isEqual:@"folder"])
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
    if (_refreshing || ![item isKindOfClass:LTNode.class])
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
    LTNode *n = [_tree itemAtRow:_tree.clickedRow];
    if (![n isKindOfClass:LTNode.class])
        return;
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
    [m popUpMenuPositioningItem:nil
                     atLocation:NSMakePoint(0, sender.bounds.size.height)
                         inView:sender];
}
- (void)search:(id)s {
    self.command(@"newTab", @"");
}
- (void)toggle:(id)s {
    self.command(@"toggleSidebar", @"");
}
- (void)downloads:(id)s {
    self.command(@"downloads", @"");
}
- (void)history:(id)s {
    self.command(@"history", @"");
}
- (void)settings:(id)s {
    self.command(@"settings", @"");
}
- (void)newSpace:(id)s {
    self.command(@"newSpace", @"");
}
@end
