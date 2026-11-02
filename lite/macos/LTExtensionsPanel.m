#import "LTExtensionsPanel.h"
#import "LTUI.h"

NSImage *LTExtensionIcon(LTExtension *extension) {
    NSImage *icon = extension.iconPath ? [[NSImage alloc] initWithContentsOfFile:extension.iconPath] : nil;
    if (!icon) icon = [NSImage imageWithSystemSymbolName:@"puzzlepiece.extension" accessibilityDescription:nil];
    icon.size = NSMakeSize(16, 16);
    return icon;
}

@interface LTExtensionPopup : NSObject <LTPageDelegate, NSPopoverDelegate>
@property (nonatomic) NSPopover *popover;
@property (nonatomic) LTPage *page;
@property (nonatomic, copy) void (^openURL)(NSString *url);
@end
static NSMutableSet<LTExtensionPopup *> *openPopups;
@implementation LTExtensionPopup
- (void)pageChanged:(LTPage *)page {
    NSSize size = page.preferredSize;
    if (size.width >= 1 && size.height >= 1 && !NSEqualSizes(size, _popover.contentSize))
        _popover.contentSize = size;
}
- (void)pageClosed:(LTPage *)page {
    [_popover close];
    [openPopups removeObject:self];
}
- (void)pageCloseCanceled:(LTPage *)page {
}
- (void)page:(LTPage *)page openURL:(NSString *)url {
    if (_openURL) _openURL(url);
    [_popover close];
}
- (void)page:(LTPage *)page downloadChanged:(NSDictionary *)download {
}
- (void)popoverDidClose:(NSNotification *)notification {
    if (_page.alive) [_page closeConfirmed];
    else [openPopups removeObject:self];
}
@end

NSPopover *LTShowExtensionPopup(LTExtension *extension, LTBrowserContext *context, NSView *view,
                                void (^openURL)(NSString *url)) {
    NSString *url = [extension URLForPage:extension.popup];
    if (!url) return nil;
    if (!openPopups) openPopups = [NSMutableSet new];
    LTExtensionPopup *popup = [LTExtensionPopup new];
    popup.openURL = openURL;
    popup.page = [[LTPage alloc] initWithID:NSUUID.UUID.UUIDString url:url context:context];
    popup.page.delegate = popup;
    popup.page.visible = YES;
    // Chrome's action popup bounds.
    [popup.page enableAutoResizeWithMinimum:NSMakeSize(25, 25) maximum:NSMakeSize(800, 600)];
    NSViewController *controller = [NSViewController new];
    controller.view = popup.page.container;
    popup.popover = [NSPopover new];
    popup.popover.behavior = NSPopoverBehaviorTransient;
    popup.popover.contentViewController = controller;
    popup.popover.contentSize = NSMakeSize(320, 200);
    popup.popover.delegate = popup;
    [openPopups addObject:popup];
    [popup.popover showRelativeToRect:view.bounds ofView:view
                        preferredEdge:view.isFlipped ? NSRectEdgeMaxY : NSRectEdgeMinY];
    [popup.page loadIfNeeded];
    [popup.page focus];
    return popup.popover;
}

@interface LTExtensionsPanel () <NSTableViewDataSource, NSTableViewDelegate>
@end
@implementation LTExtensionsPanel {
    LTExtensions *_extensions;
    NSTableView *_table;
    NSButton *_addFolder, *_addStore, *_update, *_options, *_remove;
    NSStackView *_restartRow;
    NSTextField *_status;
    NSProgressIndicator *_progress;
    BOOL _busy;
}
- (instancetype)initWithExtensions:(LTExtensions *)extensions {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 780, 460)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"Extensions";
    panel.minSize = NSMakeSize(660, 320);
    if ((self = [super initWithWindow:panel])) {
        _extensions = extensions;
        _table = [NSTableView new];
        for (NSArray *spec in @[ @[ @"icon", @"", @24 ], @[ @"enabled", @"On", @34 ], @[ @"name", @"Extension", @270 ],
                                 @[ @"source", @"Source", @120 ], @[ @"status", @"Status", @250 ] ]) {
            NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
            column.title = spec[1];
            column.width = [spec[2] doubleValue];
            column.editable = [spec[0] isEqual:@"enabled"];
            [_table addTableColumn:column];
        }
        NSButtonCell *toggle = [NSButtonCell new];
        [toggle setButtonType:NSButtonTypeSwitch];
        toggle.title = @"";
        toggle.accessibilityLabel = @"Extension enabled";
        [_table tableColumnWithIdentifier:@"enabled"].dataCell = toggle;
        [_table tableColumnWithIdentifier:@"icon"].dataCell = [NSImageCell new];
        _table.dataSource = self;
        _table.delegate = self;
        _table.rowHeight = 26;
        _table.target = self;
        _table.doubleAction = @selector(openOptions:);
        _table.accessibilityLabel = @"Extensions";
        NSScrollView *scroll = [NSScrollView new];
        scroll.documentView = _table;
        scroll.hasVerticalScroller = YES;
        _addFolder = [NSButton buttonWithTitle:@"Add Folder…" target:self action:@selector(addFolder:)];
        _addStore = [NSButton buttonWithTitle:@"Add from Chrome Web Store…" target:self action:@selector(addFromStore:)];
        _update = [NSButton buttonWithTitle:@"Update" target:self action:@selector(update:)];
        _options = [NSButton buttonWithTitle:@"Options" target:self action:@selector(openOptions:)];
        _remove = [NSButton buttonWithTitle:@"Remove…" target:self action:@selector(remove:)];
        _progress = [NSProgressIndicator new];
        _progress.style = NSProgressIndicatorStyleSpinning;
        _progress.controlSize = NSControlSizeSmall;
        _progress.displayedWhenStopped = NO;
        _status = LTLabel(@"", 11, NSFontWeightRegular);
        _status.textColor = NSColor.secondaryLabelColor;
        NSView *spacer = [NSView new];
        [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *buttons = LTStack(@[ _addFolder, _addStore, _progress, _status, spacer, _update, _options, _remove ],
                                       NSUserInterfaceLayoutOrientationHorizontal, 8);
        NSTextField *restartLabel = LTLabel(@"Restart Lite to apply extension changes.", 12, NSFontWeightMedium);
        NSButton *restart = [NSButton buttonWithTitle:@"Restart Lite" target:self action:@selector(restart:)];
        restart.bezelColor = NSColor.controlAccentColor;
        _restartRow = LTStack(@[ restartLabel, restart ], NSUserInterfaceLayoutOrientationHorizontal, 10);
        NSTextField *hint = LTLabel(
            @"Extensions run in regular windows, not private ones. Content scripts, background service workers, "
            @"messaging, storage, popups and options pages work. Lite has no Chrome tab strip, so APIs that "
            @"create Chrome tabs or windows may not respond.", 11, NSFontWeightRegular);
        hint.maximumNumberOfLines = 0;
        hint.textColor = NSColor.secondaryLabelColor;
        [hint setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *stack = LTStack(@[ _restartRow, scroll, buttons, hint ], NSUserInterfaceLayoutOrientationVertical, 12);
        LTPin(stack, panel.contentView, 16);
        for (NSView *view in @[ scroll, buttons, hint ])
            [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
        [panel center];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
                                                   name:LTExtensionsChanged object:extensions];
        [self refresh];
    }
    return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)present {
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    [self refresh];
}
- (void)refresh {
    NSString *selected = [self selected].identifier;
    [_table reloadData];
    NSArray *extensions = _extensions.extensions;
    for (NSUInteger i = 0; i < extensions.count; i++)
        if ([[extensions[i] identifier] isEqual:selected])
            [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
    _restartRow.hidden = !_extensions.restartRequired;
    [self updateButtons];
}
- (LTExtension *)selected {
    NSInteger row = _table.selectedRow;
    return row >= 0 && row < (NSInteger)_extensions.extensions.count ? _extensions.extensions[row] : nil;
}
- (BOOL)running:(LTExtension *)extension {
    for (LTExtension *launched in _extensions.launched)
        if ([launched.identifier isEqual:extension.identifier] && [launched.path isEqual:extension.path]) return YES;
    return NO;
}
- (void)updateButtons {
    LTExtension *extension = [self selected];
    _addFolder.enabled = _addStore.enabled = !_busy;
    _update.enabled = !_busy && [extension.source isEqual:@"webstore"];
    _options.enabled = extension.options && [self running:extension];
    _remove.enabled = !_busy && extension;
}
- (NSString *)statusFor:(LTExtension *)extension {
    if (extension.problem) return extension.problem;
    BOOL running = [self running:extension];
    if (!extension.enabled) return running ? @"Turns off after restart" : @"Off";
    return running ? @"Running" : @"Loads after restart";
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _extensions.extensions.count;
}
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    LTExtension *extension = _extensions.extensions[row];
    NSString *identifier = column.identifier;
    if ([identifier isEqual:@"icon"]) return LTExtensionIcon(extension);
    if ([identifier isEqual:@"enabled"]) return @(extension.enabled);
    if ([identifier isEqual:@"name"])
        return extension.version.length ? [NSString stringWithFormat:@"%@  %@", extension.name, extension.version] : extension.name;
    if ([identifier isEqual:@"source"]) return [extension.source isEqual:@"webstore"] ? @"Chrome Web Store" : @"Folder";
    return [self statusFor:extension];
}
- (void)tableView:(NSTableView *)tableView setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if (![column.identifier isEqual:@"enabled"] || row >= (NSInteger)_extensions.extensions.count) return;
    NSError *error = nil;
    if (![_extensions setEnabled:[value boolValue] identifier:_extensions.extensions[row].identifier error:&error])
        LTAlert(self.window, @"The extension could not be changed", error.localizedDescription);
}
- (NSString *)tableView:(NSTableView *)tableView toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect
            tableColumn:(NSTableColumn *)column row:(NSInteger)row mouseLocation:(NSPoint)location {
    LTExtension *extension = _extensions.extensions[row];
    NSMutableArray *lines = [NSMutableArray arrayWithObject:extension.name];
    if (extension.summary.length) [lines addObject:extension.summary];
    for (NSString *warning in extension.warnings) [lines addObject:[@"• " stringByAppendingString:warning]];
    [lines addObject:[@"ID: " stringByAppendingString:extension.identifier]];
    [lines addObject:extension.path];
    return [lines componentsJoinedByString:@"\n"];
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateButtons];
}
- (void)addFolder:(id)sender {
    NSOpenPanel *open = [NSOpenPanel openPanel];
    open.canChooseDirectories = YES;
    open.canChooseFiles = NO;
    open.prompt = @"Add Extension";
    open.message = @"Choose an unpacked extension folder that contains manifest.json.";
    [open beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        NSError *error = nil;
        LTExtension *extension = [self->_extensions addUnpackedAtPath:open.URL.path error:&error];
        if (extension) [self confirmAdded:extension];
        else dispatch_async(dispatch_get_main_queue(), ^{
            LTAlert(self.window, @"The extension could not be added", error.localizedDescription);
        });
    }];
}
- (void)addFromStore:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Add from Chrome Web Store";
    alert.informativeText = @"Paste the extension’s Chrome Web Store link or ID. Lite downloads it from Google and checks the Web Store and developer signatures before installing it.";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 380, 24)];
    field.placeholderString = @"https://chromewebstore.google.com/detail/…";
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;
    [alert addButtonWithTitle:@"Add"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSString *identifier = LTWebStoreExtensionID(field.stringValue);
        if (identifier) [self installFromWebStore:identifier];
        else dispatch_async(dispatch_get_main_queue(), ^{
            LTAlert(self.window, @"That is not a Chrome Web Store extension",
                    @"Use a link that starts with https://chromewebstore.google.com/detail/, or the extension’s 32-letter ID.");
        });
    }];
}
- (void)installFromWebStore:(NSString *)identifier {
    [self present];
    if (_busy) return;
    LTExtension *previous = [_extensions extensionWithIdentifier:identifier];
    NSString *previousVersion = previous.problem ? nil : previous.version;
    _busy = YES;
    [_progress startAnimation:nil];
    _status.stringValue = @"Downloading from Chrome Web Store…";
    [self updateButtons];
    [_extensions installFromWebStore:identifier completion:^(LTExtension *extension, NSError *error) {
        self->_busy = NO;
        [self->_progress stopAnimation:nil];
        self->_status.stringValue = @"";
        [self refresh];
        if (!extension)
            LTAlert(self.window, @"The extension could not be added", error.localizedDescription);
        else if (!previous)
            [self confirmAdded:extension];
        else
            LTAlert(self.window, [NSString stringWithFormat:@"%@ %@", extension.name, extension.version],
                    [extension.version isEqual:previousVersion] ? @"This is the latest version." :
                        @"The new version is installed. Restart Lite to use it.");
    }];
}
// Nothing runs until Chromium restarts, so the user can review access first.
- (void)confirmAdded:(LTExtension *)extension {
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"“%@” was added", extension.name];
    NSString *access = extension.warnings.count ?
        [@"After Lite restarts, it will be able to:\n• " stringByAppendingString:[extension.warnings componentsJoinedByString:@"\n• "]] :
        @"It requests no special access. It loads after Lite restarts.";
    alert.informativeText = access;
    alert.icon = extension.iconPath ? [[NSImage alloc] initWithContentsOfFile:extension.iconPath] : nil;
    [alert addButtonWithTitle:@"Keep"];
    [alert addButtonWithTitle:@"Remove"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertSecondButtonReturn) [self->_extensions removeIdentifier:extension.identifier error:nil];
    }];
}
- (void)update:(id)sender {
    LTExtension *extension = [self selected];
    if ([extension.source isEqual:@"webstore"]) [self installFromWebStore:extension.identifier];
}
- (void)openOptions:(id)sender {
    LTExtension *extension = [self selected];
    if (extension.options && [self running:extension] && _openURL) _openURL([extension URLForPage:extension.options]);
}
- (void)remove:(id)sender {
    LTExtension *extension = [self selected];
    if (!extension) return;
    LTConfirm(self.window, [NSString stringWithFormat:@"Remove “%@”?", extension.name],
        [extension.source isEqual:@"webstore"] ?
            @"It stops running after Lite restarts, and its installed files are deleted then. Data it stored in this profile is kept." :
            @"It stops running after Lite restarts. The extension folder is not changed.",
        @"Remove", ^{
            NSError *error = nil;
            if (![self->_extensions removeIdentifier:extension.identifier error:&error])
                LTAlert(self.window, @"The extension could not be removed", error.localizedDescription);
        });
}
- (void)restart:(id)sender {
    [NSNotificationCenter.defaultCenter postNotificationName:@"LTRestart" object:nil];
}
@end
