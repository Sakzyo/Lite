#import <Foundation/Foundation.h>
// The engine must be fully shut down before performing a pending reset.
FOUNDATION_EXPORT BOOL LTRequestWebsiteDataClear(NSString *profilePath, NSError **error);
FOUNDATION_EXPORT BOOL LTPerformPendingWebsiteDataClear(NSString *profilePath, BOOL *cleared, NSError **error);
