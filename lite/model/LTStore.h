#import "LTModel.h"
NS_ASSUME_NONNULL_BEGIN
extern NSNotificationName const LTStoreChanged;
extern NSNotificationName const LTStoreBackupFailed;
@interface LTStore : NSObject
@property (nonatomic, readonly) LTProfile *profile;
@property (nonatomic, readonly) BOOL privateMode;
@property (nonatomic, readonly, nullable) NSError *backupError;
+ (BOOL)recoveryAvailableAtPath:(NSString *)path;
+ (BOOL)recoverProfileAtPath:(NSString *)path
             preservedPath:(NSString * _Nullable * _Nullable)preservedPath
                     error:(NSError **)error;
- (nullable instancetype)initWithPath:(nullable NSString *)path error:(NSError **)error;
- (BOOL)commit:(void (^)(LTProfile *profile))change error:(NSError **)error;
- (void)recordVisit:(NSString *)url title:(NSString *)title;
- (NSArray<NSDictionary *> *)history:(NSString *)query limit:(NSInteger)limit;
- (NSArray<NSDictionary *> *)history:(NSString *)query limit:(NSInteger)limit exact:(BOOL)exact;
- (void)clearHistorySince:(double)time;
- (BOOL)clearHistorySince:(double)time error:(NSError **)error;
- (void)deleteHistoryURL:(NSString *)url;
- (BOOL)deleteHistoryURL:(NSString *)url error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
