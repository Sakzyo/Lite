#import "../browser/LTEngine.h"
typedef NS_ENUM(NSInteger, LTLifecycleAction) {
    LTLifecycleKeep,
    LTLifecycleFreeze,
    LTLifecycleDiscard
};
FOUNDATION_EXPORT LTLifecycleAction LTPolicy(NSString *mode, double idle, BOOL protectedPage,
                                             BOOL pressure);
@interface LTPerformance : NSObject
@property (nonatomic, copy) NSArray<LTPage *> * (^pages)(void);
@property (nonatomic, copy) NSString * (^mode)(void);
- (void)start;
- (void)stop;
- (void)reclaim:(BOOL)pressure;
@end
