#import "LTModel.h"
NS_ASSUME_NONNULL_BEGIN
extern NSNotificationName const LTStoreChanged;
@interface LTStore : NSObject
@property (nonatomic, readonly) LTProfile *profile;
@property (nonatomic, readonly) BOOL privateMode;
- (nullable instancetype)initWithPath:(nullable NSString *)path error:(NSError **)error;
- (BOOL)commit:(void (^)(LTProfile *profile))change error:(NSError **)error;
- (void)recordVisit:(NSString *)url title:(NSString *)title;
- (NSArray<NSDictionary *> *)history:(NSString *)query limit:(NSInteger)limit;
- (NSArray<NSDictionary *> *)history:(NSString *)query limit:(NSInteger)limit exact:(BOOL)exact;
- (void)clearHistorySince:(double)time;
- (void)deleteHistoryURL:(NSString *)url;
@end
NS_ASSUME_NONNULL_END
