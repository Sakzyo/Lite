#import "LTFilterUpdates.h"
#import "LTModel.h"
#import <CommonCrypto/CommonDigest.h>
#include <math.h>

NSString *const LTFilterFormat = @"lite-filters";
NSNotificationName const LTFilterUpdatesChanged = @"LTFilterUpdatesChanged";
const NSInteger LTFilterFormatVersion = 1;
static const NSUInteger ManifestLimit = 64 * 1024, SignatureLimit = 1024;
static const int64_t FileLimit = 32 * 1024 * 1024, TotalLimit = 64 * 1024 * 1024;
static const int64_t SerialLimit = 999999999999; // YYYYMMDDHHMM
static const double CheckInterval = 24 * 60 * 60;

NSArray<NSString *> *LTFilterFiles(void) {
    return @[ @"network.json", @"cosmetic.json", @"suffixes.txt", @"youtube.js", @"provenance.json",
              @"NOTICE.txt", @"COPYING-uBOL.txt" ];
}
static BOOL Integer(id value, int64_t minimum, int64_t maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())
        return NO;
    double n = [value doubleValue];
    return isfinite(n) && floor(n) == n && n >= minimum && n <= maximum;
}
int64_t LTFilterSerial(NSString *directory) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"provenance.json"]];
    NSDictionary *provenance = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    id serial = [provenance isKindOfClass:NSDictionary.class] ? provenance[@"serial"] : nil;
    return Integer(serial, 1, SerialLimit) ? [serial longLongValue] : 0;
}
NSString *LTFilterSerialDate(int64_t serial) {
    if (serial < 100000000000 || serial > SerialLimit) return nil;
    NSDateComponents *c = [NSDateComponents new];
    c.year = serial / 100000000;
    c.month = serial / 1000000 % 100;
    c.day = serial / 10000 % 100;
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDate *date = [calendar dateFromComponents:c];
    NSDateComponents *back = date ? [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:date] : nil;
    if (!back || back.year != c.year || back.month != c.month || back.day != c.day || serial / 100 % 100 > 23 || serial % 100 > 59)
        return nil;
    NSDateFormatter *f = [NSDateFormatter new];
    f.timeZone = calendar.timeZone;
    f.dateStyle = NSDateFormatterLongStyle;
    return [f stringFromDate:date];
}
NSURL *LTFilterFeedURL(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return nil;
    NSURLComponents *c = [NSURLComponents componentsWithString:text];
    NSString *scheme = c.scheme.lowercaseString, *host = c.host.lowercaseString;
    BOOL local = [@[ @"127.0.0.1", @"localhost", @"::1", @"[::1]" ] containsObject:host ?: @""];
    if (!host.length || c.user.length || c.password.length || c.query || c.fragment ||
        !([scheme isEqual:@"https"] || ([scheme isEqual:@"http"] && local)))
        return nil;
    if (![c.path hasSuffix:@"/"]) c.path = [(c.path ?: @"") stringByAppendingString:@"/"];
    return c.URL;
}
SecKeyRef LTFilterPublicKeyCreate(NSString *base64) {
    if (![base64 isKindOfClass:NSString.class]) return NULL;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    // The SubjectPublicKeyInfo header for an uncompressed P-256 key: id-ecPublicKey, prime256v1.
    static const uint8_t header[] = {0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                                     0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00};
    if (data.length == sizeof(header) + 65 && !memcmp(data.bytes, header, sizeof(header)))
        data = [data subdataWithRange:NSMakeRange(sizeof(header), 65)];
    if (data.length != 65 || ((const uint8_t *)data.bytes)[0] != 0x04) return NULL;
    NSDictionary *attributes = @{(id)kSecAttrKeyType : (id)kSecAttrKeyTypeECSECPrimeRandom,
                                 (id)kSecAttrKeyClass : (id)kSecAttrKeyClassPublic,
                                 (id)kSecAttrKeySizeInBits : @256};
    return SecKeyCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)attributes, NULL);
}
static NSString *SHA256(NSData *data) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}
static BOOL Fail(NSError **error, NSString *message) {
    if (error) *error = LTError(message);
    return NO;
}
static BOOL HexDigest(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 64) return NO;
    return [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]]
               .location == NSNotFound;
}
NSDictionary *LTVerifiedFilterManifest(NSData *manifest, NSData *signature, SecKeyRef key, NSError **error) {
    if (manifest.length > ManifestLimit || signature.length > SignatureLimit) {
        Fail(error, @"The filter manifest or its signature is too large.");
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:signature encoding:NSUTF8StringEncoding];
    NSData *der = [[NSData alloc] initWithBase64EncodedString:
        [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"" options:0];
    if (!der.length || !SecKeyVerifySignature(key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                              (__bridge CFDataRef)manifest, (__bridge CFDataRef)der, NULL)) {
        Fail(error, @"The filter update's signature is not valid.");
        return nil;
    }
    NSDictionary *m = [NSJSONSerialization JSONObjectWithData:manifest options:0 error:nil];
    if (![m isKindOfClass:NSDictionary.class] || ![m[@"format"] isEqual:LTFilterFormat] ||
        !Integer(m[@"version"], 1, INT32_MAX)) {
        Fail(error, @"The filter manifest is not in a format Lite reads.");
        return nil;
    }
    if ([m[@"version"] integerValue] > LTFilterFormatVersion) {
        Fail(error, @"These filters need a newer version of Lite.");
        return nil;
    }
    NSDictionary *files = m[@"files"];
    if (!Integer(m[@"serial"], 1, SerialLimit) || ![files isKindOfClass:NSDictionary.class] ||
        ![[NSSet setWithArray:files.allKeys] isEqual:[NSSet setWithArray:LTFilterFiles()]]) {
        Fail(error, @"The filter manifest is incomplete.");
        return nil;
    }
    int64_t total = 0;
    for (NSString *name in files) {
        NSDictionary *file = files[name];
        if (![file isKindOfClass:NSDictionary.class] || !HexDigest(file[@"sha256"]) || !Integer(file[@"size"], 1, FileLimit)) {
            Fail(error, @"The filter manifest describes a file incorrectly.");
            return nil;
        }
        total += [file[@"size"] longLongValue];
    }
    if (total > TotalLimit) {
        Fail(error, @"The filter update is larger than 64 MB.");
        return nil;
    }
    return m;
}
// Whether `data` is the file the manifest describes.
static BOOL Matches(NSData *data, NSDictionary *file) {
    return data && (int64_t)data.length == [file[@"size"] longLongValue] && [SHA256(data) isEqual:file[@"sha256"]];
}
// The provenance in a set must carry the manifest's serial, so the compiled blocker reports it.
static BOOL ProvenanceMatches(NSData *data, int64_t serial) {
    NSDictionary *p = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [p isKindOfClass:NSDictionary.class] && Integer(p[@"serial"], 1, SerialLimit) &&
           [p[@"serial"] longLongValue] == serial;
}

@interface LTFilterRedirects : NSObject <NSURLSessionTaskDelegate>
@end
@implementation LTFilterRedirects
- (void)URLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil); // A redirect could hand the request to a host the build did not name.
}
@end

static LTFilterUpdater *sharedUpdater;
@implementation LTFilterUpdater {
    SecKeyRef _key;
    dispatch_queue_t _queue;
}
+ (LTFilterUpdater *)shared { return sharedUpdater; }
+ (void)setShared:(LTFilterUpdater *)updater { sharedUpdater = updater; }
- (instancetype)initWithFeed:(NSString *)feed publicKey:(NSString *)key directory:(NSString *)directory {
    NSURL *url = LTFilterFeedURL(feed);
    SecKeyRef publicKey = LTFilterPublicKeyCreate(key);
    if (!url || !publicKey || !(self = [super init])) {
        if (publicKey) CFRelease(publicKey);
        return nil;
    }
    _feed = url;
    _key = publicKey;
    _directory = [directory copy];
    _queue = dispatch_queue_create("Lite.FilterUpdates", DISPATCH_QUEUE_SERIAL);
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions : @0700} error:nil];
    NSData *state = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"state.json"]];
    NSDictionary *saved = state ? [NSJSONSerialization JSONObjectWithData:state options:0 error:nil] : nil;
    if ([saved isKindOfClass:NSDictionary.class]) {
        if (Integer(saved[@"lastCheck"], 0, INT64_MAX)) _lastCheck = [saved[@"lastCheck"] doubleValue];
        if ([saved[@"lastResult"] isKindOfClass:NSString.class]) _lastResult = [saved[@"lastResult"] copy];
    }
    if (!_lastResult) _lastResult = @"";
    return self;
}
- (void)dealloc {
    if (_key) CFRelease(_key);
}
- (void)updateFilters {
    if (_checking) return;
    [self checkNewerThan:[LTContentBlocker shared].serial completion:^(LTContentBlocker *blocker, NSError *error) {
        if (blocker) [LTContentBlocker install:blocker];
        [NSNotificationCenter.defaultCenter postNotificationName:LTFilterUpdatesChanged object:self];
    }];
}
- (BOOL)isDue:(double)now {
    return _lastCheck <= 0 || now - _lastCheck >= CheckInterval || now < _lastCheck;
}
- (NSString *)path:(NSString *)name {
    return [_directory stringByAppendingPathComponent:name];
}
- (void)removeSetsExcept:(NSString *)kept {
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:_directory error:nil])
        if (![name isEqual:kept] && ![name isEqual:@"state.json"] && ![name isEqual:@"current"])
            [NSFileManager.defaultManager removeItemAtPath:[self path:name] error:nil];
}
- (LTContentBlocker *)installedBlockerNewerThan:(int64_t)serial {
    NSString *current = [[NSString stringWithContentsOfFile:[self path:@"current"] encoding:NSUTF8StringEncoding error:nil]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *set = current.length && current.length <= 12 &&
                            [current rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound
                        ? [self path:current] : nil;
    LTContentBlocker *blocker = nil;
    if (set) {
        NSDictionary *m = LTVerifiedFilterManifest(
            [NSData dataWithContentsOfFile:[set stringByAppendingPathComponent:@"filters.json"]] ?: [NSData data],
            [NSData dataWithContentsOfFile:[set stringByAppendingPathComponent:@"filters.json.sig"]] ?: [NSData data], _key, nil);
        int64_t installed = [m[@"serial"] longLongValue];
        BOOL intact = m && installed == current.longLongValue && installed > serial;
        for (NSString *name in LTFilterFiles()) {
            if (!intact) break;
            NSData *data = [NSData dataWithContentsOfFile:[set stringByAppendingPathComponent:name]];
            intact = Matches(data, m[@"files"][name]) && (![name isEqual:@"provenance.json"] || ProvenanceMatches(data, installed));
        }
        if (intact) blocker = [[LTContentBlocker alloc] initWithDirectory:set];
    }
    if (!blocker) {
        [NSFileManager.defaultManager removeItemAtPath:[self path:@"current"] error:nil];
        [self removeSetsExcept:nil];
    }
    return blocker;
}
- (NSURLSession *)session {
    NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    c.HTTPCookieStorage = nil;
    c.HTTPShouldSetCookies = NO;
    c.URLCredentialStorage = nil;
    c.URLCache = nil;
    c.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    c.timeoutIntervalForRequest = 30;
    c.timeoutIntervalForResource = 300;
    c.HTTPAdditionalHeaders = @{@"User-Agent" : @"Lite-Browser"};
    if (_protocolClasses) c.protocolClasses = [_protocolClasses arrayByAddingObjectsFromArray:c.protocolClasses];
    return [NSURLSession sessionWithConfiguration:c delegate:[LTFilterRedirects new] delegateQueue:nil];
}
- (void)get:(NSString *)path
      session:(NSURLSession *)session
        limit:(int64_t)limit
   completion:(void (^)(NSData *data, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:path relativeToURL:_feed].absoluteURL;
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error || status != 200)
            completion(nil, LTError(error ? [@"The filter server could not be reached: " stringByAppendingString:error.localizedDescription]
                                          : [NSString stringWithFormat:@"The filter server answered %ld for %@.", (long)status, path]));
        else if ((int64_t)data.length > limit)
            completion(nil, LTError(@"The filter server sent more data than expected."));
        else
            completion(data, nil);
    }] resume];
}
- (void)finish:(LTContentBlocker *)blocker
         error:(NSError *)error
        result:(NSString *)result
    completion:(void (^)(LTContentBlocker *, NSError *))completion {
    double now = NSDate.date.timeIntervalSince1970;
    NSString *text = error ? [@"Failed: " stringByAppendingString:error.localizedDescription] : result ?: @"Failed";
    NSData *state = [NSJSONSerialization dataWithJSONObject:@{@"lastCheck" : @(floor(now)), @"lastResult" : text} options:0 error:nil];
    [state writeToFile:[self path:@"state.json"] options:NSDataWritingAtomic error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_lastCheck = floor(now);
        self->_lastResult = text;
        self->_checking = NO;
        completion(blocker, error);
    });
}
- (void)checkNewerThan:(int64_t)serial completion:(void (^)(LTContentBlocker *, NSError *))completion {
    if (_checking) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, LTError(@"A filter check is already running.")); });
        return;
    }
    _checking = YES;
    NSURLSession *session = [self session];
    void (^done)(LTContentBlocker *, NSError *, NSString *) = ^(LTContentBlocker *blocker, NSError *error, NSString *result) {
        [session finishTasksAndInvalidate];
        [self finish:blocker error:error result:result completion:completion];
    };
    [self get:@"filters.json" session:session limit:ManifestLimit completion:^(NSData *manifest, NSError *error) {
        if (!manifest) { done(nil, error, nil); return; }
        [self get:@"filters.json.sig" session:session limit:SignatureLimit completion:^(NSData *signature, NSError *error) {
            if (!signature) { done(nil, error, nil); return; }
            NSError *invalid = nil;
            NSDictionary *m = LTVerifiedFilterManifest(manifest, signature, self->_key, &invalid);
            if (!m) { done(nil, invalid, nil); return; }
            int64_t offered = [m[@"serial"] longLongValue];
            if (offered <= serial) { done(nil, nil, @"Up to date"); return; }
            NSMutableDictionary *contents = [NSMutableDictionary new];
            __block NSError *failure = nil;
            dispatch_group_t group = dispatch_group_create();
            for (NSString *name in LTFilterFiles()) {
                NSDictionary *file = m[@"files"][name];
                dispatch_group_enter(group);
                [self get:[NSString stringWithFormat:@"%lld/%@", offered, name] session:session
                    limit:[file[@"size"] longLongValue] completion:^(NSData *data, NSError *error) {
                    NSError *problem = error;
                    if (data && !Matches(data, file))
                        problem = LTError([name stringByAppendingString:@" does not match the signed filter manifest."]);
                    else if (data && [name isEqual:@"provenance.json"] && !ProvenanceMatches(data, offered))
                        problem = LTError(@"The filter provenance does not match the signed filter manifest.");
                    dispatch_async(self->_queue, ^{
                        if (problem && !failure) failure = problem;
                        if (!problem) contents[name] = data;
                        dispatch_group_leave(group);
                    });
                }];
            }
            dispatch_group_notify(group, self->_queue, ^{
                if (failure) { done(nil, failure, nil); return; }
                NSError *installError = nil;
                LTContentBlocker *blocker = [self install:contents manifest:manifest signature:signature
                                                   serial:offered error:&installError];
                done(blocker, installError, blocker ? [@"Installed filters published " stringByAppendingString:
                                                       LTFilterSerialDate(offered) ?: @(offered).stringValue] : nil);
            });
        }];
    }];
}
// Writes the set beside the installed one, compiles it, then makes it current. Runs on `_queue`.
- (LTContentBlocker *)install:(NSDictionary<NSString *, NSData *> *)contents
                     manifest:(NSData *)manifest
                    signature:(NSData *)signature
                       serial:(int64_t)serial
                        error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *staging = [self path:[@".staging-" stringByAppendingString:LTUUID()]];
    NSString *final = [self path:@(serial).stringValue];
    if (![fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions : @0700} error:error])
        return nil;
    NSMutableDictionary *all = [contents mutableCopy];
    all[@"filters.json"] = manifest;
    all[@"filters.json.sig"] = signature;
    for (NSString *name in all)
        if (![all[name] writeToFile:[staging stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:error]) {
            [fm removeItemAtPath:staging error:nil];
            return nil;
        }
    LTContentBlocker *blocker = [[LTContentBlocker alloc] initWithDirectory:staging];
    if (!blocker) {
        [fm removeItemAtPath:staging error:nil];
        Fail(error, @"The new filters could not be loaded, so the current ones were kept.");
        return nil;
    }
    [fm removeItemAtPath:final error:nil];
    if (![fm moveItemAtPath:staging toPath:final error:error] ||
        ![[@(serial).stringValue stringByAppendingString:@"\n"] writeToFile:[self path:@"current"] atomically:YES
                                                                  encoding:NSUTF8StringEncoding error:error]) {
        [fm removeItemAtPath:staging error:nil];
        return nil;
    }
    [self removeSetsExcept:@(serial).stringValue];
    // The blocker read its files from the staging path, which no longer exists; it holds them in memory.
    return blocker;
}
@end
