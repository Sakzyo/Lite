#import "../model/LTStore.h"
#import <Cocoa/Cocoa.h>
@interface LTCommandPanel : NSWindowController
@property (nonatomic, copy) void (^selected)(NSDictionary *result);
- (instancetype)initWithStore:(LTStore *)store openIDs:(NSSet<NSString *> *)openIDs;
- (void)presentForWindow:(NSWindow *)window initial:(NSString *)text;
@end
