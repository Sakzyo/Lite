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
    NSPopUpButton *_engines;
    NSButton *_removeEngine;
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
        [self.window setContentSize:NSMakeSize(620, 770)];
        [self buildSettings];
    } else {
        _search = [NSSearchField new];
        _search.placeholderString =
            [mode isEqual:@"history"] ? @"Search history" : @"Search downloads";
        _search.accessibilityLabel = _search.placeholderString;
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
        _table.accessibilityLabel = [mode isEqual:@"history"] ? @"Browsing history" : @"Downloads";
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
             @[ @"Search engine", @"search" ],
             @[ @"Memory policy", @"performance", @"Balanced", @"Efficient", @"Maximum Saving" ]
         ]) {
        BOOL search = [setting[1] isEqual:@"search"];
        NSPopUpButton *p = [NSPopUpButton new];
        p.identifier = setting[1];
        p.accessibilityLabel = setting[0];
        p.target = self;
        p.action = @selector(setting:);
        NSMutableArray *row = [@[ LTLabel(setting[0], 13, NSFontWeightMedium), p ] mutableCopy];
        if (search) {
            _engines = p;
            NSButton *add = [NSButton buttonWithTitle:@"Add…" target:self action:@selector(addEngine:)];
            add.accessibilityLabel = @"Add search engine";
            _removeEngine = [NSButton buttonWithTitle:@"Remove" target:self action:@selector(removeEngine:)];
            _removeEngine.accessibilityLabel = @"Remove search engine";
            [row addObjectsFromArray:@[ add, _removeEngine ]];
            [self reloadEngines];
        } else {
            [p addItemsWithTitles:[setting subarrayWithRange:NSMakeRange(2, setting.count - 2)]];
            [p selectItemWithTitle:_store.profile.settings[setting[1]]];
        }
        [_content addArrangedSubview:LTStack(row, NSUserInterfaceLayoutOrientationHorizontal, search ? 10 : 18)];
        if (search)
            [_content addArrangedSubview:[self suggestionsSetting]];
    }
    NSButton *mini = [NSButton checkboxWithTitle:@"Open external links in Mini Lite"
                                          target:self
                                          action:@selector(externalMini:)];
    mini.state = [_store.profile.settings[@"externalMini"] boolValue];
    [_content addArrangedSubview:mini];
    NSArray *actions = @[
        @[ @"Make Lite the default browser…", @"defaultBrowser" ],
        @[ @"Import Sidebar from Arc…", @"importArc" ],
        @[ @"Import bookmarks (HTML, Chromium, Safari, Lite)…", @"importBookmarks" ],
        @[ @"Export bookmarks (HTML)…", @"exportBookmarks" ],
        @[ @"Export Lite organization…", @"exportOrganization" ],
        @[ @"Clear browsing data…", @"clearData" ], @[ @"Manage saved logins…", @"passwords" ],
        @[ @"Keyboard shortcuts…", @"shortcuts" ],
        @[ @"Browser task manager…", @"taskManager" ],
        @[ @"Content blocking…", @"contentBlocking" ],
        @[ @"New GitHub Live Folder…", @"githubFolder" ],
        @[ @"Extensions…", @"extensions" ]
    ];
    for (NSArray *a in actions) {
        NSButton *b = [NSButton buttonWithTitle:a[0] target:self action:@selector(action:)];
        b.identifier = a[1];
        [_content addArrangedSubview:b];
    }
    NSTextField *privacy = LTLabel(
        @"Your browser data stays on this Mac.\nNo Lite account or analytics. Crash reports are sent only if you choose to send them.", 12,
        NSFontWeightRegular);
    privacy.maximumNumberOfLines = 0;
    privacy.textColor = NSColor.secondaryLabelColor;
    [_content addArrangedSubview:privacy];
    NSTextField *about =
        LTLabel([NSString stringWithFormat:@"Lite %@ · Chromium " LITE_CHROMIUM_MAJOR @" · Native AppKit\n%@",
                  [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.1",
                  [[NSBundle.mainBundle objectForInfoDictionaryKey:@"LiteDistribution"] isEqual:@"DeveloperID"] ? @"Developer ID distribution build" : @"Local development build"], 11,
                NSFontWeightRegular);
    about.maximumNumberOfLines = 0;
    about.textColor = NSColor.tertiaryLabelColor;
    [_content addArrangedSubview:about];
    [_content addArrangedSubview:[NSView new]];
}
- (NSView *)suggestionsSetting {
    NSButton *suggestions = [NSButton checkboxWithTitle:@"Show search suggestions in the Command Bar"
                                                 target:self
                                                 action:@selector(searchSuggestions:)];
    suggestions.state = [_store.profile.settings[@"searchSuggestions"] boolValue];
    NSTextField *sent = [NSTextField wrappingLabelWithString:
        @"Sends what you type in the Command Bar to your search engine as you type. Addresses and private windows are never sent."];
    sent.font = [NSFont systemFontOfSize:11];
    sent.textColor = NSColor.secondaryLabelColor;
    sent.selectable = NO;
    [sent.widthAnchor constraintEqualToConstant:540].active = YES;
    return LTStack(@[ suggestions, sent ], NSUserInterfaceLayoutOrientationVertical, 4);
}
- (void)setting:(NSPopUpButton *)b {
    NSString *setting = b.identifier, *value = b.titleOfSelectedItem;
    BOOL search = b == _engines;
    [_store commit:^(LTProfile *p) {
      // An engine removed by a save still queued is no longer there to select.
      if (!search || [[LTSearchEngines(p.settings) valueForKey:@"name"] containsObject:value])
          p.settings[setting] = value;
    } completion:nil];
    if (search)
        _removeEngine.enabled = [self customEngineNamed:value] != nil;
}
// Fills the search engine menu from the profile: the built-in engines, then the user's own.
- (void)reloadEngines {
    NSDictionary *settings = _store.profile.settings;
    [_engines removeAllItems];
    [_engines addItemsWithTitles:[LTSearchEngines(settings) valueForKey:@"name"]];
    NSString *selected = LTSelectedSearchEngine(settings)[@"name"];
    [_engines selectItemWithTitle:selected];
    _removeEngine.enabled = [self customEngineNamed:selected] != nil;
}
- (NSDictionary *)customEngineNamed:(NSString *)name {
    NSArray *custom = _store.profile.settings[@"searchEngines"];
    for (NSDictionary *engine in [custom isKindOfClass:NSArray.class] ? custom : @[])
        if ([engine[@"name"] isEqual:name])
            return engine;
    return nil;
}
- (void)addEngine:(id)sender {
    [self askForEngine:@{} problem:nil];
}
// Asks for a search engine of the user's own. After a mistake it asks again with what was entered.
- (void)askForEngine:(NSDictionary *)draft problem:(NSString *)problem {
    NSAlert *a = [NSAlert new];
    a.messageText = @"Add a search engine";
    a.informativeText = problem ?: @"Use %s where the search text goes. The suggestions address is optional.";
    NSMutableArray<NSTextField *> *fields = [NSMutableArray new];
    NSMutableArray *rows = [NSMutableArray new];
    for (NSArray *f in @[
             @[ @"Name", @"name", @"Example Search" ],
             @[ @"Search address", @"url", @"https://example.com/search?q=%s" ],
             @[ @"Suggestions address", @"suggest", @"https://example.com/suggest?q=%s" ]
         ]) {
        NSTextField *field = [NSTextField new];
        field.stringValue = draft[f[1]] ?: @"";
        field.placeholderString = f[2];
        field.accessibilityLabel = f[0];
        [field.widthAnchor constraintEqualToConstant:340].active = YES;
        [fields addObject:field];
        [rows addObject:LTStack(@[ LTLabel(f[0], 12, NSFontWeightMedium), field ],
                                NSUserInterfaceLayoutOrientationVertical, 4)];
    }
    NSStackView *form = LTStack(rows, NSUserInterfaceLayoutOrientationVertical, 10);
    form.translatesAutoresizingMaskIntoConstraints = YES;
    form.frame = NSMakeRect(0, 0, 340, form.fittingSize.height);
    a.accessoryView = form;
    [a addButtonWithTitle:@"Add"];
    [a addButtonWithTitle:@"Cancel"];
    [a beginSheetModalForWindow:self.window
              completionHandler:^(NSModalResponse r) {
                if (r != NSAlertFirstButtonReturn)
                    return;
                NSDictionary *entered = @{
                    @"name" : fields[0].stringValue,
                    @"url" : fields[1].stringValue,
                    @"suggest" : fields[2].stringValue
                };
                NSError *error = nil;
                NSDictionary *engine =
                    LTCustomSearchEngine(entered[@"name"], entered[@"url"], entered[@"suggest"],
                                         self->_store.profile.settings[@"searchEngines"], &error);
                if (!engine) {
                    // The first sheet is still closing; ask again once it has gone.
                    dispatch_async(dispatch_get_main_queue(), ^{
                      [self askForEngine:entered problem:error.localizedDescription];
                    });
                    return;
                }
                [self->_store commit:^(LTProfile *p) {
                  // Checked again against the list as it is when this save runs.
                  NSArray *custom = p.settings[@"searchEngines"];
                  NSDictionary *checked = LTCustomSearchEngine(engine[@"name"], engine[@"url"],
                                                               engine[@"suggest"], custom, NULL);
                  if (!checked)
                      return;
                  p.settings[@"searchEngines"] = [custom ?: @[] arrayByAddingObject:checked];
                  p.settings[@"search"] = checked[@"name"];
                } completion:^(NSError *failure) {
                  if (failure)
                      [self->_store reportWriteFailure:failure];
                  [self reloadEngines];
                }];
              }];
    [a.window makeFirstResponder:fields[problem && [draft[@"name"] length] ? 1 : 0]];
}
- (void)removeEngine:(id)sender {
    NSString *name = _engines.titleOfSelectedItem;
    if (![self customEngineNamed:name])
        return;
    LTConfirm(self.window, [NSString stringWithFormat:@"Remove “%@”?", name],
              [NSString stringWithFormat:@"Lite will search with %@ until you choose another search engine.",
                                         LTDefaultSearchEngine],
              @"Remove", ^{
                [self->_store commit:^(LTProfile *p) {
                  NSMutableArray *kept = [NSMutableArray new];
                  for (NSDictionary *engine in p.settings[@"searchEngines"])
                      if (![engine[@"name"] isEqual:name])
                          [kept addObject:engine];
                  if (kept.count)
                      p.settings[@"searchEngines"] = kept;
                  else
                      [p.settings removeObjectForKey:@"searchEngines"];
                  if ([p.settings[@"search"] isEqual:name])
                      p.settings[@"search"] = LTDefaultSearchEngine;
                } completion:^(NSError *failure) {
                  if (failure)
                      [self->_store reportWriteFailure:failure];
                  [self reloadEngines];
                }];
              });
}
- (void)searchSuggestions:(NSButton *)b {
    BOOL enabled = b.state == NSControlStateValueOn;
    [_store commit:^(LTProfile *p) {
      p.settings[@"searchSuggestions"] = @(enabled);
    } completion:nil];
}
- (void)externalMini:(NSButton *)b {
    BOOL enabled = b.state == NSControlStateValueOn;
    [_store commit:^(LTProfile *p) {
      p.settings[@"externalMini"] = @(enabled);
    } completion:nil];
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
                       : [r[@"securityError"] length] ? r[@"securityError"]
                       : [r[@"complete"] boolValue] ? @"Complete — double-click to open"
                       : [r[@"interrupted"] boolValue] ? r[@"reason"] ?: @"Interrupted — download again from the website"
                       : [r[@"canceled"] boolValue] ? @"Canceled"
                       : [r[@"paused"] boolValue]
                           ? @"Paused"
                           : [r[@"percent"] integerValue] >= 0 ? [NSString stringWithFormat:@"Downloading · %@%%", r[@"percent"]]
                           : [NSString stringWithFormat:@"Downloading · %@", [NSByteCountFormatter stringFromByteCount:[r[@"received"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
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
    } else if ([r[@"complete"] boolValue]) {
        if (![r[@"quarantined"] boolValue])
            LTAlert(self.window, @"Download security metadata is unavailable", @"Lite could not verify this file’s quarantine metadata. It will not open the file automatically. You can reveal it in Finder to inspect it.");
        else [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:r[@"path"]]];
    }
}
- (void)delete:(id)s {
    NSDictionary *r = [self selection];
    if (r) {
        [_store deleteHistoryURL:r[@"url"] completion:^(NSError *error) {
            if (error) LTAlert(self.window, @"Could not finish deleting history", error.localizedDescription);
            [self refresh];
        }];
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
                    [self->_store clearHistorySince:NSDate.date.timeIntervalSince1970 - delta completion:^(NSError *error) {
                        if (error) LTAlert(self.window, @"Could not finish clearing history", error.localizedDescription);
                        [self refresh];
                    }];
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
    if ([r[@"paused"] boolValue] || [r[@"canResume"] boolValue]) self.downloadAction(r, @"resume");
    else if ([r[@"active"] boolValue]) self.downloadAction(r, @"pause");
    else if ([r[@"interrupted"] boolValue]) LTAlert(self.window, @"Download cannot be resumed", r[@"reason"] ?: @"Return to the original website and start the download again. Lite does not replay requests automatically.");
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
