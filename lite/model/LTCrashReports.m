#import "LTCrashReports.h"
#import <os/log.h>

static const NSTimeInterval RetentionSeconds = 7 * 24 * 60 * 60;
static const unsigned long long MaxUploadBytes = 25 * 1024 * 1024;

NSURL *LTCrashUploadURL(NSString *value) {
    NSURL *url = value.length ? [NSURL URLWithString:value] : nil;
    if (!url.host.length || url.user || url.password) return nil;
    if ([url.scheme isEqual:@"https"]) return url;
    return [url.scheme isEqual:@"http"] && [url.host isEqual:@"127.0.0.1"] ? url : nil;
}

// Any redirect would resend the report to a host the user was not told about.
@interface LTCrashUploadDelegate : NSObject <NSURLSessionTaskDelegate>
@end
@implementation LTCrashUploadDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}
@end

@implementation LTCrashReports {
    NSString *_profile;
    NSURL *_url;
    NSURLSessionConfiguration *_configuration;
    NSArray<NSString *> *_reports;
    BOOL _privateNoted;
}
- (instancetype)initWithProfilePath:(NSString *)path uploadURL:(NSURL *)url {
    return [self initWithProfilePath:path uploadURL:url
                       configuration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
}
- (instancetype)initWithProfilePath:(NSString *)path uploadURL:(NSURL *)url
                      configuration:(NSURLSessionConfiguration *)configuration {
    self = [super init];
    _profile = [path copy];
    _url = url;
    _configuration = configuration;
    _configuration.HTTPShouldSetCookies = NO;
    _configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    _configuration.URLCache = nil;
    _reports = @[];
    _uploadFields = @{};
    return self;
}
- (BOOL)canUpload { return _url != nil; }
- (NSString *)markerPath { return [_profile stringByAppendingPathComponent:@"PrivateSession.marker"]; }
- (NSArray<NSString *> *)dumpsIn:(NSArray<NSString *> *)directories {
    NSFileManager *files = NSFileManager.defaultManager;
    NSMutableArray *dumps = [NSMutableArray new];
    for (NSString *name in directories) {
        NSString *directory = [[_profile stringByAppendingPathComponent:@"Chromium"] stringByAppendingPathComponent:name];
        for (NSString *entry in [files contentsOfDirectoryAtPath:directory error:nil]) {
            NSString *path = [directory stringByAppendingPathComponent:entry];
            if ([entry.pathExtension isEqual:@"dmp"] &&
                [[files attributesOfItemAtPath:path error:nil].fileType isEqual:NSFileTypeRegular])
                [dumps addObject:path];
        }
    }
    return dumps;
}
- (BOOL)remove:(NSString *)report {
    NSFileManager *files = NSFileManager.defaultManager;
    BOOL removed = [files removeItemAtPath:report error:nil];
    NSString *identifier = report.lastPathComponent.stringByDeletingPathExtension;
    NSString *chromium = report.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    [files removeItemAtPath:[chromium stringByAppendingPathComponent:[@"attachments" stringByAppendingPathComponent:identifier]] error:nil];
    return removed;
}
- (void)prepareForLaunch {
    NSFileManager *files = NSFileManager.defaultManager;
    NSArray *all = [self dumpsIn:@[@"new", @"pending", @"completed"]];
    BOOL privateRun = [files fileExistsAtPath:self.markerPath];
    NSDate *privateSince = [files attributesOfItemAtPath:self.markerPath error:nil].fileModificationDate;
    NSDate *oldest = [NSDate dateWithTimeIntervalSinceNow:-RetentionSeconds];
    BOOL purged = YES;
    for (NSString *path in all) {
        NSDate *date = [files attributesOfItemAtPath:path error:nil].fileModificationDate;
        // An unreadable date cannot show that a report came before the private session.
        BOOL fromPrivateRun = privateRun && (!date || !privateSince || [date compare:privateSince] != NSOrderedAscending);
        if (!fromPrivateRun && date && [date compare:oldest] != NSOrderedAscending) continue;
        if (![self remove:path]) {
            purged = NO;
            os_log_error(OS_LOG_DEFAULT, "Lite could not delete an expired or private crash report");
        }
    }
    // Keep the marker on failure, so the next launch retries, and offer nothing.
    if (purged && privateRun) purged = [files removeItemAtPath:self.markerPath error:nil];
    _reports = purged ? [self dumpsIn:@[@"pending", @"completed"]] : @[];
}
- (void)notePrivateSession {
    if (_privateNoted) return;
    _privateNoted = YES;
    // Written before the private window exists, so no private page can crash first.
    NSDictionary *attributes = @{NSFilePosixPermissions: @0600};
    if (![NSFileManager.defaultManager createFileAtPath:self.markerPath contents:[NSData data] attributes:attributes])
        os_log_error(OS_LOG_DEFAULT, "Lite could not record a private session for crash reports");
}
- (void)discardReports:(NSArray<NSString *> *)reports {
    for (NSString *report in reports) [self remove:report];
    [self forget:reports];
}
- (void)forget:(NSArray<NSString *> *)reports {
    NSMutableArray *remaining = [_reports mutableCopy];
    [remaining removeObjectsInArray:reports];
    _reports = remaining;
}
- (NSData *)bodyForReport:(NSData *)report name:(NSString *)name boundary:(NSString *)boundary {
    NSMutableData *body = [NSMutableData new];
    void (^text)(NSString *) = ^(NSString *string) { [body appendData:[string dataUsingEncoding:NSUTF8StringEncoding]]; };
    for (NSString *field in _uploadFields)
        text([NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n", boundary, field, _uploadFields[field]]);
    text([NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"upload_file_minidump\"; filename=\"%@\"\r\nContent-Type: application/octet-stream\r\n\r\n", boundary, name]);
    [body appendData:report];
    text([NSString stringWithFormat:@"\r\n--%@--\r\n", boundary]);
    return body;
}
- (void)sendReports:(NSArray<NSString *> *)reports completion:(void (^)(NSUInteger, NSUInteger))completion {
    if (!_url) { completion(0, reports.count); return; }
    NSURLSession *session = [NSURLSession sessionWithConfiguration:_configuration delegate:[LTCrashUploadDelegate new] delegateQueue:NSOperationQueue.mainQueue];
    [self send:reports index:0 sent:0 session:session completion:^(NSUInteger sent, NSUInteger failed) {
        [session finishTasksAndInvalidate];
        completion(sent, failed);
    }];
}
- (void)send:(NSArray<NSString *> *)reports index:(NSUInteger)index sent:(NSUInteger)sent
     session:(NSURLSession *)session completion:(void (^)(NSUInteger, NSUInteger))completion {
    if (index == reports.count) { completion(sent, reports.count - sent); return; }
    NSString *path = reports[index];
    unsigned long long size = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileSize;
    NSData *report = size && size <= MaxUploadBytes ? [NSData dataWithContentsOfFile:path] : nil;
    if (!report) { [self send:reports index:index + 1 sent:sent session:session completion:completion]; return; }
    NSString *boundary = NSUUID.UUID.UUIDString;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60];
    request.HTTPMethod = @"POST";
    request.HTTPShouldHandleCookies = NO;
    [request setValue:[@"multipart/form-data; boundary=" stringByAppendingString:boundary] forHTTPHeaderField:@"Content-Type"];
    NSData *body = [self bodyForReport:report name:path.lastPathComponent boundary:boundary];
    [[session uploadTaskWithRequest:request fromData:body completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        BOOL accepted = !error && status >= 200 && status < 300;
        if (accepted) [self discardReports:@[path]];
        [self send:reports index:index + 1 sent:sent + accepted session:session completion:completion];
    }] resume];
}
- (NSArray<NSString *> *)reports { return _reports; }
@end
