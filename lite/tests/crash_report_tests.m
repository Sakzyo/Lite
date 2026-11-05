#import "../model/LTCrashReports.h"
#import "../model/LTWebsiteData.h"
static int passed, failed;
static void Check(BOOL result, NSString *name) {
    if (result) passed++;
    else { failed++; fprintf(stderr, "FAIL: %s\n", name.UTF8String); }
}
// Stands in for the network, so these tests can never reach a real endpoint.
static NSMutableArray<NSURLRequest *> *requests;
static NSMutableArray<NSData *> *bodies;
static NSInteger responseStatus = 200;
static NSURL *redirectTarget;
@interface LTFakeUpload : NSURLProtocol
@end
@implementation LTFakeUpload
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSMutableData *body = [NSMutableData new];
    NSInputStream *stream = self.request.HTTPBodyStream;
    [stream open];
    uint8_t buffer[8192];
    NSInteger count;
    while (stream && (count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) [body appendBytes:buffer length:(NSUInteger)count];
    [stream close];
    if (self.request.HTTPBody) [body appendData:self.request.HTTPBody];
    [requests addObject:self.request];
    [bodies addObject:body];
    NSDictionary *headers = redirectTarget ? @{@"Location": redirectTarget.absoluteString} : @{};
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:redirectTarget ? 302 : responseStatus HTTPVersion:@"HTTP/1.1" headerFields:headers];
    if (redirectTarget) {
        NSURLRequest *next = [NSURLRequest requestWithURL:redirectTarget];
        [self.client URLProtocol:self wasRedirectedToRequest:next redirectResponse:response];
    }
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
static NSString *Root;
static NSString *Dump(NSString *directory, NSString *name, NSTimeInterval age) {
    NSString *folder = [Root stringByAppendingPathComponent:[@"Chromium" stringByAppendingPathComponent:directory]];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [folder stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"dmp"]];
    [[name dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:NO];
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-age]} ofItemAtPath:path error:nil];
    return path;
}
static BOOL Exists(NSString *path) { return [NSFileManager.defaultManager fileExistsAtPath:path]; }
static void Reset(void) {
    [NSFileManager.defaultManager removeItemAtPath:Root error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:Root withIntermediateDirectories:YES attributes:nil error:nil];
    [requests removeAllObjects];
    [bodies removeAllObjects];
    responseStatus = 200;
    redirectTarget = nil;
}
static LTCrashReports *Reports(NSString *url) {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[LTFakeUpload.class];
    return [[LTCrashReports alloc] initWithProfilePath:Root uploadURL:LTCrashUploadURL(url) configuration:configuration];
}
static void Send(LTCrashReports *reports, NSArray *list, NSUInteger *sent, NSUInteger *failures) {
    __block BOOL done = NO;
    [reports sendReports:list completion:^(NSUInteger s, NSUInteger f) { *sent = s; *failures = f; done = YES; }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done && [deadline timeIntervalSinceNow] > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    Check(done, @"Upload finished");
}
int main(void) { @autoreleasepool {
    requests = [NSMutableArray new];
    bodies = [NSMutableArray new];
    Root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *endpoint = @"https://o1.ingest.sentry.io/api/2/minidump/?sentry_key=public";
    NSUInteger sent = 0, failures = 0;

    Check(LTCrashUploadURL(endpoint) != nil, @"HTTPS endpoint accepted");
    Check(LTCrashUploadURL(@"http://127.0.0.1:18743/crash-upload") != nil, @"Loopback fixture accepted");
    for (NSString *bad in @[@"", @"http://sentry.io/minidump", @"ftp://sentry.io/", @"https://user:pw@sentry.io/", @"http://localhost.evil.test/", @"not a url"])
        Check(LTCrashUploadURL(bad) == nil, [@"Rejected endpoint " stringByAppendingString:bad]);

    Reset();
    NSString *pending = Dump(@"pending", @"pending-report", 3600), *completed = Dump(@"completed", @"completed-report", 3600);
    NSString *fresh = Dump(@"new", @"in-progress", 60), *expired = Dump(@"pending", @"expired", 8 * 86400);
    LTCrashReports *reports = Reports(endpoint);
    Check(reports.canUpload && reports.reports.count == 0, @"Nothing is offered before launch preparation");
    [reports prepareForLaunch];
    Check([reports.reports containsObject:pending] && [reports.reports containsObject:completed] && reports.reports.count == 2, @"Only finished, retained reports are offered");
    Check(!Exists(expired), @"Expired report deleted");
    Check(Exists(fresh), @"In-progress report kept");
    Check(requests.count == 0, @"Preparing and listing send nothing");

    Reset();
    NSString *alone = Dump(@"pending", @"no-endpoint", 60);
    reports = Reports(nil);
    [reports prepareForLaunch];
    Check(!reports.canUpload, @"No endpoint disables upload");
    Send(reports, reports.reports, &sent, &failures);
    Check(sent == 0 && failures == 1 && requests.count == 0 && Exists(alone), @"No endpoint sends nothing and keeps the report");

    Reset();
    NSString *before = Dump(@"pending", @"before-private", 3600);
    NSString *marker = [Root stringByAppendingPathComponent:@"PrivateSession.marker"];
    reports = Reports(endpoint);
    [reports prepareForLaunch];
    [reports notePrivateSession];
    Check(Exists(marker), @"Private session recorded before any private page");
    Check([[NSFileManager.defaultManager attributesOfItemAtPath:marker error:nil][NSFilePosixPermissions] isEqual:@0600], @"Private marker is owner-only");
    NSString *during = Dump(@"pending", @"during-private", 0), *late = Dump(@"completed", @"after-private-closed", 0), *writing = Dump(@"new", @"still-writing", 0);
    reports = Reports(endpoint);
    [reports prepareForLaunch];
    Check(!Exists(during) && !Exists(late) && !Exists(writing), @"Every report from a private run deleted");
    Check(Exists(before) && [reports.reports isEqual:@[before]], @"Report from before the private session kept");
    Check(!Exists(marker), @"Marker cleared after a successful purge");

    Reset();
    NSString *identifier = @"with-attachments";
    NSString *declined = Dump(@"pending", identifier, 60);
    NSString *attachments = [[Root stringByAppendingPathComponent:@"Chromium/attachments"] stringByAppendingPathComponent:identifier];
    [NSFileManager.defaultManager createDirectoryAtPath:attachments withIntermediateDirectories:YES attributes:nil error:nil];
    reports = Reports(endpoint);
    [reports prepareForLaunch];
    [reports discardReports:reports.reports];
    Check(!Exists(declined) && !Exists(attachments) && reports.reports.count == 0 && requests.count == 0, @"Declining deletes the report and sends nothing");

    Reset();
    NSString *first = Dump(@"pending", @"first-report", 60), *second = Dump(@"completed", @"second-report", 60);
    reports = Reports(endpoint);
    reports.uploadFields = @{@"product": @"Lite", @"sentry[release]": @"lite@1.0"};
    [reports prepareForLaunch];
    Send(reports, @[first], &sent, &failures);
    Check(sent == 1 && failures == 0 && requests.count == 1, @"Only the approved report is sent");
    Check(!Exists(first) && Exists(second) && [reports.reports isEqual:@[second]], @"Sent report deleted; unapproved report untouched");
    NSURLRequest *request = requests.firstObject;
    NSString *body = [[NSString alloc] initWithData:bodies.firstObject encoding:NSUTF8StringEncoding];
    Check([request.HTTPMethod isEqual:@"POST"] && [request.URL.absoluteString isEqual:endpoint], @"Report posted to the configured endpoint");
    Check([body containsString:@"name=\"upload_file_minidump\"; filename=\"first-report.dmp\""] && [body containsString:@"\r\n\r\nfirst-report\r\n"], @"Body carries the minidump");
    Check([body containsString:@"name=\"sentry[release]\""] && [body containsString:@"lite@1.0"], @"Body carries the release");
    Check(!request.allHTTPHeaderFields[@"Cookie"] && !request.HTTPShouldHandleCookies, @"Upload carries no cookies");

    Reset();
    NSString *rejected = Dump(@"pending", @"rejected", 60);
    reports = Reports(endpoint);
    [reports prepareForLaunch];
    responseStatus = 429;
    Send(reports, reports.reports, &sent, &failures);
    Check(sent == 0 && failures == 1 && Exists(rejected) && reports.reports.count == 1, @"Rejected upload keeps the report");

    Reset();
    NSString *redirected = Dump(@"pending", @"redirected", 60);
    reports = Reports(endpoint);
    [reports prepareForLaunch];
    redirectTarget = [NSURL URLWithString:@"https://elsewhere.invalid/collect"];
    Send(reports, reports.reports, &sent, &failures);
    Check(requests.count == 1 && Exists(redirected) && sent == 0, @"Redirect is not followed");

    Reset();
    NSString *real = Dump(@"pending", @"real", 60);
    NSString *link = [[real stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"link.dmp"];
    [NSFileManager.defaultManager createSymbolicLinkAtPath:link withDestinationPath:[Root stringByAppendingPathComponent:@"Lite.sqlite"] error:nil];
    reports = Reports(endpoint);
    [reports prepareForLaunch];
    Check([reports.reports isEqual:@[real]], @"Symbolic links are never offered");

    Reset();
    NSString *cleared = Dump(@"pending", @"cleared", 60);
    NSError *error = nil; BOOL didClear = NO;
    LTRequestWebsiteDataClear(Root, &error);
    Check(LTPerformPendingWebsiteDataClear(Root, &didClear, &error) && didClear && !Exists(cleared), @"Clear Browsing Data removes crash reports");

    [NSFileManager.defaultManager removeItemAtPath:Root error:nil];
    printf("crash report tests: %d passed, %d failed\n", passed, failed);
    return failed ? 1 : 0;
} }
