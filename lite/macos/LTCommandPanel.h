#import "../model/LTStore.h"
#import <Cocoa/Cocoa.h>
@interface LTCommandPanel : NSWindowController
@property (nonatomic, copy) void (^selected)(NSDictionary *result);
// `suggestions` fetches search suggestions for this window, or is nil for a window that never asks
// for them, such as a private one.
- (instancetype)initWithStore:(LTStore *)store
                      openIDs:(NSSet<NSString *> *)openIDs
                  suggestions:(LTSearchSuggestions *)suggestions;
- (void)presentForWindow:(NSWindow *)window initial:(NSString *)text;
@end
