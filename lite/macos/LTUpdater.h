#import <Cocoa/Cocoa.h>

BOOL LTUpdateConfigurationValid(NSDictionary *info);
BOOL LTUpdateIsCompatible(NSDictionary *properties, NSString *version, NSDictionary *installed,
                          NSError **error);

@interface LTUpdater : NSObject
- (void)start;
- (void)checkForUpdates:(id)sender;
@end
