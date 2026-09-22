#import "LTStore.h"
#import "LTLoginStore.h"
FOUNDATION_EXPORT NSString *LTGitHubQuery(NSDictionary *configuration, NSError **error);
FOUNDATION_EXPORT NSArray<NSDictionary *> *LTGitHubPullRequests(NSDictionary *response, NSError **error);
FOUNDATION_EXPORT void LTApplyGitHubPullRequests(LTProfile *profile, NSString *folderID, NSArray<NSDictionary *> *pulls, NSSet<NSString *> *openIDs);
@interface LTGitHub : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, copy) NSSet<NSString *> *(^openIDs)(void);
@property (nonatomic, readonly) LTLoginStore *logins;
- (instancetype)initWithStore:(LTStore *)store logins:(LTLoginStore *)logins;
- (void)start;
- (void)stop;
- (void)refreshFolder:(NSString *)identifier;
- (void)refreshAll;
- (NSString *)statusForFolder:(NSString *)identifier;
@end
