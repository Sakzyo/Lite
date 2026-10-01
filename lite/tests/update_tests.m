#import "../macos/LTUpdater.h"
#import <Sparkle/Sparkle.h>
#import <Sparkle/SPUAppcastItemStateResolver.h>
// Pinned-framework parser integration; private API is isolated to this test binary.
@interface SUAppcast (FixtureParsing)
- (instancetype)initWithXMLData:(NSData *)data relativeToURL:(NSURL *)url stateResolver:(SPUAppcastItemStateResolver *)state signingValidationStatus:(SPUAppcastSigningValidationStatus)status error:(NSError **)error;
@end
static int passed, failed;
static void check(BOOL value, NSString *name) {
    if (value) passed++; else { failed++; fprintf(stderr, "FAIL: %s\n", name.UTF8String); }
}
int main(void) {
    @autoreleasepool {
        NSDictionary *installed = @{ @"CFBundleVersion": @"12", @"LTProfileSchemaVersion": @1, @"LTArchitecture": @"arm64" };
        NSDictionary *item = @{ @"lite:minimumProfileSchema": @"1", @"lite:maximumProfileSchema": @"1", @"lite:architecture": @"arm64" };
        check(LTUpdateIsCompatible(item, @"13", installed, NULL), @"compatible higher build");
        NSString *xml = @"<?xml version='1.0'?><rss version='2.0' xmlns:sparkle='http://www.andymatuschak.org/xml-namespaces/sparkle' xmlns:lite='https://lite.app/xml-namespaces/updates'><channel><item><sparkle:version>13</sparkle:version><enclosure url='https://updates.example.invalid/Lite.zip' length='1000' type='application/octet-stream'/><lite:minimumProfileSchema>1</lite:minimumProfileSchema><lite:maximumProfileSchema>1</lite:maximumProfileSchema><lite:architecture>arm64</lite:architecture></item></channel></rss>";
        SUStandardVersionComparator *comparator = [SUStandardVersionComparator defaultComparator];
        SPUAppcastItemStateResolver *state = [[SPUAppcastItemStateResolver alloc] initWithHostVersion:@"12" applicationVersionComparator:comparator standardVersionComparator:comparator];
        NSError *parseError = nil;
        SUAppcast *feed = [[SUAppcast alloc] initWithXMLData:[xml dataUsingEncoding:NSUTF8StringEncoding] relativeToURL:[NSURL URLWithString:@"https://updates.example.invalid/appcast.xml"] stateResolver:state signingValidationStatus:0 error:&parseError];
        check(feed.items.count == 1 && !parseError && LTUpdateIsCompatible(feed.items.firstObject.propertiesDictionary, feed.items.firstObject.versionString, installed, NULL), @"real Sparkle XML compatibility metadata parsing");

        for (id version in @[@"11", @"12", @"0", @"13junk", @"13.1", NSNull.null])
            check(!LTUpdateIsCompatible(item, version, installed, NULL), @"reject downgrade or malformed build");
        for (NSDictionary *bad in @[@{}, @{ @"lite:minimumProfileSchema": @"2", @"lite:maximumProfileSchema": @"3", @"lite:architecture": @"arm64" }, @{ @"lite:minimumProfileSchema": @"1", @"lite:maximumProfileSchema": @"1", @"lite:architecture": @"x86_64" }])
            check(!LTUpdateIsCompatible(bad, @"13", installed, NULL), @"reject incompatible architecture/schema");
        NSMutableDictionary *configuration = [@{ @"LTUpdatesEnabled": @YES, @"SUFeedURL": @"https://updates.example.invalid/appcast.xml", @"SUPublicEDKey": @"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", @"SUVerifyUpdateBeforeExtraction": @YES, @"SURequireSignedFeed": @YES, @"SUSignedFeedFailureExpirationInterval": @0 } mutableCopy];
        check(LTUpdateConfigurationValid(configuration), @"signed-feed configuration");
        for (NSString *key in configuration.allKeys) {
            NSMutableDictionary *missing = [configuration mutableCopy]; [missing removeObjectForKey:key];
            check(!LTUpdateConfigurationValid(missing), @"missing configuration fails closed");
        }
        configuration[@"SUFeedURL"] = @"http://updates.example.invalid/appcast.xml";
        check(!LTUpdateConfigurationValid(configuration), @"reject insecure transport");
        configuration[@"SUFeedURL"] = @"https://user:password@updates.example.invalid/appcast.xml";
        check(!LTUpdateConfigurationValid(configuration), @"reject embedded credentials");
        printf("%d updater policy checks passed, %d failed\n", passed, failed);
    }
    return failed ? 1 : 0;
}
