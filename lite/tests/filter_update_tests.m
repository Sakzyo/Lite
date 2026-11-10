// Signed filter updates: keys, feed addresses, manifest verification, downloading and installing a
// set, refusing bad ones, loading the installed set at launch, and swapping the filters in use. A
// stand-in for the network serves the feed, so nothing leaves this Mac.
#import "../model/LTFilterUpdates.h"
#import "../model/LTModel.h"
#import <CommonCrypto/CommonDigest.h>
static int passed, failed;
#define CHECK(condition, name) do { if (condition) { passed++; printf("PASS %s\n", name); } else { failed++; fprintf(stderr, "FAIL %s (line %d)\n", name, __LINE__); } } while (0)

static NSMutableDictionary<NSString *, id> *served; // path -> NSData, or @302 for a redirect
static NSMutableArray<NSURLRequest *> *requests;
@interface LTFakeFeed : NSURLProtocol
@end
@implementation LTFakeFeed
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    @synchronized(requests) { [requests addObject:self.request]; }
    id body;
    @synchronized(served) { body = served[self.request.URL.path]; }
    if ([body isEqual:@302]) {
        NSURL *target = [NSURL URLWithString:@"https://elsewhere.test/filters.json"];
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:302 HTTPVersion:@"HTTP/1.1"
                                                                headerFields:@{@"Location" : target.absoluteString}];
        [self.client URLProtocol:self wasRedirectedToRequest:[NSURLRequest requestWithURL:target] redirectResponse:response];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocolDidFinishLoading:self];
        return;
    }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:body ? 200 : 404
                                                             HTTPVersion:@"HTTP/1.1" headerFields:@{@"Set-Cookie" : @"tracker=1"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:body ?: [NSData data]];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

static NSData *JSON(id object) { return [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil]; }
static NSData *UTF8(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static NSString *SHA(NSData *data) {
    uint8_t d[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, d);
    NSMutableString *hex = [NSMutableString new];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", d[i]];
    return hex;
}
static SecKeyRef NewKey(void) {
    return SecKeyCreateRandomKey((__bridge CFDictionaryRef)@{(id)kSecAttrKeyType : (id)kSecAttrKeyTypeECSECPrimeRandom,
                                                             (id)kSecAttrKeySizeInBits : @256}, NULL);
}
static NSString *PublicBase64(SecKeyRef privateKey) {
    SecKeyRef publicKey = SecKeyCopyPublicKey(privateKey);
    NSData *raw = CFBridgingRelease(SecKeyCopyExternalRepresentation(publicKey, NULL));
    CFRelease(publicKey);
    return [raw base64EncodedStringWithOptions:0];
}
static NSData *Sign(SecKeyRef privateKey, NSData *data) {
    NSData *der = CFBridgingRelease(SecKeyCreateSignature(privateKey, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                                          (__bridge CFDataRef)data, NULL));
    return UTF8([der base64EncodedStringWithOptions:0]);
}
// A small filter set that LTContentBlocker compiles: one rule blocking `blocked`.
static NSMutableDictionary<NSString *, NSData *> *Set(int64_t serial, NSString *blocked) {
    return [@{
        @"network.json" : JSON(@[ @{@"condition" : @{@"urlFilter" : [NSString stringWithFormat:@"||%@^", blocked]},
                                    @"action" : @{@"type" : @"block"}, @"priority" : @1} ]),
        @"cosmetic.json" : JSON(@{@"generic" : @[ @".ad" ], @"specific" : @{}, @"exceptions" : @{}}),
        @"suffixes.txt" : UTF8(@"com\nexample\ntest\n"),
        @"youtube.js" : UTF8(@"// fallback\n"),
        @"provenance.json" : JSON(@{@"serial" : @(serial), @"version" : @"test", @"networkRules" : @1}),
        @"NOTICE.txt" : UTF8(@"notice\n"),
        @"COPYING-uBOL.txt" : UTF8(@"license\n")
    } mutableCopy];
}
static NSMutableDictionary *Manifest(int64_t serial, NSDictionary<NSString *, NSData *> *files) {
    NSMutableDictionary *described = [NSMutableDictionary new];
    for (NSString *name in files) described[name] = @{@"sha256" : SHA(files[name]), @"size" : @(files[name].length)};
    return [@{@"format" : @"lite-filters", @"version" : @1, @"serial" : @(serial), @"created" : @"2026-11-10T00:00:00Z",
              @"files" : described} mutableCopy];
}
// Serves a feed at https://filters.test/lite/. `files` may differ from what the manifest describes.
static void Serve(SecKeyRef key, NSDictionary *manifest, NSDictionary<NSString *, NSData *> *files, int64_t serial) {
    NSData *body = JSON(manifest);
    @synchronized(served) {
        [served removeAllObjects];
        served[@"/lite/filters.json"] = body;
        served[@"/lite/filters.json.sig"] = Sign(key, body);
        for (NSString *name in files) served[[NSString stringWithFormat:@"/lite/%lld/%@", serial, name]] = files[name];
    }
}
static void Publish(SecKeyRef key, int64_t serial, NSString *blocked) {
    NSDictionary *files = Set(serial, blocked);
    Serve(key, Manifest(serial, files), files, serial);
}
static NSError *lastError;
static LTContentBlocker *Check(LTFilterUpdater *updater, int64_t serial) {
    __block BOOL finished = NO;
    __block LTContentBlocker *result = nil;
    lastError = nil;
    [updater checkNewerThan:serial completion:^(LTContentBlocker *blocker, NSError *error) {
        result = blocker;
        lastError = error;
        finished = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    while (!finished && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return result;
}
static LTFilterUpdater *Updater(NSString *directory, NSString *key) {
    LTFilterUpdater *u = [[LTFilterUpdater alloc] initWithFeed:@"https://filters.test/lite" publicKey:key directory:directory];
    u.protocolClasses = @[ LTFakeFeed.class ];
    return u;
}
static NSArray *Entries(NSString *directory) {
    return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil] sortedArrayUsingSelector:@selector(compare:)];
}
static BOOL Blocks(LTContentBlocker *b, NSString *host) {
    return [b blocksURL:[NSString stringWithFormat:@"https://%@/x.js", host] initiator:@"https://site.example" type:@"script" method:@"GET"];
}

int main(void) {
    @autoreleasepool {
        served = [NSMutableDictionary new];
        requests = [NSMutableArray new];
        NSError *e = nil;
        SecKeyRef key = NewKey(), other = NewKey();
        NSString *publicKey = PublicBase64(key);

        // Keys.
        static const uint8_t spki[] = {0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                                       0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00};
        NSMutableData *wrapped = [NSMutableData dataWithBytes:spki length:sizeof(spki)];
        [wrapped appendData:[[NSData alloc] initWithBase64EncodedString:publicKey options:0]];
        SecKeyRef fromPoint = LTFilterPublicKeyCreate(publicKey), fromSPKI = LTFilterPublicKeyCreate([wrapped base64EncodedStringWithOptions:0]);
        CHECK(fromPoint && fromSPKI, "a P-256 key is read from its point or its SubjectPublicKeyInfo");
        if (fromPoint) CFRelease(fromPoint);
        if (fromSPKI) CFRelease(fromSPKI);
        NSMutableData *compressed = [[[NSData alloc] initWithBase64EncodedString:publicKey options:0] mutableCopy];
        ((uint8_t *)compressed.mutableBytes)[0] = 0x02;
        CHECK(!LTFilterPublicKeyCreate(nil) && !LTFilterPublicKeyCreate(@"not base64") &&
                  !LTFilterPublicKeyCreate([[NSData dataWithBytes:"\x04" length:1] base64EncodedStringWithOptions:0]) &&
                  !LTFilterPublicKeyCreate([compressed base64EncodedStringWithOptions:0]),
              "anything but an uncompressed P-256 key is refused");

        // Feed addresses.
        CHECK([LTFilterFeedURL(@"https://filters.test/lite").absoluteString isEqual:@"https://filters.test/lite/"] &&
                  LTFilterFeedURL(@"http://127.0.0.1:18743/filters/") && LTFilterFeedURL(@"http://localhost/f/"),
              "https feeds, and http on this Mac, are accepted");
        CHECK(!LTFilterFeedURL(@"http://filters.test/") && !LTFilterFeedURL(@"https://u:p@filters.test/") &&
                  !LTFilterFeedURL(@"https://filters.test/?x=1") && !LTFilterFeedURL(@"ftp://filters.test/") &&
                  !LTFilterFeedURL(@"https:///nohost") && !LTFilterFeedURL(nil),
              "other feed addresses are refused");
        CHECK([LTFilterSerialDate(202611101200) containsString:@"2026"] && !LTFilterSerialDate(202613011200) &&
                  !LTFilterSerialDate(202602301200) && !LTFilterSerialDate(1),
              "serials are read as publication dates");

        // Manifest verification.
        SecKeyRef verifier = LTFilterPublicKeyCreate(publicKey);
        NSDictionary *files = Set(202611101200, @"ads.test");
        NSData *body = JSON(Manifest(202611101200, files));
        CHECK(LTVerifiedFilterManifest(body, Sign(key, body), verifier, &e) != nil, "a manifest signed by the key verifies");
        e = nil;
        CHECK(!LTVerifiedFilterManifest(body, Sign(other, body), verifier, &e) && [e.localizedDescription containsString:@"signature"],
              "a manifest signed by another key is refused");
        NSMutableData *tampered = [body mutableCopy];
        ((uint8_t *)tampered.mutableBytes)[tampered.length - 2] ^= 1;
        CHECK(!LTVerifiedFilterManifest(tampered, Sign(key, body), verifier, nil), "a changed manifest no longer verifies");
        CHECK(!LTVerifiedFilterManifest(body, UTF8(@"!!"), verifier, nil) && !LTVerifiedFilterManifest(body, [NSData data], verifier, nil),
              "a signature that is not base64 is refused");
        NSData * (^signed_)(NSDictionary *) = ^NSData *(NSDictionary *m) { return JSON(m); };
        NSDictionary * (^variant)(void (^)(NSMutableDictionary *)) = ^NSDictionary *(void (^change)(NSMutableDictionary *)) {
            NSMutableDictionary *m = Manifest(202611101200, files);
            m[@"files"] = [m[@"files"] mutableCopy];
            change(m);
            return m;
        };
        NSDictionary *refusals = @{
            @"newer version" : variant(^(NSMutableDictionary *m) { m[@"version"] = @2; }),
            @"other format" : variant(^(NSMutableDictionary *m) { m[@"format"] = @"something"; }),
            @"boolean serial" : variant(^(NSMutableDictionary *m) { m[@"serial"] = @YES; }),
            @"fractional serial" : variant(^(NSMutableDictionary *m) { m[@"serial"] = @1.5; }),
            @"missing file" : variant(^(NSMutableDictionary *m) { [m[@"files"] removeObjectForKey:@"youtube.js"]; }),
            @"extra file" : variant(^(NSMutableDictionary *m) { m[@"files"][@"../escape.txt"] = m[@"files"][@"NOTICE.txt"]; }),
            @"uppercase digest" : variant(^(NSMutableDictionary *m) { m[@"files"][@"NOTICE.txt"] = @{@"sha256" : [SHA(files[@"NOTICE.txt"]) uppercaseString], @"size" : @7}; }),
            @"empty file" : variant(^(NSMutableDictionary *m) { m[@"files"][@"NOTICE.txt"] = @{@"sha256" : SHA(files[@"NOTICE.txt"]), @"size" : @0}; }),
            @"file over 32 MB" : variant(^(NSMutableDictionary *m) { m[@"files"][@"NOTICE.txt"] = @{@"sha256" : SHA(files[@"NOTICE.txt"]), @"size" : @(32 * 1024 * 1024 + 1)}; }),
            @"set over 64 MB" : variant(^(NSMutableDictionary *m) {
                for (NSString *name in @[ @"network.json", @"cosmetic.json", @"suffixes.txt" ])
                    m[@"files"][name] = @{@"sha256" : SHA(files[name]), @"size" : @(22 * 1024 * 1024)};
            }),
        };
        BOOL allRefused = YES;
        for (NSString *name in refusals) {
            NSData *m = signed_(refusals[name]);
            BOOL refused = !LTVerifiedFilterManifest(m, Sign(key, m), verifier, &e);
            if (!refused) fprintf(stderr, "  accepted: %s\n", name.UTF8String);
            allRefused &= refused;
        }
        CHECK(allRefused, "malformed signed manifests are refused");
        NSData *newer = signed_(refusals[@"newer version"]);
        e = nil;
        LTVerifiedFilterManifest(newer, Sign(key, newer), verifier, &e);
        CHECK([e.localizedDescription containsString:@"newer version of Lite"], "a newer manifest version asks for a newer Lite");
        NSMutableData *huge = [NSMutableData dataWithLength:64 * 1024 + 1];
        CHECK(!LTVerifiedFilterManifest(huge, Sign(key, huge), verifier, nil), "a manifest over 64 KB is refused");
        CFRelease(verifier);

        // Installing a set.
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:LTUUID()];
        NSString *directory = [root stringByAppendingPathComponent:@"Filters"];
        CHECK(!Updater(directory, @"bad key") && ![[LTFilterUpdater alloc] initWithFeed:@"http://filters.test/" publicKey:publicKey directory:directory],
              "an updater needs a valid key and feed");
        LTFilterUpdater *updater = Updater(directory, publicKey);
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:directory error:nil];
        CHECK([attributes[NSFilePosixPermissions] isEqual:@0700], "the filter directory is readable only by its owner");
        CHECK([updater isDue:NSDate.date.timeIntervalSince1970] && updater.lastCheck == 0, "a new updater is due a check");
        [NSHTTPCookieStorage.sharedHTTPCookieStorage setCookie:[NSHTTPCookie cookieWithProperties:@{
            NSHTTPCookieDomain : @"filters.test", NSHTTPCookiePath : @"/", NSHTTPCookieName : @"shared", NSHTTPCookieValue : @"1"}]];
        Publish(key, 202611101200, @"ads.test");
        [requests removeAllObjects];
        LTContentBlocker *installed = Check(updater, 202609221540);
        CHECK(installed && installed.serial == 202611101200 && Blocks(installed, @"ads.test") && !Blocks(installed, @"ok.test"),
              "a newer signed set is downloaded, compiled and returned");
        CHECK([Entries(directory) isEqual:(@[ @"202611101200", @"current", @"state.json" ])], "the set is saved as the current one");
        CHECK([[NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:@"current"] encoding:NSUTF8StringEncoding error:nil] isEqual:@"202611101200\n"],
              "current names the installed serial");
        BOOL clean = requests.count == 9;
        for (NSURLRequest *r in requests)
            clean &= !r.allHTTPHeaderFields[@"Cookie"] && [r.allHTTPHeaderFields[@"User-Agent"] isEqual:@"Lite-Browser"] && [r.URL.host isEqual:@"filters.test"];
        CHECK(clean, "the check sends nine requests to the feed host, without cookies");
        CHECK([updater.lastResult hasPrefix:@"Installed filters published"] && ![updater isDue:NSDate.date.timeIntervalSince1970] &&
                  [updater isDue:NSDate.date.timeIntervalSince1970 + 86400] && [updater isDue:updater.lastCheck - 10],
              "the result is recorded and the next check is due in a day");

        [requests removeAllObjects];
        CHECK(!Check(updater, installed.serial) && !lastError && [updater.lastResult isEqual:@"Up to date"] && requests.count == 2,
              "the same serial again downloads only the manifest and signature");
        Publish(key, 202610010000, @"old.test");
        CHECK(!Check(updater, installed.serial) && !lastError && [Entries(directory) containsObject:@"202611101200"],
              "an older set is never installed");

        // Refusals leave the installed set alone.
        NSArray *before = Entries(directory);
        NSMutableDictionary *bad = Set(202611111200, @"bad.test");
        NSDictionary *badManifest = Manifest(202611111200, bad);
        bad[@"network.json"] = JSON(@[]);
        Serve(key, badManifest, bad, 202611111200);
        CHECK(!Check(updater, installed.serial) && [lastError.localizedDescription containsString:@"network.json does not match"] &&
                  [Entries(directory) isEqual:before] && [updater.lastResult hasPrefix:@"Failed:"],
              "a file that differs from the manifest installs nothing");
        bad = Set(202611111200, @"bad.test");
        bad[@"provenance.json"] = JSON(@{@"serial" : @202611111300});
        Serve(key, Manifest(202611111200, bad), bad, 202611111200);
        CHECK(!Check(updater, installed.serial) && [lastError.localizedDescription containsString:@"provenance"] && [Entries(directory) isEqual:before],
              "provenance must carry the manifest's serial");
        bad = Set(202611111200, @"bad.test");
        bad[@"network.json"] = JSON(@{@"not" : @"a list"});
        Serve(key, Manifest(202611111200, bad), bad, 202611111200);
        CHECK(!Check(updater, installed.serial) && [lastError.localizedDescription containsString:@"could not be loaded"] && [Entries(directory) isEqual:before],
              "a set that does not compile installs nothing and leaves no staging folder");
        bad = Set(202611111200, @"bad.test");
        Serve(key, Manifest(202611111200, bad), bad, 202611111200);
        @synchronized(served) { [served removeObjectForKey:@"/lite/202611111200/youtube.js"]; }
        CHECK(!Check(updater, installed.serial) && [lastError.localizedDescription containsString:@"404"] &&
                  [lastError.localizedDescription containsString:@"youtube.js"] && [Entries(directory) isEqual:before],
              "a missing file installs nothing, and the error names it");
        double failedAt = updater.lastCheck;
        CHECK(![updater isDue:failedAt + 60] && [updater isDue:failedAt + 3600] && [Updater(directory, publicKey) isDue:failedAt + 3600],
              "a failed check is retried an hour later, also after relaunching");
        Serve(other, Manifest(202611111200, bad), bad, 202611111200);
        CHECK(!Check(updater, installed.serial) && [lastError.localizedDescription containsString:@"signature"], "a feed signed by another key is refused");
        @synchronized(served) { served[@"/lite/filters.json"] = @302; }
        [requests removeAllObjects];
        BOOL elsewhere = NO;
        CHECK(!Check(updater, installed.serial) && lastError, "a redirected manifest is refused");
        for (NSURLRequest *r in requests) elsewhere |= [r.URL.host isEqual:@"elsewhere.test"];
        CHECK(!elsewhere, "redirects are not followed");

        Publish(key, 202611121200, @"slow.test");
        __block int callbacks = 0;
        __block NSError *secondError = nil;
        [updater checkNewerThan:installed.serial completion:^(LTContentBlocker *b, NSError *error) { callbacks++; }];
        [updater checkNewerThan:installed.serial completion:^(LTContentBlocker *b, NSError *error) { callbacks++; secondError = error; }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
        while (callbacks < 2 && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        CHECK([secondError.localizedDescription containsString:@"already running"], "a second check while one runs is refused");
        CHECK([Entries(directory) isEqual:(@[ @"202611121200", @"current", @"state.json" ])], "a newer set replaces the older one on disk");

        // Launch.
        LTFilterUpdater *relaunched = Updater(directory, publicKey);
        CHECK([relaunched.lastResult hasPrefix:@"Installed filters published"] && relaunched.lastCheck > 0, "the last result survives relaunching");
        LTContentBlocker *loaded = [relaunched installedBlockerNewerThan:202609221540];
        CHECK(loaded.serial == 202611121200 && Blocks(loaded, @"slow.test"), "the installed set loads at launch when it is newer than the bundled one");
        CHECK(![Updater(directory, PublicBase64(other)) installedBlockerNewerThan:0] && ![Entries(directory) containsObject:@"current"],
              "a set that does not verify with the build's key is deleted at launch");
        Check(Updater(directory, publicKey), 0);
        CHECK(![relaunched installedBlockerNewerThan:202611121200] && [Entries(directory) isEqual:(@[ @"state.json" ])],
              "a set no newer than the bundled one is deleted");
        Check(updater, 0);
        NSString *network = [directory stringByAppendingPathComponent:@"202611121200/network.json"];
        NSMutableData *damaged = [[NSData dataWithContentsOfFile:network] mutableCopy];
        ((uint8_t *)damaged.mutableBytes)[2] ^= 1;
        [damaged writeToFile:network atomically:YES];
        CHECK(![relaunched installedBlockerNewerThan:0] && [Entries(directory) isEqual:(@[ @"state.json" ])],
              "a damaged installed set is deleted at launch");
        [@"../../etc\n" writeToFile:[directory stringByAppendingPathComponent:@"current"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        CHECK(![relaunched installedBlockerNewerThan:0], "current must name a serial");

        // The filters in use.
        LTContentBlocker *first = Check(updater, 0);
        [LTContentBlocker install:first];
        CHECK([LTContentBlocker shared] == first, "installing a set makes it the one in use");
        __block BOOL consistent = YES;
        dispatch_apply(2000, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
            if (i % 100 == 0) [LTContentBlocker install:i % 200 ? loaded : first];
            LTContentBlocker *b = [LTContentBlocker shared];
            if (b != first && b != loaded) consistent = NO;
        });
        CHECK(consistent, "readers on other threads always see a whole set while it is replaced");

        // Profile setting.
        LTProfile *p = LTProfile.fresh;
        p.settings[@"contentBlocking"] = @{@"updatesDisabled" : @YES};
        CHECK([p validate:nil], "turning automatic filter updates off is a valid setting");
        p.settings[@"contentBlocking"] = @{@"updatesDisabled" : @"no"};
        CHECK(![p validate:nil], "the setting must be a boolean");

        CFRelease(key);
        CFRelease(other);
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        printf("%d passed, %d failed\n", passed, failed);
        return failed ? 1 : 0;
    }
}
