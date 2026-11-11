#import "../browser/LTEngine.h"
#import "../model/LTStore.h"
#import <Cocoa/Cocoa.h>
@class LTFaviconCache, LTLoginStore, LTGitHub, LTDownloadHistory, LTExtensions;
@interface LTWindow : NSWindowController <LTPageDelegate>
@property (nonatomic, readonly) LTStore *store;
@property (nonatomic, readonly) BOOL mini;
@property (nonatomic, readonly) NSArray<LTPage *> *pages;
@property (nonatomic) LTGitHub *github;
/// Profile extensions; nil in private windows.
@property (nonatomic) LTExtensions *extensions;
@property (nonatomic, copy) void (^promote)(NSString *url, NSString *spaceID);
@property (nonatomic, copy) void (^didClose)(LTWindow *window);
- (instancetype)initWithStore:(LTStore *)store
                         mini:(BOOL)mini
                      restore:(NSDictionary *)state
                        icons:(LTFaviconCache *)icons
                       logins:(LTLoginStore *)logins;
- (void)setDownloadHistory:(LTDownloadHistory *)history;
- (void)captureSessionStates:(void (^)(void))completion;
- (void)openURL:(NSString *)url;
// `next` runs once the tab exists and is selected. Saves are queued, so that is not before this returns.
- (void)openURL:(NSString *)url then:(nullable void (^)(void))next;
- (void)performCommand:(NSString *)command;
// Tabs this window shows, or whose pages are busy: playing, capturing, downloading, holding
// unsaved work, kept awake or in Picture in Picture. Auto-archive never closes these.
- (NSSet<NSString *> *)tabsInUse;
// Closes an idle temporary tab into Recently Closed without asking. Does nothing for a tab that
// is in use, no longer temporary, or was used again within the archive interval.
- (void)archiveTab:(NSString *)identifier;
- (NSDictionary *)restorationState;
- (void)showOnboarding;
@end
