#import "../browser/LTEngine.h"
#import "../model/LTLoginStore.h"
#import <Cocoa/Cocoa.h>
FOUNDATION_EXPORT NSString *LTLoginReadScript(NSString *origin);
FOUNDATION_EXPORT NSString *LTLoginFillScript(NSDictionary *entry, NSString *password);
@interface LTPasswords : NSObject
- (instancetype)initWithStore:(LTLoginStore *)store;
- (void)saveForPage:(LTPage *)page window:(NSWindow *)window;
- (void)fillForPage:(LTPage *)page window:(NSWindow *)window;
- (void)manageForWindow:(NSWindow *)window;
@end
