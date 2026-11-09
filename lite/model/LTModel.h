#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *LTUUID(void);
FOUNDATION_EXPORT NSError *LTError(NSString *message);
FOUNDATION_EXPORT BOOL LTValidURL(NSString *url);
FOUNDATION_EXPORT NSString *LTURLFromInput(NSString *input, NSString *provider);
FOUNDATION_EXPORT NSString *LTSearchURL(NSString *query, NSString *provider);
// How many recently closed tabs and windows a profile keeps.
FOUNDATION_EXPORT const NSUInteger LTClosedLimit;

@interface LTNode : NSObject <NSCopying>
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *kind; // folder, pinned, temporary, favorite
@property (nonatomic, copy) NSString *spaceID;
@property (nonatomic, copy) NSString *parentID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *customTitle;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *pinnedURL;
@property (nonatomic, copy) NSString *favicon;
@property (nonatomic) NSInteger order;
@property (nonatomic) BOOL expanded;
@property (nonatomic) double lastUsed;
@property (nonatomic, readonly) NSString *displayTitle;
+ (instancetype)fromJSON:(NSDictionary *)json;
- (NSDictionary *)JSON;
@end

@interface LTSpace : NSObject <NSCopying>
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *selectedID;
+ (instancetype)fromJSON:(NSDictionary *)json;
- (NSDictionary *)JSON;
@end

@interface LTProfile : NSObject
@property (nonatomic) NSMutableArray<LTSpace *> *spaces;
@property (nonatomic) NSMutableArray<LTNode *> *nodes;
@property (nonatomic) NSMutableDictionary *settings;
@property (nonatomic) NSMutableArray<NSDictionary *> *windows;
@property (nonatomic, copy) NSString *activeSpaceID;
// Recently closed tabs and windows, oldest first, at most LTClosedLimit. Each entry has `id`, `type`
// ("tab" or "window"), `closed` (seconds since 1970) and either `node`, a temporary tab's JSON, or
// `state`, a window's restoration state. Clearing or deleting history removes matching entries.
@property (nonatomic) NSMutableArray<NSDictionary *> *closed;
+ (instancetype)fresh;
+ (nullable instancetype)fromJSON:(NSDictionary *)json error:(NSError **)error;
- (NSDictionary *)JSON;
- (LTProfile *)transactionCopy;
// Builds lookups for a model that will no longer change. LTStore seals each model on its writer
// before publishing it, so these are cheap on the main thread however long the sidebar is.
- (void)seal;
- (nullable LTNode *)node:(NSString *)identifier;
// Every node in a Space, keyed by parent identifier ("" for the top level), in sidebar order.
- (NSDictionary<NSString *, NSArray<LTNode *> *> *)childrenInSpace:(NSString *)space;
- (nullable LTSpace *)space:(NSString *)identifier;
- (NSArray<LTNode *> *)children:(NSString *)parent
                          space:(NSString *)space
                           kind:(nullable NSString *)kind;
- (LTSpace *)addSpace:(NSString *)name;
- (LTNode *)addNode:(NSString *)kind
              title:(NSString *)title
                url:(NSString *)url
              space:(NSString *)space
             parent:(NSString *)parent;
- (BOOL)moveNode:(NSString *)identifier
           space:(NSString *)space
          parent:(NSString *)parent
           index:(NSInteger)index
           error:(NSError **)error;
- (void)removeNode:(NSString *)identifier;
- (void)removeSpace:(NSString *)identifier;
- (BOOL)validate:(NSError **)error;
// Record a closed temporary tab or window, dropping the oldest entry beyond LTClosedLimit. A tab
// whose address cannot be reopened is not recorded.
- (void)noteClosedTab:(LTNode *)node time:(double)time;
- (void)noteClosedWindow:(NSDictionary *)state time:(double)time;
// The newest entry of this type ("tab" or "window"), or of any type when `type` is nil.
- (nullable NSDictionary *)latestClosed:(nullable NSString *)type;
// Removes and returns the entry with this `id`, or nil if another reopen already took it.
- (nullable NSDictionary *)takeClosed:(NSString *)identifier;
// For history deletion. Each returns whether anything changed. `time` <= 0 forgets everything.
- (BOOL)forgetClosedSince:(double)time;
// Drops closed tabs at `url` and that address's saved scroll positions in closed windows.
- (BOOL)forgetClosedURL:(NSString *)url;
@end
NS_ASSUME_NONNULL_END
