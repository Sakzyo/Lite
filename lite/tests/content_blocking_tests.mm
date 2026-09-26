#import "../browser/LTContentBlocker.h"
#import "../model/LTStore.h"
#include "../browser/LTYouTubeFilter.h"

static NSUInteger checks, failures;
static void Check(BOOL result, NSString *name) {
    checks++;
    if (!result) { failures++; fprintf(stderr, "FAIL: %s\n", name.UTF8String); }
}
static NSDictionary *Rule(NSString *pattern, NSDictionary *conditions, NSString *action, int priority) {
    NSMutableDictionary *c = [conditions mutableCopy];
    if (pattern) c[@"urlFilter"] = pattern;
    return @{@"condition": c, @"action": @{@"type": action}, @"priority": @(priority)};
}
static std::string FilterYouTube(const std::string &input, size_t chunk, size_t capacity) {
    CefRefPtr<LTYouTubeFilter> filter = new LTYouTubeFilter;
    filter->InitFilter();
    std::string result;
    char output[256];
    for (size_t offset = 0; offset < input.size();) {
        size_t end = std::min(offset + chunk, input.size());
        while (offset < end) {
            size_t read = 0, written = 0;
            filter->Filter(const_cast<char *>(input.data() + offset), end - offset, read,
                           output, capacity, written);
            result.append(output, written);
            offset += read;
        }
    }
    while (true) {
        size_t read = 0, written = 0;
        auto status = filter->Filter(nullptr, 0, read, output, capacity, written);
        result.append(output, written);
        if (status == RESPONSE_FILTER_DONE) break;
    }
    return result;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        for (NSString *host in @[@"www.youtube.com", @"m.youtube.com", @"youtube.com",
                                @"www.youtube-nocookie.com", @"www.youtubekids.com"])
            Check(LTFilterYouTubeResponse([NSString stringWithFormat:@"https://%@/watch?v=test", host],
                                         @"main_frame", @"text/html"), @"YouTube document scope");
        Check(LTFilterYouTubeResponse(@"https://WWW.YOUTUBE.COM./youtubei/v1/player?key=x", @"xmlhttprequest", @"application/json; charset=utf-8"), @"player API and canonical host");
        for (NSString *url in @[@"https://notyoutube.com/watch", @"https://youtube.com.evil.test/watch",
                                @"https://example.com/youtube.com/watch", @"file:///youtube.com/watch"])
            Check(!LTFilterYouTubeResponse(url, @"main_frame", @"text/html"), @"unrelated host unchanged");
        Check(!LTFilterYouTubeResponse(@"https://www.youtube.com/youtubei/v1/account", @"xmlhttprequest", @"application/json"), @"other YouTube APIs unchanged");
        Check(!LTFilterYouTubeResponse(@"https://www.youtube.com/s/player.js", @"script", @"application/javascript"), @"player code unchanged");
        Check(!LTFilterYouTubeResponse(@"https://rr1.googlevideo.com/videoplayback", @"media", @"video/mp4"), @"video media unchanged");
        const std::string before = R"(<script>var ytInitialPlayerResponse={"adPlacements":[],"adSlots" : [1],"playerAds"\n:[],"videoDetails":{"videoId":"content"},"streamingData":{"url":"https://video.test/a"},"label":"adSlots","text":"\"adPlacements\":keep"};</script>)";
        std::string input = before;
        input.replace(input.find("\\n:"), 3, "\n:");
        std::string expected = input;
        for (const char *key : {"adPlacements", "adSlots", "playerAds"}) expected[expected.find(key)] = '_';
        BOOL boundaries = YES;
        for (size_t chunk = 1; chunk < input.size(); ++chunk)
            for (size_t capacity : {size_t(1), size_t(7), size_t(256)})
                boundaries &= FilterYouTube(input, chunk, capacity) == expected;
        Check(boundaries, @"YouTube keys filtered across every input boundary and small output buffers");
        const std::string encoded = R"({"playerResponse":"{\"adPlacements\":[],\"adSlots\" : [1],\"playerAds\":{},\"videoDetails\":{\"videoId\":\"main\"}}","text":"\"adSlots\":[1]"})";
        std::string encodedExpected = encoded;
        for (const char *key : {"adPlacements", "adSlots", "playerAds"})
            encodedExpected[encodedExpected.find(key)] = '_';
        BOOL encodedBoundaries = YES;
        for (size_t chunk = 1; chunk < encoded.size(); ++chunk)
            for (size_t capacity : {size_t(1), size_t(7), size_t(256)})
                encodedBoundaries &= FilterYouTube(encoded, chunk, capacity) == encodedExpected;
        Check(encodedBoundaries, @"serialized player responses filtered without changing ordinary escaped text");
        Check(FilterYouTube(R"({\"adSlots\":keep})", 1, 1) == R"({\"adSlots\":keep})",
              @"escaped prose without a structured ad value preserved");
        Check(FilterYouTube("ends in \"adPlacements", 1, 1) == "ends in \"adPlacements", @"incomplete final token preserved");
        std::string spaced = "{\"playerAds\"" + std::string(200, ' ') + ":[1]}";
        Check(FilterYouTube(spaced, 3, 7) == spaced, @"unusual whitespace passes through with bounded buffering");
        NSString *resources = [NSString stringWithUTF8String:argv[1]];
        double start = NSDate.timeIntervalSinceReferenceDate;
        LTContentBlocker *real = [[LTContentBlocker alloc] initWithDirectory:resources];
        Check(real != nil, @"bundled filters load");
        Check([real youtubeScriptForURL:@"https://www.youtube.com/watch"].length > 0,
              @"YouTube player fallback bundled");
        Check([real youtubeScriptForURL:@"https://youtube.com.evil.test/watch"].length == 0,
              @"YouTube player fallback excludes unrelated sites");
        Check([real.provenance[@"networkRules"] unsignedIntegerValue] == 17665, @"pinned rule coverage");
        Check([real blocksURL:@"https://googleads.g.doubleclick.net/pagead/ads" initiator:@"https://example.com" type:@"script" method:@"GET"], @"real advertising host");
        Check([real blocksURL:@"https://www.google-analytics.com/analytics.js" initiator:@"https://example.com" type:@"script" method:@"GET"], @"real analytics host");
        Check(![real blocksURL:@"https://example.com/articles/advertising" initiator:@"https://example.com" type:@"main_frame" method:@"GET"], @"ordinary top-level navigation");
        Check([real blocksURL:@"http://127.0.0.1:18743/webtracking.min.js" initiator:@"http://127.0.0.1:18743" type:@"xmlhttprequest" method:@"GET"], @"loopback integration uses real upstream filter");
        for (NSArray *pair in @[@[@"a.b.example.co.uk", @"example.co.uk"], @[@"a.github.io", @"a.github.io"],
                                @[@"b.a.github.io", @"a.github.io"], @[@"www.city.kobe.jp", @"city.kobe.jp"],
                                @[@"a.b.ck", @"a.b.ck"], @[@"www.ck", @"www.ck"],
                                @[@"127.0.0.1", @"127.0.0.1"], @[@"localhost", @"localhost"]])
            Check([[real siteForHost:pair[0]] isEqual:pair[1]], [@"PSL " stringByAppendingString:pair[0]]);

        NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:temporary withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *name in @[@"suffixes.txt", @"provenance.json"])
            [NSFileManager.defaultManager copyItemAtPath:[resources stringByAppendingPathComponent:name]
                                                toPath:[temporary stringByAppendingPathComponent:name] error:nil];
        NSArray *rules = @[
            Rule(@"||ads.example^", @{}, @"block", 10),
            Rule(@"||ads.example/safe", @{}, @"allow", 10),
            Rule(@"||ads.example/safe/important", @{}, @"block", 40),
            Rule(@"|https://exact.example/path|", @{}, @"block", 10),
            Rule(@"/CaseSensitive.js|", @{@"isUrlFilterCaseSensitive": @YES, @"resourceTypes": @[@"script"]}, @"block", 10),
            Rule(@"/track*pixel^", @{@"domainType": @"thirdParty", @"requestMethods": @[@"post"]}, @"block", 10),
            Rule(nil, @{@"requestDomains": @[@"bad.example"], @"excludedRequestDomains": @[@"ok.bad.example"],
                         @"initiatorDomains": @[@"site.example"], @"excludedInitiatorDomains": @[@"safe.site.example"]}, @"block", 10),
            Rule(@"tiny", @{@"resourceTypes": @[@"image"], @"excludedResourceTypes": @[@"script"]}, @"block", 10),
            Rule(@"/first-party", @{@"domainType": @"firstParty"}, @"block", 10),
            Rule(@"/main-only", @{@"resourceTypes": @[@"main_frame"]}, @"block", 10)
        ];
        NSDictionary *cosmetic = @{@"generic": @[@"#ad", @".banner"],
            @"specific": @{@"site.example": @[@".local"], @"site.*": @[@".entity"]},
            @"exceptions": @{@"site.example": @[@"#ad"], @"safe.site.example": @[@".local"]}};
        for (NSString *name in @[@"network.json", @"cosmetic.json"])
            [[NSJSONSerialization dataWithJSONObject:[name isEqual:@"network.json"] ? rules : cosmetic options:0 error:nil]
                writeToFile:[temporary stringByAppendingPathComponent:name] atomically:YES];
        LTContentBlocker *b = [[LTContentBlocker alloc] initWithDirectory:temporary];
        // Public DNR syntax and precedence examples, including negative boundary cases.
        NSArray *vectors = @[
            @[@"https://ads.example/a", @YES], @[@"https://sub.ads.example/a", @YES],
            @[@"https://notads.example/a", @NO], @[@"https://ads.example.evil/a", @NO],
            @[@"https://good.example/path/ads.example/a", @NO],
            @[@"https://ads.example/safe", @NO], @[@"https://ads.example/safe/important", @YES],
            @[@"https://exact.example/path", @YES], @[@"http://exact.example/path", @NO],
            @[@"https://exact.example/path/more", @NO],
            @[@"https://cdn.example/CaseSensitive.js", @YES], @[@"https://cdn.example/casesensitive.js", @NO]
        ];
        for (NSArray *v in vectors)
            Check([b blocksURL:v[0] initiator:@"https://site.example" type:@"script" method:@"GET"] == [v[1] boolValue], v[0]);
        Check(![b blocksURL:@"https://ads.example/a" initiator:@"" type:@"main_frame" method:@"GET"], @"implicit types exclude main_frame");
        Check([b blocksURL:@"https://good.example/main-only" initiator:@"" type:@"main_frame" method:@"GET"], @"explicit main_frame");
        Check([b blocksURL:@"https://bad.example/a" initiator:@"https://sub.site.example" type:@"image" method:@"GET"], @"domain-only index");
        Check(![b blocksURL:@"https://ok.bad.example/a" initiator:@"https://site.example" type:@"image" method:@"GET"], @"excluded request domain");
        Check(![b blocksURL:@"https://bad.example/a" initiator:@"https://safe.site.example" type:@"image" method:@"GET"], @"excluded initiator domain");
        Check(![b blocksURL:@"https://bad.example/a" initiator:@"null" type:@"image" method:@"GET"], @"opaque initiator cannot match domain include");
        Check([b blocksURL:@"https://cdn.example/tiny.png" initiator:@"https://site.example" type:@"image" method:@"GET"], @"short unindexed rule");
        Check(![b blocksURL:@"https://cdn.example/tiny.js" initiator:@"https://site.example" type:@"script" method:@"GET"], @"resource type restriction");
        Check([b blocksURL:@"https://cdn.example/track-long-pixel?x" initiator:@"https://site.example" type:@"xmlhttprequest" method:@"POST"], @"wildcard separator method and third party");
        Check(![b blocksURL:@"https://cdn.example/track-long-pixelXX" initiator:@"https://site.example" type:@"xmlhttprequest" method:@"POST"], @"separator excludes letters");
        Check(![b blocksURL:@"https://cdn.example/track-long-pixel?x" initiator:@"https://site.example" type:@"xmlhttprequest" method:@"GET"], @"method restriction");
        Check(![b blocksURL:@"https://cdn.example.co.uk/track-pixel" initiator:@"https://www.example.co.uk" type:@"xmlhttprequest" method:@"POST"], @"same registrable site");
        Check([b blocksURL:@"https://a.github.io/track-pixel" initiator:@"https://b.github.io" type:@"xmlhttprequest" method:@"POST"], @"private PSL boundary");
        Check([b blocksURL:@"https://cdn.example.co.uk/first-party" initiator:@"https://www.example.co.uk" type:@"image" method:@"GET"], @"first-party rule");
        NSString *css = [b cosmeticScriptForURL:@"https://safe.site.example/"];
        Check(![css containsString:@"#ad"] && ![css containsString:@".local"] && [css containsString:@".banner"], @"cosmetic exceptions across host ancestors");
        Check([[b cosmeticScriptForURL:@"https://site.co.uk/"] containsString:@".entity"], @"entity cosmetic rule with PSL");
        Check(![b cosmeticScriptForURL:@"file:///tmp/a.html"].length, @"internal and file pages unchanged");
        LTBlockingPolicy *policy = [LTBlockingPolicy new];
        Check([policy enabledForURL:@"https://site.example"], @"enabled by default");
        [policy updatePreferences:@{@"disabledSites": @[@"site.example"], @"cosmeticDisabled": @YES}];
        Check(![policy enabledForURL:@"https://SITE.example./a"], @"canonical site exception");
        Check([policy enabledForURL:@"https://othersite.example"] && ![policy cosmeticEnabledForURL:@"https://othersite.example"], @"cosmetic independent toggle");
        [policy updatePreferences:@{@"disabled": @YES}];
        Check(![policy enabledForURL:@"https://any.example"], @"global pause");
        [policy updatePreferences:nil];
        Check([policy cosmeticEnabledForURL:@"https://site.example"], @"re-enable filters");
        // Exercise the same SQLite profile persistence used by the native sheet.
        NSString *db = [temporary stringByAppendingPathComponent:@"profile.sqlite"];
        LTStore *store = [[LTStore alloc] initWithPath:db error:nil];
        [store commit:^(LTProfile *p) { p.settings[@"contentBlocking"] = @{@"disabledSites": @[@"site.example"]}; } error:nil];
        LTStore *reopened = [[LTStore alloc] initWithPath:db error:nil];
        Check([reopened.profile.settings[@"contentBlocking"][@"disabledSites"] containsObject:@"site.example"], @"site exceptions persist");
        LTStore *privateStore = [[LTStore alloc] initWithPath:nil error:nil];
        Check(privateStore.profile.settings[@"contentBlocking"] == nil, @"private preferences isolated");
        double matchStart = NSDate.timeIntervalSinceReferenceDate;
        for (NSUInteger i = 0; i < 10000; i++)
            [real blocksURL:@"https://static.example.com/assets/application-123.js" initiator:@"https://example.com" type:@"script" method:@"GET"];
        printf("%lu content-blocking checks, %lu failures; 10,000 requests %.3fs; total %.3fs\n",
               checks, failures, NSDate.timeIntervalSinceReferenceDate - matchStart, NSDate.timeIntervalSinceReferenceDate - start);
        [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
        return failures ? 1 : 0;
    }
}
