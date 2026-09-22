#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSString *LTLoginOrigin(NSString *url);
@interface LTLoginStore : NSObject
- (instancetype)initWithProfilePath:(NSString *)path;
- (NSArray<NSDictionary *> *)entriesForOrigin:(NSString *)origin error:(NSError **)error;
- (NSArray<NSDictionary *> *)keychainEntriesForOrigin:(NSString *)origin error:(NSError **)error;
- (NSString *)githubToken:(NSError **)error;
- (BOOL)setGitHubToken:(NSString *)token error:(NSError **)error;
- (BOOL)saveUsername:(NSString *)username
            password:(NSString *)password
              origin:(NSString *)origin
               error:(NSError **)error;
- (NSString *)passwordForEntry:(NSDictionary *)entry error:(NSError **)error;
- (BOOL)deleteEntry:(NSDictionary *)entry error:(NSError **)error;
@end
