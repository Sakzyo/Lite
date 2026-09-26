#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL LTFilterYouTubeResponse(NSString *url, NSString *type, NSString *mimeType);
FOUNDATION_EXPORT BOOL LTIsYouTubeURL(NSString *url);

// Immutable compiled rules, shared by every regular and private browser context.
@interface LTContentBlocker : NSObject
@property (nonatomic, readonly) NSDictionary *provenance;
+ (nullable instancetype)shared;
- (nullable instancetype)initWithDirectory:(NSString *)directory;
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
@end
NS_ASSUME_NONNULL_END
