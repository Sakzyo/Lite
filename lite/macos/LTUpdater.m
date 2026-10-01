#import "LTUpdater.h"
#import <Sparkle/Sparkle.h>

static BOOL LTPositiveInteger(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length || value.length > 15)
        return NO;
    return [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location == NSNotFound &&
           value.longLongValue > 0;
}

BOOL LTUpdateConfigurationValid(NSDictionary *info) {
    NSString *feed = info[@"SUFeedURL"], *key = info[@"SUPublicEDKey"];
    if (![feed isKindOfClass:NSString.class] || ![key isKindOfClass:NSString.class]) return NO;
    NSURL *url = [NSURL URLWithString:feed];
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:key options:0];
    return [url.scheme isEqual:@"https"] && url.host.length && !url.user.length && !url.password.length &&
           decoded.length == 32 && [info[@"LTUpdatesEnabled"] isEqual:@YES] &&
           [info[@"SUVerifyUpdateBeforeExtraction"] isEqual:@YES] &&
           [info[@"SURequireSignedFeed"] isEqual:@YES] &&
           [info[@"SUSignedFeedFailureExpirationInterval"] isEqual:@0];
}

BOOL LTUpdateIsCompatible(NSDictionary *properties, NSString *version, NSDictionary *installed,
                          NSError **error) {
    NSString *current = installed[@"CFBundleVersion"];
    NSString *minimum = properties[@"lite:minimumProfileSchema"];
    NSString *maximum = properties[@"lite:maximumProfileSchema"];
    id schema = installed[@"LTProfileSchemaVersion"];
    BOOL compatible = LTPositiveInteger(version) && LTPositiveInteger(current) &&
        version.longLongValue > current.longLongValue && LTPositiveInteger(minimum) &&
        LTPositiveInteger(maximum) && [schema isKindOfClass:NSNumber.class] &&
        [schema longLongValue] >= minimum.longLongValue && [schema longLongValue] <= maximum.longLongValue &&
        [properties[@"lite:architecture"] isEqual:installed[@"LTArchitecture"]];
    if (!compatible && error)
        *error = [NSError errorWithDomain:@"LiteUpdater" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"This update is older than Lite or does not support this architecture and profile version."}];
    return compatible;
}

@interface LTUpdater () <SPUUpdaterDelegate>
@property SPUStandardUpdaterController *controller;
@end
@implementation LTUpdater
- (void)start {
    if (!LTUpdateConfigurationValid(NSBundle.mainBundle.infoDictionary)) return;
    _controller = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO
        updaterDelegate:self userDriverDelegate:nil];
    [_controller startUpdater];
}
- (void)checkForUpdates:(id)sender {
    if (_controller) {
        [_controller checkForUpdates:sender];
        return;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Updates are unavailable in this build";
    alert.informativeText = @"A release build needs a signed update feed and a publisher verification key. This local build does not check for or install updates.";
    [alert addButtonWithTitle:@"OK"];
    if (NSApp.keyWindow) [alert beginSheetModalForWindow:NSApp.keyWindow completionHandler:nil];
    else [alert runModal];
}
- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater {
    return NSBundle.mainBundle.infoDictionary[@"SUFeedURL"];
}
- (BOOL)updater:(SPUUpdater *)updater shouldProceedWithUpdate:(SUAppcastItem *)item
    updateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    if (![item.fileURL.scheme isEqual:@"https"] || ![item.installationType isEqual:@"application"] || item.deltaUpdate || item.deltaUpdates.count) {
        if (error) *error = [NSError errorWithDomain:@"LiteUpdater" code:2 userInfo:@{
            NSLocalizedDescriptionKey: @"Lite requires a complete application update delivered over HTTPS."}];
        return NO;
    }
    return LTUpdateIsCompatible(item.propertiesDictionary, item.versionString,
                                 NSBundle.mainBundle.infoDictionary, error);
}
- (BOOL)updater:(SPUUpdater *)updater shouldDownloadReleaseNotesForUpdate:(SUAppcastItem *)item {
    return NO;
}
- (BOOL)updater:(SPUUpdater *)updater mayPerformUpdateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    return LTUpdateConfigurationValid(NSBundle.mainBundle.infoDictionary);
}
@end
