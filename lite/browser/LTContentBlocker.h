#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL LTFilterYouTubeResponse(NSString *url, NSString *type, NSString *mimeType);
FOUNDATION_EXPORT BOOL LTIsYouTubeURL(NSString *url);
// Validates the whole custom network filter list; errors identify the offending line.
FOUNDATION_EXPORT BOOL LTValidateCustomFilters(id _Nullable text, NSError * _Nullable * _Nullable error);

typedef NS_ENUM(NSInteger, LTNetworkDecision) {
    LTNetworkNoMatch,
    LTNetworkBlock,
    LTNetworkAllow,
};

// Immutable compiled rules, shared by every regular and private browser context.
@interface LTContentBlocker : NSObject
@property (nonatomic, readonly) NSDictionary *provenance;
// The filter set's `serial` from provenance.json: when it was published, as YYYYMMDDHHMM in UTC.
// 0 for a set without one.
@property (nonatomic, readonly) int64_t serial;
// The filters in use: the last installed set, else the ones bundled with Lite. Safe on any thread.
// Callers should ask again for each decision rather than keep the result, so an update applies to
// the next request.
+ (nullable instancetype)shared;
// Replaces the filters in use. Pages that already applied cosmetic styles keep them until reload.
+ (void)install:(LTContentBlocker *)blocker;
+ (NSString *)bundledDirectory;
- (nullable instancetype)initWithDirectory:(NSString *)directory;
- (LTNetworkDecision)decisionForURL:(NSString *)url initiator:(NSString *)initiator
                              type:(NSString *)type method:(NSString *)method;
- (BOOL)blocksURL:(NSString *)url initiator:(NSString *)initiator
            type:(NSString *)type method:(NSString *)method;
- (NSString *)cosmeticScriptForURL:(NSString *)url;
- (NSString *)youtubeScriptForURL:(NSString *)url;
- (NSString *)siteForHost:(NSString *)host;
@end

// Each window/context owns a policy. Private-window preferences stay in memory.
// All methods are safe on the CEF IO thread; no AppKit or profile objects cross it.
@interface LTBlockingPolicy : NSObject
- (void)updatePreferences:(nullable NSDictionary *)preferences;
- (BOOL)enabledForURL:(NSString *)url;
- (BOOL)cosmeticEnabledForURL:(NSString *)url;
- (BOOL)blocksURL:(NSString *)url initiator:(NSString *)initiator type:(NSString *)type
          method:(NSString *)method topURL:(NSString *)topURL;
@end
NS_ASSUME_NONNULL_END
