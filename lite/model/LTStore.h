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
// The SQLite schema this build writes. A database with a higher `user_version` fails closed.
extern const int LTStoreSchemaVersion;
// History retention, applied on the writer after visits: visits older than LTHistoryMaxAge seconds
// are dropped, then the least frecent URLs beyond LTHistoryMaxURLs.
extern const NSTimeInterval LTHistoryMaxAge;
extern const NSUInteger LTHistoryMaxURLs;
// A visit's weight halves every LTHistoryHalfLife seconds.
extern const NSTimeInterval LTHistoryHalfLife;
extern NSString *const LTHistoryMatchExact;
extern NSString *const LTHistoryMatchAddress;
extern NSString *const LTHistoryMatchWord;
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
// Queued; recorded in order with saves. A visit that fails is logged, not reported. Each visit adds
// one to the URL's visit count and to its frecency. Private stores record nothing.
- (void)recordVisit:(NSString *)url title:(NSString *)title;
// Queued like a visit, but only renames an already recorded URL: a page that changes its own title
// while it stays open is not visited again.
- (void)updateVisitTitle:(NSString *)title url:(NSString *)url;
// History reads use their own connection and never wait for a write. They see committed rows only.
// Newest first; `query` matches any part of the URL or title. For the History panel.
- (NSArray<NSDictionary *> *)history:(NSString *)query limit:(NSInteger)limit;
// For the Command Bar. Rows rank by match, then by frecency. `match` in each row says how it matched:
// LTHistoryMatchExact (the whole URL or title), LTHistoryMatchAddress (the start of the address after
// any scheme and "www.", such as "gith" for github.com), or LTHistoryMatchWord (every word of `query`
// starts a word of the title or address). An empty query lists the most frecent rows with no `match`.
// Each row also has `url`, `title`, `visited` (last visit) and `visits`.
- (NSArray<NSDictionary *> *)searchHistory:(NSString *)query limit:(NSInteger)limit;
// Drops visits older than `cutoff`, then the least frecent URLs beyond `maxURLs`. The store already
// does this on the writer with LTHistoryMaxAge and LTHistoryMaxURLs after the first visit it records
// and at most hourly after that; this blocking form is for tests.
- (BOOL)pruneHistoryBefore:(double)cutoff keeping:(NSUInteger)maxURLs error:(NSError **)error;
- (void)clearHistorySince:(double)time;
- (BOOL)clearHistorySince:(double)time error:(NSError **)error;
- (void)clearHistorySince:(double)time completion:(LTStoreCompletion)completion;
- (void)deleteHistoryURL:(NSString *)url;
- (BOOL)deleteHistoryURL:(NSString *)url error:(NSError **)error;
- (void)deleteHistoryURL:(NSString *)url completion:(LTStoreCompletion)completion;
@end
NS_ASSUME_NONNULL_END
