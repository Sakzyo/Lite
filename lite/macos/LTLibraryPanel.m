#import "LTLibraryPanel.h"
#import "LTUI.h"
@interface LTLibraryPanel () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@end
@implementation LTLibraryPanel {
    LTStore *_store;
    NSString *_mode;
    NSArray *_rows;
    NSSearchField *_search;
    NSTableView *_table;
    NSStackView *_content;
    NSArray *_downloads;
}
- (instancetype)initWithStore:(LTStore *)store {
    NSPanel *panel =
        [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 620, 490)
                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                             NSWindowStyleMaskResizable
                                     backing:NSBackingStoreBuffered
                                       defer:NO];
    panel.title = @"Lite";
    panel.minSize = NSMakeSize(500, 400);
    if ((self = [super initWithWindow:panel])) {
        _store = store;
    }
    return self;
}
- (void)showMode:(NSString *)mode owner:(NSWindow *)owner downloads:(NSArray *)downloads {
    _mode = mode;
    _downloads = downloads;
    self.window.title = [@"Lite — " stringByAppendingString:mode.capitalizedString];
    NSView *root = [NSView new];
    self.window.contentView = root;
    _content = LTStack(@[], NSUserInterfaceLayoutOrientationVertical, 16);
    LTPin(_content, root, 22);
    if ([mode isEqual:@"settings"]) {
        [self.window setContentSize:NSMakeSize(620, 600)];
        [self buildSettings];
    } else {
        _search = [NSSearchField new];
        _search.placeholderString =
            [mode isEqual:@"history"] ? @"Search history" : @"Search downloads";
        _search.delegate = self;
        [_content addArrangedSubview:_search];
        [_search.widthAnchor constraintEqualToAnchor:_content.widthAnchor].active = YES;
        _table = [NSTableView new];
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:@"entry"];
        [_table addTableColumn:c];
        _table.headerView = nil;
        _table.rowHeight = 52;
        _table.dataSource = self;
        _table.delegate = self;
        _table.target = self;
        _table.doubleAction = @selector(open:);
        _table.style = NSTableViewStyleFullWidth;
        NSScrollView *scroll = [NSScrollView new];
        scroll.documentView = _table;
        scroll.hasVerticalScroller = YES;
        [_content addArrangedSubview:scroll];
        [scroll.widthAnchor constraintEqualToAnchor:_content.widthAnchor].active = YES;
        NSArray *buttons=[mode isEqual:@"history"]?@[[NSButton buttonWithTitle:@"Open" target:self action:@selector(open:)],[NSButton buttonWithTitle:@"Delete selected" target:self action:@selector(delete:)],[NSButton buttonWithTitle:@"Clear history…" target:self action:@selector(clear:)]]:@[[NSButton buttonWithTitle:@"Reveal in Finder" target:self action:@selector(reveal:)],[NSButton buttonWithTitle:@"Pause / Resume" target:self action:@selector(pause:)],[NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)],[NSButton buttonWithTitle:@"Clear completed" target:self action:@selector(clearCompleted:)]];
        [_content
            addArrangedSubview:LTStack(buttons, NSUserInterfaceLayoutOrientationHorizontal, 8)];
        [self refresh];
    }
    [self.window setFrameOrigin:NSMakePoint(NSMidX(owner.frame) - 310, NSMidY(owner.frame) - 245)];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}
- (void)buildSettings {
    [_content addArrangedSubview:LTLabel(@"Settings", 26, NSFontWeightSemibold)];
    for (NSArray *setting in @[
             @[ @"Search engine", @"search", @"DuckDuckGo", @"Google" ],
             @[ @"Memory policy", @"performance", @"Balanced", @"Efficient", @"Maximum Saving" ]
         ]) {
        NSPopUpButton *p = [NSPopUpButton new];
        [p addItemsWithTitles:[setting subarrayWithRange:NSMakeRange(2, setting.count - 2)]];
        [p selectItemWithTitle:_store.profile.settings[setting[1]]];
        p.identifier = setting[1];
        p.target = self;
        p.action = @selector(setting:);
        [_content addArrangedSubview:LTStack(@[ LTLabel(setting[0], 13, NSFontWeightMedium), p ],
                                             NSUserInterfaceLayoutOrientationHorizontal, 18)];
    }
    NSButton *mini = [NSButton checkboxWithTitle:@"Open external links in Mini Lite"
                                          target:self
                                          action:@selector(externalMini:)];
    mini.state = [_store.profile.settings[@"externalMini"] boolValue];
    [_content addArrangedSubview:mini];
    NSArray *actions = @[
        @[ @"Make Lite the default browser…", @"defaultBrowser" ],
        @[ @"Import Sidebar from Arc…", @"importArc" ],
        @[ @"Import bookmarks (HTML, Chromium, Safari)…", @"importBookmarks" ],
        @[ @"Clear browsing data…", @"clearData" ], @[ @"Manage saved logins…", @"passwords" ],
        @[ @"Keyboard shortcuts…", @"shortcuts" ],
        @[ @"Browser task manager…", @"taskManager" ],
        @[ @"New GitHub Live Folder…", @"githubFolder" ],
        @[ @"Extensions and compatibility", @"extensions" ]
    ];
    for (NSArray *a in actions) {
        NSButton *b = [NSButton buttonWithTitle:a[0] target:self action:@selector(action:)];
        b.identifier = a[1];
        [_content addArrangedSubview:b];
    }
    NSTextField *privacy = LTLabel(
        @"Your browser data stays on this Mac.\nNo Lite account, analytics, or cloud services.", 12,
        NSFontWeightRegular);
    privacy.maximumNumberOfLines = 0;
    privacy.textColor = NSColor.secondaryLabelColor;
    [_content addArrangedSubview:privacy];
    NSTextField *about =
        LTLabel(@"Lite 0.1 · Chromium 154 · Native AppKit\nDevelopment build — not notarized", 11,
                NSFontWeightRegular);
    about.maximumNumberOfLines = 0;
    about.textColor = NSColor.tertiaryLabelColor;
    [_content addArrangedSubview:about];
    [_content addArrangedSubview:[NSView new]];
}
- (void)setting:(NSPopUpButton *)b {
    NSError *e = nil;
    if (![_store
            commit:^(LTProfile *p) {
              p.settings[b.identifier] = b.titleOfSelectedItem;
            }
             error:&e])
        LTAlert(self.window, @"Could not save", e.localizedDescription);
}
- (void)externalMini:(NSButton *)b {
    NSError *e = nil;
    if (![_store
            commit:^(LTProfile *p) {
              p.settings[@"externalMini"] = @(b.state == NSControlStateValueOn);
            }
             error:&e])
        LTAlert(self.window, @"Could not save", e.localizedDescription);
}
- (void)action:(NSButton *)b {
    [self.window orderOut:nil];
    self.command(b.identifier);
}
- (void)updateDownloads:(NSArray *)downloads {
    _downloads = downloads;
    if ([_mode isEqual:@"downloads"])
        [self refresh];
}
- (void)refresh {
    if ([_mode isEqual:@"history"])
        _rows = [_store history:_search.stringValue limit:500];
    else {
        NSMutableArray *a = [NSMutableArray new];
        for (NSDictionary *d in _downloads)
            if (!_search.stringValue.length ||
                [d[@"name"] localizedCaseInsensitiveContainsString:_search.stringValue])
                [a addObject:d];
        _rows = a;
    }
    [_table reloadData];
}
- (void)controlTextDidChange:(NSNotification *)n {
    [self refresh];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t {
    return _rows.count;
}
- (NSView *)tableView:(NSTableView *)table
    viewForTableColumn:(NSTableColumn *)column
                   row:(NSInteger)row {
    NSDictionary *r = _rows[row];
    BOOL history = [_mode isEqual:@"history"];
    NSString *detail = history                      ? r[@"url"]
                       : [r[@"complete"] boolValue] ? @"Complete — double-click to open"
                       : [r[@"canceled"] boolValue] ? @"Canceled"
                       : [r[@"paused"] boolValue]
                           ? @"Paused"
                           : [NSString stringWithFormat:@"Downloading · %@%%", r[@"percent"]];
    NSTextField *title = LTLabel(history ? r[@"title"] : r[@"name"], 13, NSFontWeightMedium),
                *sub = LTLabel(detail, 11, NSFontWeightRegular);
    sub.textColor = NSColor.secondaryLabelColor;
    NSStackView *v = LTStack(@[ title, sub ], NSUserInterfaceLayoutOrientationVertical, 4);
    v.edgeInsets = NSEdgeInsetsMake(6, 8, 6, 8);
    [title.widthAnchor constraintLessThanOrEqualToConstant:510].active = YES;
    [sub.widthAnchor constraintLessThanOrEqualToConstant:510].active = YES;
    return v;
}
- (NSDictionary *)selection {
    return _table.selectedRow >= 0 && _table.selectedRow < (NSInteger)_rows.count
               ? _rows[_table.selectedRow]
               : nil;
}
- (void)open:(id)s {
    NSDictionary *r = [self selection];
    if (!r)
        return;
    if ([_mode isEqual:@"history"]) {
        self.openURL(r[@"url"]);
        [self.window orderOut:nil];
    } else if ([r[@"complete"] boolValue])
        [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:r[@"path"]]];
}
- (void)delete:(id)s {
    NSDictionary *r = [self selection];
    if (r) {
        [_store deleteHistoryURL:r[@"url"]];
        [self refresh];
    }
}
- (void)clear:(id)s {
    NSAlert *a = [NSAlert new];
    a.messageText = @"Clear history";
    NSPopUpButton *range = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 250, 28)];
    [range addItemsWithTitles:@[ @"Last hour", @"Last 24 hours", @"All time" ]];
    a.accessoryView = range;
    [a addButtonWithTitle:@"Cancel"];
    [a addButtonWithTitle:@"Clear"];
    [a beginSheetModalForWindow:self.window
              completionHandler:^(NSModalResponse r) {
                if (r == NSAlertSecondButtonReturn) {
                    double delta = range.indexOfSelectedItem == 0   ? 3600
                                   : range.indexOfSelectedItem == 1 ? 86400
                                                                    : DBL_MAX;
                    [self->_store clearHistorySince:NSDate.date.timeIntervalSince1970 - delta];
                    [self refresh];
                }
              }];
}
- (void)reveal:(id)s {
    NSDictionary *r = [self selection];
    if ([r[@"path"] length])
        [NSWorkspace.sharedWorkspace
            activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:r[@"path"]] ]];
}
- (void)pause:(id)s {
    NSDictionary *r = [self selection];
    if (r)
        self.downloadAction(r, [r[@"paused"] boolValue] ? @"resume" : @"pause");
}
- (void)cancel:(id)s {
    NSDictionary *r = [self selection];
    if (r)
        self.downloadAction(r, @"cancel");
}
- (void)clearCompleted:(id)s {
    NSMutableArray *a = [NSMutableArray new];
    for (NSDictionary *r in _downloads)
        if ([r[@"active"] boolValue])
            [a addObject:r];
        else
            self.downloadAction(r, @"forget");
    _downloads = a;
    [self refresh];
}
@end
