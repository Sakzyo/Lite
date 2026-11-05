#import "LTModel.h"
NS_ASSUME_NONNULL_BEGIN
extern NSNotificationName const LTStoreChanged;
extern NSNotificationName const LTStoreBackupFailed;
// Posted on the main thread when a queued write fails and no completion handled it.
extern NSNotificationName const LTStoreWriteFailed;
extern NSString *const LTStoreWriteErrorKey;           // NSError in LTStoreWriteFailed
extern NSString *const LTStoreChangeQuietObserverKey;  // Observer that need not redraw for this change
typedef void (^LTProfileChange)(LTProfile *profile);
typedef void (^LTStoreCompletion)(NSError *_Nullable error);
// Call LTStore from the main thread. `profile` is read-only and holds only committed state: it
// changes on the main thread after COMMIT succeeds, so it does not show a write that is still queued.
@interface LTStore : NSObject
@property (nonatomic, readonly) LTProfile *profile;
@property (nonatomic, readonly) BOOL privateMode;
@property (nonatomic, readonly, nullable) NSError *backupError;
+ (BOOL)recoveryAvailableAtPath:(NSString *)path;
+ (BOOL)recoverProfileAtPath:(NSString *)path
             preservedPath:(NSString * _Nullable * _Nullable)preservedPath
                     error:(NSError **)error;
- (nullable instancetype)initWithPath:(nullable NSString *)path error:(NSError **)error;
// Queues a save and returns at once. `change` runs later on the writer, against a copy of the last
// committed profile, so it may touch only that copy and immutable values captured beforehand: never
// AppKit objects, pages or `self->` state. `completion` runs on the main thread after `profile` is
// updated, in submission order. On failure the write is dropped, `profile` stays as it was, and later
// writes still run on top of it. Without a completion a failure posts LTStoreWriteFailed.
- (void)commit:(LTProfileChange)change completion:(nullable LTStoreCompletion)completion;
// As above; `observer` finds itself in LTStoreChanged's userInfo and can skip its redraw.
- (void)commit:(LTProfileChange)change
      quietFor:(nullable id)observer
    completion:(nullable LTStoreCompletion)completion;
// Blocks the main thread until this save and everything queued before it finish, which costs a full
// save. For launch and quit only; everywhere else use commit:completion:.
- (BOOL)commit:(LTProfileChange)change error:(NSError **)error;
// Sends a failure that a completion chose not to handle to the app's single save-failure alert.
- (void)reportWriteFailure:(NSError *)error;
// Waits for queued writes and delivers their results.
- (void)waitForWrites;
// Finishes queued writes, closes the database and refuses later writes. Unlike waitForWrites it runs
// no completions, so it is safe once windows are gone.
- (void)close;
// Queued; recorded in order with saves. A visit that fails is logged, not reported.
- (void)recordVisit:(NSString *)url title:(NSString *)title;
// History reads use their own connection and never wait for a write. They see committed rows only.
- (NSArray<NSDictionary *> *)history:(NSString *)query limit:(NSInteger)limit;
- (NSArray<NSDictionary *> *)history:(NSString *)query limit:(NSInteger)limit exact:(BOOL)exact;
- (void)clearHistorySince:(double)time;
- (BOOL)clearHistorySince:(double)time error:(NSError **)error;
- (void)clearHistorySince:(double)time completion:(LTStoreCompletion)completion;
- (void)deleteHistoryURL:(NSString *)url;
- (BOOL)deleteHistoryURL:(NSString *)url error:(NSError **)error;
- (void)deleteHistoryURL:(NSString *)url completion:(LTStoreCompletion)completion;
@end
NS_ASSUME_NONNULL_END
