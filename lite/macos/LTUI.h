#import <Cocoa/Cocoa.h>
FOUNDATION_EXPORT NSButton *LTButton(NSString *symbol, NSString *help, id target, SEL action);
FOUNDATION_EXPORT NSTextField *LTLabel(NSString *text, CGFloat size, NSFontWeight weight);
FOUNDATION_EXPORT NSStackView *
LTStack(NSArray<NSView *> *views, NSUserInterfaceLayoutOrientation orientation, CGFloat spacing);
FOUNDATION_EXPORT void LTPin(NSView *child, NSView *parent, CGFloat inset);
FOUNDATION_EXPORT void LTAlert(NSWindow *window, NSString *title, NSString *message);
FOUNDATION_EXPORT void LTAskName(NSWindow *window, NSString *title, NSString *value,
                                 void (^completion)(NSString *));
FOUNDATION_EXPORT void LTConfirm(NSWindow *window, NSString *title, NSString *message,
                                 NSString *action, void (^completion)(void));
@interface LTDropButton : NSButton
@property (nonatomic, copy) NSString *itemID;
@property (nonatomic, copy) void (^drop)(NSString *identifier);
@end
