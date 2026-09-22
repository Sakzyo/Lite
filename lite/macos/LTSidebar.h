#import "../model/LTStore.h"
#import <Cocoa/Cocoa.h>
@interface LTSidebar : NSVisualEffectView
@property (nonatomic, copy) void (^selected)(NSString *identifier);
@property (nonatomic, copy) void (^spaceSelected)(NSString *identifier);
@property (nonatomic, copy) void (^command)(NSString *command, NSString *identifier);
@property (nonatomic, copy) NSDictionary * (^pageState)(NSString *identifier);
- (instancetype)initWithStore:(LTStore *)store header:(NSView *)header;
- (void)refreshSpace:(NSString *)spaceID selected:(NSString *)selectedID;
- (void)updateItem:(NSString *)identifier;
@end
