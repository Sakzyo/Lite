#import "../model/LTModel.h"
#import <Cocoa/Cocoa.h>
FOUNDATION_EXPORT NSNotificationName const LTFaviconChanged;
FOUNDATION_EXPORT NSString *LTFaviconOrigin(NSString *url);
@interface LTFaviconCache : NSObject <NSURLSessionDataDelegate>
- (instancetype)initWithDirectory:(NSString *)directory;
- (void)prefetchNodes:(NSArray<LTNode *> *)nodes;
- (NSImage *)imageForURL:(NSString *)url;
- (void)storeImage:(NSImage *)image forURL:(NSString *)url;
- (void)shutdown;
@end
