#import "LTFaviconCache.h"
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
NSNotificationName const LTFaviconChanged = @"LTFaviconChanged";
NSString *LTFaviconOrigin(NSString *url) {
    if (!url.length)
        return nil;
    NSURLComponents *u = [NSURLComponents componentsWithString:url];
    if (![@[ @"https", @"http" ] containsObject:u.scheme.lowercaseString] || !u.host.length ||
        u.user.length || u.password.length)
        return nil;
    u.scheme = u.scheme.lowercaseString;
    u.host = u.host.lowercaseString;
    u.path = @"";
    u.query = nil;
    u.fragment = nil;
    if (([u.scheme isEqual:@"https"] && u.port.integerValue == 443) ||
        ([u.scheme isEqual:@"http"] && u.port.integerValue == 80))
        u.port = nil;
    return u.URL.absoluteString;
}
static NSData *Thumbnail(NSData *data) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source)
        return nil;
    NSDictionary *properties =
        CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    double width = [properties[(id)kCGImagePropertyPixelWidth] doubleValue];
    double height = [properties[(id)kCGImagePropertyPixelHeight] doubleValue];
    if (width <= 0 || height <= 0 || width * height > 1024 * 1024) {
        CFRelease(source);
        return nil;
    }
    NSDictionary *options = @{
        (id)kCGImageSourceShouldCache : @NO,
        (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize : @32,
        (id)kCGImageSourceCreateThumbnailWithTransform : @YES
    };
    CGImageRef image =
        CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!image)
        return nil;
    NSData *png = [[[NSBitmapImageRep alloc] initWithCGImage:image]
        representationUsingType:NSBitmapImageFileTypePNG
                     properties:@{}];
    CGImageRelease(image);
    return png;
}
@implementation LTFaviconCache {
    NSString *_directory;
    NSCache<NSString *, NSImage *> *_images;
    NSMapTable<NSString *, NSImage *> *_sources;
    NSMutableSet<NSString *> *_attempted;
    NSMutableArray<NSMutableDictionary *> *_pending;
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *_active;
    NSURLSession *_session;
    NSUInteger _writes;
    BOOL _stopped;
}
- (instancetype)initWithDirectory:(NSString *)directory {
    if ((self = [super init])) {
        _directory = directory;
        [NSFileManager.defaultManager createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:@{NSFilePosixPermissions : @0700}
                                                      error:nil];
        _images = [NSCache new];
        _images.countLimit = 1024;
        _images.totalCostLimit = 4 * 1024 * 1024;
        _sources = [NSMapTable strongToWeakObjectsMapTable];
        _attempted = [NSMutableSet new];
        _pending = [NSMutableArray new];
        _active = [NSMutableDictionary new];
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.HTTPShouldSetCookies = NO;
        config.HTTPCookieStorage = nil;
        config.URLCredentialStorage = nil;
        config.URLCache = nil;
        config.timeoutIntervalForRequest = 8;
        config.timeoutIntervalForResource = 15;
        _session = [NSURLSession sessionWithConfiguration:config
                                                 delegate:self
                                            delegateQueue:NSOperationQueue.mainQueue];
        [self trimDisk];
    }
    return self;
}
- (NSString *)pathForOrigin:(NSString *)origin {
    NSData *bytes = [origin dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString *name = [NSMutableString new];
    for (NSUInteger i = 0; i < sizeof(digest); i++)
        [name appendFormat:@"%02x", digest[i]];
    return [_directory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
}
- (NSImage *)imageForURL:(NSString *)url {
    NSString *origin = LTFaviconOrigin(url);
    if (!origin)
        return nil;
    NSImage *image = [_images objectForKey:origin];
    if (!image) {
        NSData *data = [NSData dataWithContentsOfFile:[self pathForOrigin:origin]];
        if (data.length && data.length <= 32 * 1024) {
            image = [[NSImage alloc] initWithData:data];
            image.size = NSMakeSize(16, 16);
            if (image)
                [_images setObject:image forKey:origin cost:4096];
        }
    }
    return image;
}
- (void)savePNG:(NSData *)png origin:(NSString *)origin {
    if (!png.length || png.length > 32 * 1024)
        return;
    NSImage *image = [[NSImage alloc] initWithData:png];
    if (!image)
        return;
    image.size = NSMakeSize(16, 16);
    [_images setObject:image forKey:origin cost:4096];
    NSString *path = [self pathForOrigin:origin];
    [png writeToFile:path options:NSDataWritingAtomic error:nil];
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions : @0600}
                                   ofItemAtPath:path
                                          error:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:LTFaviconChanged
                                                      object:self
                                                    userInfo:@{@"origin" : origin}];
    if (++_writes % 128 == 0)
        [self trimDisk];
}
- (void)storeImage:(NSImage *)image forURL:(NSString *)url {
    NSString *origin = LTFaviconOrigin(url);
    if (!origin || !image || [_sources objectForKey:origin] == image)
        return;
    [_sources setObject:image forKey:origin];
    [self savePNG:Thumbnail(image.TIFFRepresentation) origin:origin];
}
- (void)prefetchNodes:(NSArray<LTNode *> *)nodes {
    if (_stopped)
        return;
    for (LTNode *node in nodes) {
        NSString *origin = LTFaviconOrigin(node.url);
        if (!origin || [_attempted containsObject:origin])
            continue;
        [_attempted addObject:origin];
        NSDictionary *attributes =
            [NSFileManager.defaultManager attributesOfItemAtPath:[self pathForOrigin:origin]
                                                           error:nil];
        if (attributes && [attributes[NSFileModificationDate] timeIntervalSinceNow] > -30 * 86400)
            continue;
        NSString *icon = LTFaviconOrigin(node.favicon)
                             ? node.favicon
                             : [origin stringByAppendingString:@"/favicon.ico"];
        [_pending addObject:[@{@"origin" : origin, @"url" : icon, @"page" : node.url, @"stage" : @0}
                                mutableCopy]];
    }
    [self pump];
}
- (void)pump {
    if (_stopped)
        return;
    while (_active.count < 4 && _pending.count) {
        NSMutableDictionary *job = _pending.firstObject;
        [_pending removeObjectAtIndex:0];
        NSMutableURLRequest *request =
            [NSMutableURLRequest requestWithURL:[NSURL URLWithString:job[@"url"]]];
        [request setValue:@"image/*,text/html;q=0.5" forHTTPHeaderField:@"Accept"];
        NSURLSessionDataTask *task = [_session dataTaskWithRequest:request];
        job[@"data"] = [NSMutableData new];
        job[@"redirects"] = @0;
        _active[@(task.taskIdentifier)] = job;
        [task resume];
    }
}
- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    NSMutableDictionary *job = _active[@(task.taskIdentifier)];
    NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
    BOOL accept =
        status >= 200 && status < 300 &&
        ([job[@"stage"] integerValue] == 1 || response.expectedContentLength <= 512 * 1024);
    job[@"valid"] = @(accept);
    completion(accept ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data {
    NSMutableDictionary *job = _active[@(task.taskIdentifier)];
    NSMutableData *buffer = job[@"data"];
    NSUInteger limit = [job[@"stage"] integerValue] == 1 ? 128 * 1024 : 512 * 1024;
    if (buffer.length + data.length > limit) {
        if ([job[@"stage"] integerValue] == 1) {
            [buffer appendData:[data subdataWithRange:NSMakeRange(0, limit - buffer.length)]];
            job[@"truncatedHead"] = @YES;
        } else
            job[@"valid"] = @NO;
        [task cancel];
    } else
        [buffer appendData:data];
}
- (void)URLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completion {
    NSMutableDictionary *job = _active[@(task.taskIdentifier)];
    NSInteger redirects = [job[@"redirects"] integerValue] + 1;
    job[@"redirects"] = @(redirects);
    BOOL downgrade =
        [response.URL.scheme isEqual:@"https"] && ![request.URL.scheme isEqual:@"https"];
    completion(redirects <= 4 && !downgrade && LTFaviconOrigin(request.URL.absoluteString) ? request
                                                                                           : nil);
}
- (void)URLSession:(NSURLSession *)session
                   task:(NSURLSessionTask *)task
    didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
      completionHandler:
          (void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    completion([challenge.protectionSpace.authenticationMethod
                   isEqual:NSURLAuthenticationMethodServerTrust]
                   ? NSURLSessionAuthChallengePerformDefaultHandling
                   : NSURLSessionAuthChallengeCancelAuthenticationChallenge,
               nil);
}
- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    NSMutableDictionary *job = _active[@(task.taskIdentifier)];
    [_active removeObjectForKey:@(task.taskIdentifier)];
    if (_stopped || !job)
        return;
    NSData *png = [job[@"valid"] boolValue] && !error ? Thumbnail(job[@"data"]) : nil;
    if (png)
        [self savePNG:png origin:job[@"origin"]];
    else if ([job[@"stage"] integerValue] == 0) {
        job[@"stage"] = @1;
        job[@"url"] = job[@"page"];
        [_pending addObject:job];
    } else if ([job[@"stage"] integerValue] == 1 && [job[@"valid"] boolValue] &&
               (!error || [job[@"truncatedHead"] boolValue])) {
        NSString *html = [[NSString alloc] initWithData:job[@"data"] encoding:NSUTF8StringEncoding];
        // The bounded head may end in the middle of a UTF-8 character.
        NSData *head = job[@"data"];
        for (NSUInteger trim = 1;
             !html && [job[@"truncatedHead"] boolValue] && trim <= 3 && trim < head.length; trim++)
            html = [[NSString alloc]
                initWithData:[head subdataWithRange:NSMakeRange(0, head.length - trim)]
                    encoding:NSUTF8StringEncoding];
        if (!html)
            html = [[NSString alloc] initWithData:head encoding:NSISOLatin1StringEncoding];
        NSRegularExpression *links =
            [NSRegularExpression regularExpressionWithPattern:@"<link\\b[^>]*>"
                                                      options:NSRegularExpressionCaseInsensitive
                                                        error:nil];
        NSRegularExpression *rel = [NSRegularExpression
            regularExpressionWithPattern:@"\\brel\\s*=\\s*['\"][^'\"]*\\bicon\\b[^'\"]*['\"]"
                                 options:NSRegularExpressionCaseInsensitive
                                   error:nil];
        NSRegularExpression *href =
            [NSRegularExpression regularExpressionWithPattern:@"\\bhref\\s*=\\s*['\"]([^'\"]+)['\"]"
                                                      options:NSRegularExpressionCaseInsensitive
                                                        error:nil];
        for (NSTextCheckingResult *match in [links matchesInString:html ?: @""
                                                           options:0
                                                             range:NSMakeRange(0, html.length)]) {
            NSString *tag = [html substringWithRange:match.range];
            NSTextCheckingResult *target = [href firstMatchInString:tag
                                                            options:0
                                                              range:NSMakeRange(0, tag.length)];
            if (!target || ![rel firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)])
                continue;
            NSString *address =
                [[NSURL URLWithString:[tag substringWithRange:[target rangeAtIndex:1]]
                        relativeToURL:task.response.URL] absoluteURL]
                    .absoluteString;
            if (!LTFaviconOrigin(address) ||
                ([task.response.URL.scheme isEqual:@"https"] &&
                 ![[NSURL URLWithString:address].scheme isEqual:@"https"]))
                continue;
            job[@"url"] = address;
            job[@"stage"] = @2;
            [_pending addObject:job];
            break;
        }
    }
    [self pump];
}
- (void)trimDisk {
    NSArray<NSURL *> *files = [NSFileManager.defaultManager
          contentsOfDirectoryAtURL:[NSURL fileURLWithPath:_directory]
        includingPropertiesForKeys:@[ NSURLFileSizeKey, NSURLContentModificationDateKey ]
                           options:NSDirectoryEnumerationSkipsHiddenFiles
                             error:nil];
    NSUInteger total = 0;
    for (NSURL *url in files) {
        NSNumber *size;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        total += size.unsignedIntegerValue;
    }
    if (total <= 64 * 1024 * 1024)
        return;
    files = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
      NSDate *first, *second;
      [a getResourceValue:&first forKey:NSURLContentModificationDateKey error:nil];
      [b getResourceValue:&second forKey:NSURLContentModificationDateKey error:nil];
      return [first compare:second];
    }];
    for (NSURL *url in files) {
        NSNumber *size;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        total -= MIN(total, size.unsignedIntegerValue);
        if (total <= 48 * 1024 * 1024)
            break;
    }
}
- (void)shutdown {
    _stopped = YES;
    [_pending removeAllObjects];
    [_session invalidateAndCancel];
    [self trimDisk];
}
@end
