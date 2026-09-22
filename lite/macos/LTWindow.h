#import "../browser/LTEngine.h"
#import "../model/LTStore.h"
#import <Cocoa/Cocoa.h>
@class LTFaviconCache, LTLoginStore, LTGitHub;
@interface LTWindow : NSWindowController <LTPageDelegate>
@property (nonatomic, readonly) LTStore *store;
@property (nonatomic, readonly) BOOL mini;
@property (nonatomic, readonly) NSArray<LTPage *> *pages;
@property (nonatomic) LTGitHub *github;
@property (nonatomic, copy) void (^promote)(NSString *url, NSString *spaceID);
@property (nonatomic, copy) void (^didClose)(LTWindow *window);
- (instancetype)initWithStore:(LTStore *)store
                         mini:(BOOL)mini
                      restore:(NSDictionary *)state
                        icons:(LTFaviconCache *)icons
                       logins:(LTLoginStore *)logins;
- (void)openURL:(NSString *)url;
- (void)performCommand:(NSString *)command;
- (NSDictionary *)restorationState;
- (void)showOnboarding;
@end
