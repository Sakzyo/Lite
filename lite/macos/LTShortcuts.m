#import "LTShortcuts.h"
#import "LTUI.h"
NSDictionary *LTNormalizeShortcut(NSString *key, NSEventModifierFlags flags) {
    flags &= NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift;
    if (![key isEqual:key.lowercaseString]) flags |= NSEventModifierFlagShift;
    NSString *shifted = @"~!@#$%^&*()_+{}|:\"<>?", *plain = @"`1234567890-=[]\\;',./";
    NSRange index = [shifted rangeOfString:key];
    if (key.length == 1 && index.location != NSNotFound) {
        key = [plain substringWithRange:NSMakeRange(index.location, 1)];
        flags |= NSEventModifierFlagShift;
    }
    return @{@"key": key.lowercaseString ?: @"", @"modifiers": @(key.length ? flags : 0)};
}
BOOL LTValidShortcut(NSDictionary *binding) {
    if (![binding isKindOfClass:NSDictionary.class] || ![binding[@"key"] isKindOfClass:NSString.class] ||
        ![binding[@"modifiers"] isKindOfClass:NSNumber.class]) return NO;
    NSString *key = binding[@"key"];
    NSUInteger flags = [binding[@"modifiers"] unsignedIntegerValue];
    return !key.length || (key.length == 1 && ([key characterAtIndex:0] >= 32 || [@[@"\t", @"\r"] containsObject:key]) &&
        (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) &&
        [LTNormalizeShortcut(key, flags) isEqual:binding]);
}
static NSString *Label(NSDictionary *binding) {
    if (![binding[@"key"] length]) return @"No shortcut";
    NSUInteger flags = [binding[@"modifiers"] unsignedIntegerValue];
    NSString *key = binding[@"key"];
    NSDictionary *names = @{@"\t": @"Tab", @"\r": @"Return", @" ": @"Space", @"\177": @"Delete",
        @"\uF700": @"↑", @"\uF701": @"↓", @"\uF702": @"←", @"\uF703": @"→"};
    NSString *name = names[key] ?: key.uppercaseString;
    unichar character = [key characterAtIndex:0];
    if (character >= NSF1FunctionKey && character <= NSF35FunctionKey)
        name = [NSString stringWithFormat:@"F%u", character - NSF1FunctionKey + 1];
    return [NSString stringWithFormat:@"%@%@%@%@%@", flags & NSEventModifierFlagControl ? @"⌃" : @"",
        flags & NSEventModifierFlagOption ? @"⌥" : @"", flags & NSEventModifierFlagShift ? @"⇧" : @"",
        flags & NSEventModifierFlagCommand ? @"⌘" : @"", name];
}
@interface LTShortcuts () <NSWindowDelegate>
@end
@implementation LTShortcuts {
    LTStore *_store;
    NSMutableArray<NSMenuItem *> *_items;
    NSMutableDictionary *_defaults;
    NSPopUpButton *_commands;
    NSTextField *_current, *_status;
    NSButton *_record;
    id _monitor;
    BOOL _recording;
}
- (instancetype)initWithStore:(LTStore *)store menu:(NSMenu *)menu {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 560, 270)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"Keyboard Shortcuts";
    if ((self = [super initWithWindow:panel])) {
        _store = store;
        _items = [NSMutableArray new];
        _defaults = [NSMutableDictionary new];
        [self collect:menu];
        [self apply];
        panel.delegate = self;
        _commands = [NSPopUpButton new];
        for (NSMenuItem *item in _items)
            [_commands addItemWithTitle:[NSString stringWithFormat:@"%@ — %@", item.menu.title, item.title]];
        _commands.target = self;
        _commands.action = @selector(selection:);
        _current = LTLabel(@"", 22, NSFontWeightMedium);
        _status = [NSTextField wrappingLabelWithString:@"Choose a command, then record a shortcut containing Command or Control."];
        _status.font = [NSFont systemFontOfSize:12];
        _record = [NSButton buttonWithTitle:@"Record Shortcut…" target:self action:@selector(record:)];
        NSStackView *buttons = LTStack(@[_record,
            [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clear:)],
            [NSButton buttonWithTitle:@"Restore Default" target:self action:@selector(reset:)],
            [NSButton buttonWithTitle:@"Reset All…" target:self action:@selector(resetAll:)]],
            NSUserInterfaceLayoutOrientationHorizontal, 8);
        NSStackView *stack = LTStack(@[_commands, _current, _status, buttons], NSUserInterfaceLayoutOrientationVertical, 18);
        LTPin(stack, panel.contentView, 20);
        [_commands.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
        [_status.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
        [self selection:nil];
        [panel center];
    }
    return self;
}
- (void)collect:(NSMenu *)menu {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.submenu) [self collect:item.submenu];
        else if ([item.representedObject isKindOfClass:NSString.class]) {
            [_items addObject:item];
            _defaults[item.representedObject] = LTNormalizeShortcut(item.keyEquivalent, item.keyEquivalentModifierMask);
        }
    }
}
- (void)apply {
    NSDictionary *saved = _store.profile.settings[@"shortcuts"];
    if (![saved isKindOfClass:NSDictionary.class]) saved = @{};
    NSMutableSet *used = [NSMutableSet new];
    for (NSMenuItem *item in _items) {
        NSDictionary *binding = saved[item.representedObject];
        if (!LTValidShortcut(binding)) binding = _defaults[item.representedObject];
        // Corrupt imported preferences must not install duplicate key equivalents.
        if ([binding[@"key"] length] && [used containsObject:binding])
            binding = LTNormalizeShortcut(@"", 0);
        if ([binding[@"key"] length]) [used addObject:binding];
        item.keyEquivalent = binding[@"key"];
        item.keyEquivalentModifierMask = [binding[@"modifiers"] unsignedIntegerValue];
    }
}
- (void)present {
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    [self selection:nil];
    if (_monitor) return;
    __weak typeof(self) weak = self;
    _monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        LTShortcuts *owner = weak;
        if (!owner || !owner->_recording || event.window != owner.window) return event;
        if (event.keyCode == 53) { [owner selection:nil]; return nil; }
        NSDictionary *binding = LTNormalizeShortcut(event.charactersIgnoringModifiers.lowercaseString, event.modifierFlags);
        if (!LTValidShortcut(binding) || ![binding[@"key"] length]) {
            owner->_status.stringValue = @"Include Command or Control and one key. Escape cancels recording.";
            return nil;
        }
        [owner save:binding];
        return nil;
    }];
}
- (void)selection:(id)sender {
    _recording = NO;
    _record.title = @"Record Shortcut…";
    NSMenuItem *item = _items[_commands.indexOfSelectedItem];
    _current.stringValue = Label(LTNormalizeShortcut(item.keyEquivalent, item.keyEquivalentModifierMask));
    _status.stringValue = @"Changes apply immediately in all windows and are saved for the next launch.";
}
- (void)record:(id)sender {
    _recording = YES;
    _record.title = @"Press shortcut…";
    _status.stringValue = @"Press the new shortcut. Escape cancels recording.";
}
- (void)save:(NSDictionary *)binding {
    NSMenuItem *selected = _items[_commands.indexOfSelectedItem];
    for (NSMenuItem *item in _items)
        if (item != selected && [binding[@"key"] length] &&
            [LTNormalizeShortcut(item.keyEquivalent, item.keyEquivalentModifierMask) isEqual:binding]) {
            _status.stringValue = [NSString stringWithFormat:@"Already used by “%@”. Change or clear that shortcut first.", item.title];
            return;
        }
    NSError *error = nil;
    if (![_store commit:^(LTProfile *profile) {
        NSMutableDictionary *saved = [profile.settings[@"shortcuts"] mutableCopy] ?: [NSMutableDictionary new];
        saved[selected.representedObject] = binding;
        profile.settings[@"shortcuts"] = saved;
    } error:&error]) { _status.stringValue = error.localizedDescription; return; }
    [self apply];
    [self selection:nil];
}
- (void)clear:(id)sender { [self save:LTNormalizeShortcut(@"", 0)]; }
- (void)reset:(id)sender { [self save:_defaults[_items[_commands.indexOfSelectedItem].representedObject]]; }
- (void)resetAll:(id)sender {
    _recording = NO;
    LTConfirm(self.window, @"Restore all default shortcuts?", @"Your custom shortcuts will be removed.", @"Restore Defaults", ^{
        NSError *error = nil;
        if (![self->_store commit:^(LTProfile *profile) { [profile.settings removeObjectForKey:@"shortcuts"]; } error:&error])
            LTAlert(self.window, @"Could not save shortcuts", error.localizedDescription);
        [self apply];
        [self selection:nil];
    });
}
- (void)windowWillClose:(NSNotification *)note {
    _recording = NO;
    if (_monitor) { [NSEvent removeMonitor:_monitor]; _monitor = nil; }
}
- (void)dealloc { if (_monitor) [NSEvent removeMonitor:_monitor]; }
@end
