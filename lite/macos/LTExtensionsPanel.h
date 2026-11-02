#import <Cocoa/Cocoa.h>
#import "../browser/LTEngine.h"
#import "../model/LTExtensions.h"
@interface LTExtensionsPanel : NSWindowController
@property (nonatomic, copy) void (^openURL)(NSString *url);
- (instancetype)initWithExtensions:(LTExtensions *)extensions;
- (void)present;
- (void)installFromWebStore:(NSString *)identifier;
@end
FOUNDATION_EXPORT NSImage *LTExtensionIcon(LTExtension *extension);
/// Shows an extension's action popup in a transient popover anchored to |view|.
FOUNDATION_EXPORT NSPopover *LTShowExtensionPopup(LTExtension *extension, LTBrowserContext *context,
                                                  NSView *view, void (^openURL)(NSString *url));
