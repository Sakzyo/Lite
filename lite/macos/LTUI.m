#import "LTUI.h"
NSButton *LTButton(NSString *symbol, NSString *help, id target, SEL action) {
    NSButton *b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol
                                                      accessibilityDescription:help]
                                     target:target
                                     action:action];
    b.bordered = NO;
    b.bezelStyle = NSBezelStyleTexturedRounded;
    b.toolTip = help;
    b.accessibilityLabel = help;
    [b.widthAnchor constraintEqualToConstant:28].active = YES;
    [b.heightAnchor constraintEqualToConstant:28].active = YES;
    return b;
}
NSTextField *LTLabel(NSString *text, CGFloat size, NSFontWeight weight) {
    NSTextField *t = [NSTextField labelWithString:text];
    t.font = [NSFont systemFontOfSize:size weight:weight];
    t.lineBreakMode = NSLineBreakByTruncatingTail;
    return t;
}
NSStackView *LTStack(NSArray *views, NSUserInterfaceLayoutOrientation orientation,
                     CGFloat spacing) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = orientation;
    s.spacing = spacing;
    s.alignment = orientation == NSUserInterfaceLayoutOrientationVertical
                      ? NSLayoutAttributeLeading
                      : NSLayoutAttributeCenterY;
    return s;
}
void LTPin(NSView *child, NSView *parent, CGFloat inset) {
    child.translatesAutoresizingMaskIntoConstraints = NO;
    [parent addSubview:child];
    [NSLayoutConstraint activateConstraints:@[
        [child.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:inset],
        [child.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-inset],
        [child.topAnchor constraintEqualToAnchor:parent.topAnchor constant:inset],
        [child.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor constant:-inset]
    ]];
}
void LTAlert(NSWindow *window, NSString *title, NSString *message) {
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    a.informativeText = message;
    [a addButtonWithTitle:@"OK"];
    if (window)
        [a beginSheetModalForWindow:window completionHandler:nil];
    else
        [a runModal];
}
void LTAskName(NSWindow *window, NSString *title, NSString *value, void (^completion)(NSString *)) {
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)];
    field.stringValue = value;
    a.accessoryView = field;
    [a addButtonWithTitle:@"Save"];
    [a addButtonWithTitle:@"Cancel"];
    [a beginSheetModalForWindow:window
              completionHandler:^(NSModalResponse r) {
                NSString *s = [field.stringValue
                    stringByTrimmingCharactersInSet:NSCharacterSet
                                                        .whitespaceAndNewlineCharacterSet];
                if (r == NSAlertFirstButtonReturn && s.length)
                    completion(s);
              }];
    [a.window makeFirstResponder:field];
}
void LTConfirm(NSWindow *window, NSString *title, NSString *message, NSString *action,
               void (^completion)(void)) {
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    a.informativeText = message;
    [a addButtonWithTitle:@"Cancel"];
    [a addButtonWithTitle:action];
    [a beginSheetModalForWindow:window
              completionHandler:^(NSModalResponse r) {
                if (r == NSAlertSecondButtonReturn)
                    completion();
              }];
}
@implementation LTDropButton
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame]))
        [self registerForDraggedTypes:@[ @"app.lite.sidebar-item" ]];
    return self;
}
- (void)mouseDragged:(NSEvent *)event {
    if (!self.itemID.length)
        return;
    NSPasteboardItem *pb = [NSPasteboardItem new];
    [pb setString:self.itemID forType:@"app.lite.sidebar-item"];
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:pb];
    [item setDraggingFrame:self.bounds
                  contents:self.image
                               ?: [NSImage imageWithSystemSymbolName:@"globe"
                                            accessibilityDescription:nil]];
    [self beginDraggingSessionWithItems:@[ item ] event:event source:(id<NSDraggingSource>)self];
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return NSDragOperationMove;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return self.drop ? NSDragOperationMove : NSDragOperationNone;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSString *identifier = [sender.draggingPasteboard stringForType:@"app.lite.sidebar-item"];
    if (identifier && self.drop) {
        self.drop(identifier);
        return YES;
    }
    return NO;
}
@end
