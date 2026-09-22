#import "LTTaskManager.h"
#import "../browser/LTEngine.h"
#import "LTUI.h"
@interface LTTaskManager () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@end
@implementation LTTaskManager {
    NSTableView *_table;
    NSArray<NSDictionary *> *_rows;
    NSTimer *_timer;
    NSButton *_end;
}
- (instancetype)init {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 780, 430)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"Browser Task Manager";
    panel.minSize = NSMakeSize(650, 300);
    if ((self = [super initWithWindow:panel])) {
        panel.delegate = self;
        _rows = @[];
        _table = [NSTableView new];
        for (NSArray *spec in @[@[@"title", @"Task", @350], @[@"cpu", @"CPU", @90],
                                @[@"memory", @"Memory", @110], @[@"gpu", @"GPU memory", @110]]) {
            NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
            column.title = spec[1];
            column.width = [spec[2] doubleValue];
            column.editable = NO;
            column.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:spec[0]
                ascending:[spec[0] isEqual:@"title"]];
            [_table addTableColumn:column];
        }
        _table.dataSource = self;
        _table.delegate = self;
        _table.rowHeight = 28;
        _table.accessibilityLabel = @"Browser tasks";
        NSScrollView *scroll = [NSScrollView new];
        scroll.documentView = _table;
        scroll.hasVerticalScroller = YES;
        _end = [NSButton buttonWithTitle:@"End Process…" target:self action:@selector(end:)];
        NSTextField *hint = LTLabel(@"CPU and memory are shared by tasks in the same process. Do not add rows together.", 11, NSFontWeightRegular);
        hint.textColor = NSColor.secondaryLabelColor;
        NSStackView *stack = LTStack(@[scroll, hint, _end], NSUserInterfaceLayoutOrientationVertical, 12);
        LTPin(stack, panel.contentView, 16);
        [scroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
        [panel center];
    }
    return self;
}
- (void)present {
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    [self refresh];
    [_timer invalidate];
    __weak typeof(self) weak = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
        [weak refresh];
    }];
}
- (void)refresh {
    NSNumber *selected = _table.selectedRow >= 0 && _table.selectedRow < _rows.count
        ? _rows[_table.selectedRow][@"id"] : nil;
    _rows = [LTBrowserTasks() sortedArrayUsingDescriptors:_table.sortDescriptors];
    [_table reloadData];
    [_table deselectAll:nil];
    for (NSUInteger i = 0; i < _rows.count; i++)
        if ([_rows[i][@"id"] isEqual:selected])
            [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
    [self tableViewSelectionDidChange:[NSNotification notificationWithName:NSTableViewSelectionDidChangeNotification object:_table]];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return _rows.count; }
- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray *)oldDescriptors {
    [self refresh];
}
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    id value = _rows[row][column.identifier];
    if ([column.identifier isEqual:@"title"])
        return value;
    if ([_rows[row][@"memory"] longLongValue] == 0)
        return @"—";
    if ([column.identifier isEqual:@"cpu"])
        return [value doubleValue] < 0 ? @"—" : [NSString stringWithFormat:@"%.1f%%", [value doubleValue]];
    return [value longLongValue] < 0 ? @"—" : [NSByteCountFormatter stringFromByteCount:[value longLongValue] countStyle:NSByteCountFormatterCountStyleMemory];
}
- (void)tableViewSelectionDidChange:(NSNotification *)note {
    NSInteger row = _table.selectedRow;
    _end.enabled = row >= 0 && row < _rows.count && [_rows[row][@"killable"] boolValue] &&
                   ![_rows[row][@"browser"] boolValue];
}
- (void)end:(id)sender {
    NSInteger row = _table.selectedRow;
    if (row < 0 || row >= _rows.count || !_end.enabled)
        return;
    NSDictionary *task = _rows[row];
    LTConfirm(self.window, @"End this browser process?",
        [NSString stringWithFormat:@"%@\nUnsaved changes in this process may be lost. Other tabs sharing the process may also stop. Reload affected tabs to recover.", task[@"title"]],
        @"End Process", ^{
            if (!LTEndBrowserTask(task[@"id"]))
                LTAlert(self.window, @"Process could not be ended", @"The task may have already ended, or Chromium protects this process.");
            [self refresh];
        });
}
- (void)windowWillClose:(NSNotification *)note {
    [_timer invalidate];
    _timer = nil;
    LTStopBrowserTaskMonitoring();
}
- (void)dealloc { [_timer invalidate]; }
@end
