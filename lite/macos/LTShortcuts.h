#import <Cocoa/Cocoa.h>
#import "../model/LTStore.h"
NSDictionary *LTNormalizeShortcut(NSString *key, NSEventModifierFlags flags);
BOOL LTValidShortcut(NSDictionary *binding);
@interface LTShortcuts : NSWindowController
- (instancetype)initWithStore:(LTStore *)store menu:(NSMenu *)menu;
- (void)present;
@end
