#import "../model/LTWebsiteData.h"
#include <unistd.h>
#include <sys/stat.h>
static int passed, failed;
static void Check(BOOL result, NSString *name) {
    if (result) passed++;
    else { failed++; fprintf(stderr, "FAIL: %s\n", name.UTF8String); }
}
int main(void) { @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"Chromium/Default/IndexedDB"] withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [@"synthetic" dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *name in @[@"Lite.sqlite", @"Logins.vault", @"Chromium/Default/Cookies", @"Chromium/Default/IndexedDB/test", @"Chromium/Default/Local Storage", @"Chromium/Default/Cache Storage", @"Chromium/Default/Service Worker"])
        [data writeToFile:[root stringByAppendingPathComponent:name] atomically:YES];
    NSError *error = nil; BOOL cleared = NO;
    Check(LTPerformPendingWebsiteDataClear(root, &cleared, &error) && !cleared, @"No request preserves storage");
    Check([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"Chromium/Default/Cookies"]], @"Cookies remain until explicit request");
    NSString *staging = [root stringByAppendingPathComponent:@"ClearWebsiteData.pending.staging"];
    [@"Interrupted marker bytes" writeToFile:staging atomically:NO encoding:NSUTF8StringEncoding error:nil];
    Check(LTPerformPendingWebsiteDataClear(root, &cleared, &error) && !cleared && ![fm fileExistsAtPath:staging], @"Interrupted marker staging is removed without running an uncommitted reset");
    Check([[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"Chromium/Default/Cookies"]] isEqual:data], @"Interrupted marker staging preserves website data");
    Check(LTRequestWebsiteDataClear(root, &error), @"Durable clear request");
    NSString *lock = [root stringByAppendingPathComponent:@"Chromium/SingletonLock"];
    [fm createSymbolicLinkAtPath:lock withDestinationPath:[NSString stringWithFormat:@"fixture-%d", getpid()] error:nil];
    Check(!LTPerformPendingWebsiteDataClear(root, &cleared, &error), @"Running engine blocks reset");
    [fm removeItemAtPath:lock error:nil];
    Check(LTPerformPendingWebsiteDataClear(root, &cleared, &error) && cleared, @"Reset finishes after engine exits");
    Check(![fm fileExistsAtPath:[root stringByAppendingPathComponent:@"Chromium"]], @"Entire engine partition absent");
    Check([[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"Lite.sqlite"]] isEqual:data], @"Organization bytes preserved");
    Check([[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"Logins.vault"]] isEqual:data], @"Credential bytes preserved");
    Check(![fm fileExistsAtPath:[root stringByAppendingPathComponent:@"ClearWebsiteData.pending"]], @"Completion removes intent marker");
    Check(LTRequestWebsiteDataClear(root, &error), @"Request interrupted reset");
    [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"Chromium.pending-clear/nested"] withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:[root stringByAppendingPathComponent:@"Chromium.pending-clear/nested/storage"] atomically:YES];
    NSString *pendingLock = [root stringByAppendingPathComponent:@"Chromium.pending-clear/SingletonLock"];
    [fm createSymbolicLinkAtPath:pendingLock withDestinationPath:[NSString stringWithFormat:@"fixture-%d", getpid()] error:nil];
    error = nil;
    Check(!LTPerformPendingWebsiteDataClear(root, &cleared, &error) && !cleared && error != nil, @"Running engine in interrupted-delete directory blocks removal");
    Check([[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"Chromium.pending-clear/nested/storage"]] isEqual:data] &&
        [fm fileExistsAtPath:[root stringByAppendingPathComponent:@"ClearWebsiteData.pending"]], @"Blocked interrupted deletion retains website bytes and retry marker");
    [fm removeItemAtPath:pendingLock error:nil];
    Check(LTPerformPendingWebsiteDataClear(root, &cleared, &error) && cleared, @"Interrupted deletion resumes");
    Check(![fm fileExistsAtPath:[root stringByAppendingPathComponent:@"Chromium.pending-clear"]], @"Interrupted tree removed before completion");
    [fm createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@"ClearWebsiteData.pending"] withDestinationPath:@"Lite.sqlite" error:nil];
    Check(!LTPerformPendingWebsiteDataClear(root, &cleared, &error), @"Symlink marker rejected");
    Check(!LTRequestWebsiteDataClear(root, &error), @"Existing marker never followed or overwritten");
    [fm removeItemAtPath:[root stringByAppendingPathComponent:@"ClearWebsiteData.pending"] error:nil];
    [fm createSymbolicLinkAtPath:staging withDestinationPath:@"Lite.sqlite" error:nil];
    Check(!LTPerformPendingWebsiteDataClear(root, &cleared, &error) &&
        [[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"Lite.sqlite"]] isEqual:data], @"Unsafe staging symlink fails closed without following its target");
    [fm removeItemAtPath:staging error:nil];
    Check(LTRequestWebsiteDataClear(root, &error), @"Request unsafe tree test");
    [fm createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@"Chromium"] withDestinationPath:NSTemporaryDirectory() error:nil];
    Check(!LTPerformPendingWebsiteDataClear(root, &cleared, &error), @"Symlink engine root rejected");
    [fm removeItemAtPath:root error:nil];
    printf("%d website data checks passed, %d failed\n", passed, failed);
    return failed ? 1 : 0;
} }
