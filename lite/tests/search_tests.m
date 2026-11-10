// Search engines: the built-in list, the user's own, profile validation, and Command Bar
// suggestions. A stand-in for the network answers every request, so nothing leaves this Mac.
#import "../model/LTCommandIndex.h"
#import "../model/LTStore.h"
static int passed, failed;
#define CHECK(condition, name) do { if (condition) { passed++; printf("PASS %s\n", name); } else { failed++; fprintf(stderr, "FAIL %s (line %d)\n", name, __LINE__); } } while (0)

static NSMutableArray<NSURLRequest *> *requests;
static NSInteger responseStatus = 200;
static NSData *responseBody;
static NSString *responseType;
static NSURL *redirectTarget;
@interface LTFakeSuggestions : NSURLProtocol
@end
@implementation LTFakeSuggestions
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    [requests addObject:self.request];
    NSMutableDictionary *headers = [@{@"Content-Type": responseType, @"Set-Cookie": @"tracker=1; Path=/"} mutableCopy];
    if (redirectTarget) headers[@"Location"] = redirectTarget.absoluteString;
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:redirectTarget ? 302 : responseStatus
                                                             HTTPVersion:@"HTTP/1.1" headerFields:headers];
    if (redirectTarget)
        [self.client URLProtocol:self wasRedirectedToRequest:[NSURLRequest requestWithURL:redirectTarget] redirectResponse:response];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:responseBody];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

static NSData *JSON(id object) { return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil]; }
static void Answer(NSArray *suggestions) {
    responseStatus = 200;
    responseBody = JSON(@[@"ignored", suggestions]);
    responseType = @"application/x-suggestions+json; charset=utf-8";
    redirectTarget = nil;
}
static void Spin(NSTimeInterval seconds, BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!(done && done()) && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
}
static LTSearchSuggestions *Suggester(NSTimeInterval delay) {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[LTFakeSuggestions.class];
    return [[LTSearchSuggestions alloc] initWithConfiguration:configuration delay:delay];
}
// Asks and waits. Returns nil when nothing was asked or no answer came.
static NSArray *Ask(LTSearchSuggestions *suggester, NSString *query, NSDictionary *settings, BOOL *asked) {
    __block NSArray *answer = nil;
    BOOL sent = [suggester suggest:query settings:settings completion:^(NSArray<NSString *> *suggestions) { answer = suggestions; }];
    if (asked) *asked = sent;
    if (sent) Spin(5, ^BOOL { return answer != nil; });
    else Spin(.1, nil);
    return answer;
}
static NSDictionary *Engine(NSString *name, NSString *url, NSString *suggest, NSArray *existing, NSString **problem) {
    NSError *error = nil;
    NSDictionary *engine = LTCustomSearchEngine(name, url, suggest, existing, &error);
    if (problem) *problem = error.localizedDescription;
    return engine;
}
static LTProfile *Load(NSDictionary *settings) {
    NSMutableDictionary *json = [LTProfile.fresh.JSON mutableCopy];
    json[@"settings"] = settings;
    // Through JSON text, as a saved profile arrives.
    return [LTProfile fromJSON:[NSJSONSerialization JSONObjectWithData:JSON(json) options:0 error:nil] error:nil];
}

static void TestEngines(void) {
    NSArray<NSDictionary *> *builtIn = LTBuiltInSearchEngines();
    CHECK(([[builtIn valueForKey:@"name"] isEqual:@[@"DuckDuckGo", @"Google", @"Bing", @"Brave Search", @"Ecosia", @"Kagi", @"Startpage"]]),
          "seven built-in engines, DuckDuckGo first");
    BOOL sound = YES;
    for (NSDictionary *engine in builtIn) {
        // Every built-in address passes the rules a custom engine must pass.
        NSDictionary *same = Engine([engine[@"name"] stringByAppendingString:@" copy"], engine[@"url"], engine[@"suggest"], nil, NULL);
        sound = sound && same && [same[@"url"] isEqual:engine[@"url"]] && [same[@"suggest"] isEqual:engine[@"suggest"]] &&
                [engine[@"url"] hasPrefix:@"https://"] && [engine[@"suggest"] hasPrefix:@"https://"];
    }
    CHECK(sound, "built-in search and suggestion addresses are valid https addresses");
    CHECK([LTDefaultSearchEngine isEqual:@"DuckDuckGo"] && [LTProfile.fresh.settings[@"search"] isEqual:LTDefaultSearchEngine] &&
              !LTProfile.fresh.settings[@"searchSuggestions"],
          "a new profile searches with DuckDuckGo and has suggestions off");
    CHECK([LTSelectedSearchEngine(nil)[@"name"] isEqual:@"DuckDuckGo"] && [LTSelectedSearchEngine(@{@"search": @"Nowhere"})[@"name"] isEqual:@"DuckDuckGo"] &&
              [LTSelectedSearchEngine(@{@"search": @"Kagi"})[@"url"] isEqual:@"https://kagi.com/search?q=%s"],
          "the selected engine falls back to the default");

    CHECK([LTSearchURL(@"two words", nil) isEqual:@"https://duckduckgo.com/?q=two%20words"], "a search fills the engine's address");
    CHECK([LTSearchURL(@"c++ & c#?", @{@"search": @"Bing"}) isEqual:@"https://www.bing.com/search?q=c%2B%2B%20%26%20c%23%3F"],
          "plus, ampersand, hash and question mark reach the engine as typed");
    CHECK([LTSearchURL(@"100% café", @{@"search": @"Startpage"}) isEqual:@"https://www.startpage.com/sp/search?query=100%25%20caf%C3%A9"],
          "percent signs and accents are encoded");
    CHECK([LTURLFromInput(@"example.org", @{@"search": @"Google"}) isEqual:@"https://example.org"] &&
              [LTURLFromInput(@" swift docs ", @{@"search": @"Google"}) isEqual:@"https://www.google.com/search?q=swift%20docs"],
          "Command Bar text is an address or a search with the selected engine");

    NSString *problem = nil;
    NSDictionary *wiki = Engine(@"  Wikipedia ", @" https://en.wikipedia.org/wiki/Special:Search?search={searchTerms} ", @"", nil, &problem);
    CHECK(([wiki isEqual:@{@"name": @"Wikipedia", @"url": @"https://en.wikipedia.org/wiki/Special:Search?search=%s"}]) && !problem,
          "a custom engine is trimmed, and {searchTerms} becomes %s");
    NSDictionary *local = Engine(@"SearXNG", @"http://search.lan:8080/search?q=%s", @"http://localhost:8080/autocompleter?q=%s", @[wiki], &problem);
    CHECK(local && [local[@"suggest"] isEqual:@"http://localhost:8080/autocompleter?q=%s"], "a self-hosted engine may use http, with suggestions on this Mac");
    NSDictionary *path = Engine(@"Docs", @"https://docs.example/%s/index.html", nil, nil, NULL);
    NSDictionary *pathSettings = @{@"search": @"Docs", @"searchEngines": @[path ?: @{}]};
    CHECK(path && [LTSearchURL(@"a/b ../c", pathSettings) isEqual:@"https://docs.example/a%2Fb%20..%2Fc/index.html"],
          "a query used in a path stays one path segment");

    NSArray *existing = @[wiki];
    for (NSArray *bad in @[
             @[@"", @"https://x.example/?q=%s", @"", @"name"], @[@"Google", @"https://x.example/?q=%s", @"", @"already"],
             @[@"duckduckgo", @"https://x.example/?q=%s", @"", @"already"], @[@"WIKIPEDIA", @"https://x.example/?q=%s", @"", @"already"],
             @[@"Two\nLines", @"https://x.example/?q=%s", @"", @"name"],
             @[@"No Query", @"https://x.example/search", @"", @"%s"], @[@"FTP", @"ftp://x.example/?q=%s", @"", @"http"],
             @[@"Script", @"javascript:alert('%s')", @"", @"http"], @[@"File", @"file:///tmp/%s", @"", @"http"],
             @[@"Login", @"https://user:pw@x.example/?q=%s", @"", @"http"], @[@"Bare", @"x.example/?q=%s", @"", @"http"],
             @[@"Host", @"https://%s/", @"", @"site"], @[@"Subdomain", @"https://%s.x.example/search", @"", @"site"],
             @[@"Scheme", @"%s://x.example/", @"", @"http"], @[@"Port", @"https://x.example:%s/", @"", @"http"],
             @[@"Spaces", @"https://x.example/?q=%s&lang=en us", @"", @"spaces"],
             @[@"Plain", @"https://x.example/?q=%s", @"http://x.example/suggest?q=%s", @"https"],
             @[@"Fixed", @"https://x.example/?q=%s", @"https://x.example/suggest", @"%s"],
             @[@"Other Host", @"https://x.example/?q=%s", @"https://%s/suggest", @"site"]
         ]) {
        NSDictionary *engine = Engine(bad[0], bad[1], bad[2], existing, &problem);
        if (engine || ![problem.lowercaseString containsString:bad[3]]) {
            failed++;
            fprintf(stderr, "FAIL rejected engine %s: %s\n", [bad[0] UTF8String], problem.UTF8String ?: "accepted");
        } else passed++;
    }
    NSString *longName = [@"" stringByPaddingToLength:65 withString:@"n" startingAtIndex:0];
    NSString *longURL = [@"https://x.example/?q=%s&pad=" stringByPaddingToLength:2049 withString:@"p" startingAtIndex:0];
    CHECK(!Engine(longName, @"https://x.example/?q=%s", nil, nil, NULL) && !Engine(@"Long", longURL, nil, nil, NULL),
          "an overlong name or address is rejected");
    NSMutableArray *full = [NSMutableArray new];
    for (NSUInteger i = 0; i < LTCustomSearchEngineLimit; i++) {
        NSDictionary *engine = Engine([NSString stringWithFormat:@"Engine %lu", (unsigned long)i], @"https://x.example/?q=%s", nil, full, NULL);
        if (engine) [full addObject:engine];
    }
    CHECK(full.count == LTCustomSearchEngineLimit && !Engine(@"One More", @"https://x.example/?q=%s", nil, full, &problem) &&
              [problem containsString:@"Remove one"],
          "the list of custom engines is bounded");

    NSDictionary *settings = @{@"search": @"Wikipedia", @"searchEngines": @[wiki, local]};
    CHECK(([[LTSearchEngines(settings) valueForKey:@"name"] isEqual:[[builtIn valueForKey:@"name"] arrayByAddingObjectsFromArray:@[@"Wikipedia", @"SearXNG"]]]) &&
              [LTSearchURL(@"Ada Lovelace", settings) isEqual:@"https://en.wikipedia.org/wiki/Special:Search?search=Ada%20Lovelace"],
          "custom engines follow the built-in ones and can be selected");
}

static void TestProfile(NSString *root) {
    NSDictionary *wiki = Engine(@"Wikipedia", @"https://en.wikipedia.org/wiki/Special:Search?search=%s", nil, nil, NULL);
    NSDictionary *local = Engine(@"SearXNG", @"http://search.lan/search?q=%s", @"https://search.lan/autocompleter?q=%s", nil, NULL);
    NSDictionary *base = LTProfile.fresh.settings;
    NSMutableDictionary * (^with)(NSDictionary *) = ^(NSDictionary *changes) {
      NSMutableDictionary *settings = [base mutableCopy];
      [settings addEntriesFromDictionary:changes];
      return settings;
    };
    LTProfile *loaded = Load(with(@{@"search": @"SearXNG", @"searchEngines": @[wiki, local], @"searchSuggestions": @YES}));
    CHECK(loaded && [LTSelectedSearchEngine(loaded.settings) isEqual:local] && [loaded.settings[@"searchSuggestions"] isEqual:@YES],
          "a profile with custom engines and suggestions loads");
    NSMutableDictionary *legacy = [base mutableCopy];
    [legacy removeObjectForKey:@"search"];
    CHECK(Load(legacy) && Load(with(@{@"search": @"Google"})) && Load(with(@{@"search": @"Startpage"})) && Load(with(@{@"searchSuggestions": @NO})),
          "profiles from before custom engines, and every built-in choice, load");
    NSMutableDictionary *extra = [wiki mutableCopy], *spaced = [wiki mutableCopy], *emptySuggest = [wiki mutableCopy], *numbered = [wiki mutableCopy];
    extra[@"keyword"] = @"w";
    spaced[@"name"] = @" Wikipedia";
    emptySuggest[@"suggest"] = @"";
    numbered[@"url"] = @7;
    NSMutableArray *tooMany = [NSMutableArray new];
    for (NSUInteger i = 0; i <= LTCustomSearchEngineLimit; i++)
        [tooMany addObject:@{@"name": [NSString stringWithFormat:@"Engine %lu", (unsigned long)i], @"url": @"https://x.example/?q=%s"}];
    NSArray<NSDictionary *> *damaged = @[
        @{@"search": @"Nowhere"}, @{@"search": @"Wikipedia"}, @{@"search": @7}, @{@"search": @"google"},
        @{@"searchSuggestions": @"yes"}, @{@"searchSuggestions": @2},
        @{@"searchEngines": @{}}, @{@"searchEngines": @[@"Wikipedia"]}, @{@"searchEngines": @[wiki, wiki]},
        @{@"searchEngines": @[extra]}, @{@"searchEngines": @[spaced]}, @{@"searchEngines": @[emptySuggest]}, @{@"searchEngines": @[numbered]},
        @{@"searchEngines": @[@{@"name": @"Bing", @"url": @"https://x.example/?q=%s"}]},
        @{@"searchEngines": @[@{@"name": @"Script", @"url": @"javascript:alert('%s')"}]},
        @{@"searchEngines": @[@{@"name": @"Host", @"url": @"https://%s/"}]},
        @{@"searchEngines": @[@{@"name": @"Plain", @"url": @"https://x.example/?q=%s", @"suggest": @"http://x.example/?q=%s"}]},
        @{@"searchEngines": tooMany}
    ];
    NSUInteger rejected = 0;
    for (NSDictionary *changes in damaged) {
        if (!Load(with(changes))) rejected++;
        else fprintf(stderr, "accepted damaged search settings: %s\n", changes.description.UTF8String);
    }
    CHECK(rejected == damaged.count, "damaged search settings are rejected when a profile loads");

    NSString *path = [[root stringByAppendingPathComponent:LTUUID()] stringByAppendingPathComponent:@"Lite.sqlite"];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *error = nil;
    LTStore *store = [[LTStore alloc] initWithPath:path error:&error];
    BOOL saved = [store commit:^(LTProfile *p) {
        p.settings[@"searchEngines"] = @[wiki];
        p.settings[@"search"] = @"Wikipedia";
        p.settings[@"searchSuggestions"] = @YES;
    } error:&error];
    [store close];
    store = [[LTStore alloc] initWithPath:path error:&error];
    CHECK(saved && store && [LTSelectedSearchEngine(store.profile.settings) isEqual:wiki] && [store.profile.settings[@"searchSuggestions"] isEqual:@YES],
          "search settings survive saving and reopening the profile");
    BOOL refused = ![store commit:^(LTProfile *p) { p.settings[@"searchEngines"] = @[]; } error:&error];
    CHECK(refused && [LTSelectedSearchEngine(store.profile.settings) isEqual:wiki],
          "a save that would leave the selected engine missing is refused");
    [store close];
}

static void TestSuggestionRules(void) {
    NSDictionary *on = @{@"search": @"DuckDuckGo", @"searchSuggestions": @YES};
    CHECK(!LTSearchSuggestionURL(@"weather", nil) && !LTSearchSuggestionURL(@"weather", LTProfile.fresh.settings) &&
              !LTSearchSuggestionURL(@"weather", @{@"searchSuggestions": @NO}),
          "nothing is asked unless suggestions are turned on");
    CHECK([LTSearchSuggestionURL(@" weather in rome ", on).absoluteString isEqual:@"https://duckduckgo.com/ac/?q=weather%20in%20rome&type=list"],
          "typed text goes to the selected engine's suggestions address");
    BOOL each = YES;
    for (NSDictionary *engine in LTBuiltInSearchEngines()) {
        NSURL *url = LTSearchSuggestionURL(@"a&b", @{@"search": engine[@"name"], @"searchSuggestions": @YES});
        each = each && [url.scheme isEqual:@"https"] && [url.absoluteString containsString:@"a%26b"] &&
               [url.host isEqual:[NSURL URLWithString:[engine[@"suggest"] stringByReplacingOccurrencesOfString:@"%s" withString:@"x"]].host];
    }
    CHECK(each, "every built-in engine has an https suggestions address");
    BOOL none = YES;
    NSString *longText = [@"" stringByPaddingToLength:257 withString:@"long " startingAtIndex:0];
    for (NSString *text in @[@"", @"   ", @"example.org", @"example.org/private/path", @"https://example.org/?token=secret", @"localhost:3000/admin",
                             @"192.168.1.1", @"https:/", @"http://intranet", @"chrome://settings", @"about:blank", @"line one\nline two", longText])
        none = none && !LTSearchSuggestionURL(text, on);
    CHECK(none, "addresses, empty, multi-line and long text are never sent");
    NSDictionary *quiet = @{@"name": @"Quiet", @"url": @"https://quiet.example/?q=%s"};
    CHECK(!LTSearchSuggestionURL(@"weather", @{@"search": @"Quiet", @"searchEngines": @[quiet], @"searchSuggestions": @YES}),
          "an engine without a suggestions address is not asked");

    NSArray *parsed = LTParseSearchSuggestions(JSON(@[@"weath", @[@"weather", @"weather radar", @"Weather", @"weath", @" WEATH ", @7, @{}, @"", @"two\nlines",
                                                           [@"" stringByPaddingToLength:201 withString:@"x" startingAtIndex:0], @"  weather today  ", @"weather tomorrow", @"weather map"],
                                                       @[], @{@"google:suggestsubtypes": @[]}]), @"UTF-8", @"weath");
    CHECK(([parsed isEqual:@[@"weather", @"weather radar", @"weather today", @"weather tomorrow"]]) && parsed.count == LTSearchSuggestionLimit,
          "suggestions are trimmed, single-line, unrepeated, without the typed text, and limited");
    BOOL empty = YES;
    NSMutableData *huge = [JSON(@[@"q", @[@"suggestion"]]) mutableCopy];
    [huge increaseLengthBy:64 * 1024];
    for (NSData *data in @[[NSData new], [@"not json" dataUsingEncoding:NSUTF8StringEncoding], JSON(@{@"suggestions": @[@"a"]}), JSON(@[@"q"]),
                           JSON(@[@"q", @"text"]), JSON(@[@[@"a", @"b"]]), [@"<html>blocked</html>" dataUsingEncoding:NSUTF8StringEncoding], huge])
        empty = empty && LTParseSearchSuggestions(data, nil, @"q").count == 0;
    CHECK(empty, "anything but an OpenSearch suggestions answer gives no suggestions");
    NSData *latin = [@"[\"caf\",[\"café\",\"cafetière\"]]" dataUsingEncoding:NSISOLatin1StringEncoding];
    CHECK(([LTParseSearchSuggestions(latin, @"ISO-8859-1", @"caf") isEqual:@[@"café", @"cafetière"]]) &&
              ([LTParseSearchSuggestions(JSON(@[@"caf", @[@"café"]]), nil, @"caf") isEqual:@[@"café"]]),
          "an answer is read in the charset it declares");
}

static void TestFetching(void) {
    NSDictionary *on = @{@"search": @"Brave Search", @"searchSuggestions": @YES};
    LTSearchSuggestions *suggester = Suggester(0);
    BOOL asked = NO;
    Answer(@[@"weather", @"weather radar"]);
    NSArray *answer = Ask(suggester, @"weath", on, &asked);
    NSURLRequest *request = requests.firstObject;
    CHECK(asked && ([answer isEqual:@[@"weather", @"weather radar"]]) && requests.count == 1 &&
              [request.URL.absoluteString isEqual:@"https://search.brave.com/api/suggest?q=weath"] && [request.HTTPMethod isEqual:@"GET"],
          "one request brings the engine's suggestions");
    CHECK(![request valueForHTTPHeaderField:@"Cookie"] && !request.HTTPShouldHandleCookies && [[request valueForHTTPHeaderField:@"User-Agent"] isEqual:@"Lite-Browser"] &&
              !request.HTTPBody && !request.HTTPBodyStream,
          "the request carries no cookies and no body");
    answer = Ask(suggester, @"weath", on, &asked);
    CHECK(asked && ([answer isEqual:@[@"weather", @"weather radar"]]) && requests.count == 1, "a remembered answer is not asked for again");
    Answer(@[@"weather today"]);
    answer = Ask(suggester, @"weathe", on, &asked);
    request = requests.lastObject;
    CHECK(([answer isEqual:@[@"weather today"]]) && requests.count == 2 && ![request valueForHTTPHeaderField:@"Cookie"],
          "a cookie an engine tries to set is not sent back");

    [requests removeAllObjects];
    for (NSArray *unsent in @[@[@"weather", LTProfile.fresh.settings], @[@"example.org/path", on], @[@"", on]]) {
        answer = Ask(suggester, unsent[0], unsent[1], &asked);
        CHECK(!asked && !answer && requests.count == 0, "nothing is sent when suggestions are off or the text is an address");
    }

    Answer(@[@"first"]);
    suggester = Suggester(.05);
    __block NSMutableArray *answers = [NSMutableArray new];
    for (NSString *typed in @[@"s", @"sw", @"swi", @"swif"])
        [suggester suggest:typed settings:on completion:^(NSArray<NSString *> *suggestions) { [answers addObject:typed]; }];
    Spin(2, ^BOOL { return answers.count > 0; });
    Spin(.2, nil);
    CHECK(([answers isEqual:@[@"swif"]]) && requests.count == 1 && [requests.firstObject.URL.query isEqual:@"q=swif"],
          "fast typing sends one request, for the text as it ended");
    [requests removeAllObjects];
    [answers removeAllObjects];
    [suggester suggest:@"swift" settings:on completion:^(NSArray<NSString *> *suggestions) { [answers addObject:@"swift"]; }];
    [suggester forget];
    Spin(.3, nil);
    CHECK(answers.count == 0 && requests.count == 0, "closing the Command Bar cancels what was not yet sent");
    Answer(@[@"swift language"]);
    Ask(suggester, @"swift", on, &asked);
    Ask(suggester, @"swift", on, &asked);
    NSUInteger remembered = requests.count;
    [suggester forget];
    Ask(suggester, @"swift", on, &asked);
    CHECK(remembered == 1 && requests.count == 2, "closing the Command Bar forgets the answers it had");

    suggester = Suggester(0);
    responseStatus = 503;
    answer = Ask(suggester, @"down", on, &asked);
    Answer(@[@"download"]);
    NSArray *retry = Ask(suggester, @"down", on, &asked);
    CHECK(asked && answer && answer.count == 0 && ([retry isEqual:@[@"download"]]), "a failed request gives no suggestions and is not remembered");
    [requests removeAllObjects];
    redirectTarget = [NSURL URLWithString:@"https://elsewhere.example/suggest?q=moved"];
    answer = Ask(suggester, @"moved", on, &asked);
    BOOL followed = NO;
    for (NSURLRequest *sent in requests) followed = followed || [sent.URL.host isEqual:@"elsewhere.example"];
    CHECK(asked && answer && answer.count == 0 && !followed, "a redirect is not followed, so typed text reaches only the chosen engine");
    Answer(@[@"x"]);
    responseBody = [@"<html>rate limited</html>" dataUsingEncoding:NSUTF8StringEncoding];
    answer = Ask(suggester, @"html", on, &asked);
    CHECK(answer && answer.count == 0, "an answer that is not suggestions is ignored");
}

static void TestCommandBar(void) {
    LTProfile *profile = LTProfile.fresh;
    profile.settings[@"search"] = @"Ecosia";
    NSArray *history = @[@{@"url": @"https://weather.example/", @"title": @"Weather", @"match": LTHistoryMatchAddress},
                         @{@"url": @"https://news.example/weather", @"title": @"Weather news", @"match": LTHistoryMatchWord}];
    NSArray *suggestions = @[@"weather radar", @"weather today", @"weather tomorrow", @"weather map", @"weather alerts"];
    NSArray *plain = LTCommandResults(@"weath", profile, history, [NSSet new], nil);
    NSArray *suggested = LTCommandResults(@"weath", profile, history, [NSSet new], suggestions);
    NSArray *titles = [suggested valueForKey:@"title"];
    CHECK(([[titles subarrayWithRange:NSMakeRange(0, 7)] isEqual:@[@"Weather", @"Search for “weath”", @"weather radar", @"weather today", @"weather tomorrow", @"weather map", @"Weather news"]]),
          "suggestions follow the search row, ahead of other history, and stop at the limit");
    CHECK(suggested.count == plain.count + LTSearchSuggestionLimit && [suggested.firstObject isEqual:plain.firstObject] && [suggested[1] isEqual:plain[1]],
          "suggestions never change the first rows");
    NSDictionary *row = suggested[2];
    CHECK([row[@"type"] isEqual:@"url"] && [row[@"value"] isEqual:@"https://www.ecosia.org/search?q=weather%20radar"] &&
              [row[@"detail"] isEqual:@"Ecosia suggestion"] && [suggested[1][@"detail"] isEqual:@"Ecosia"],
          "a suggestion searches for itself with the selected engine");
    NSArray *address = LTCommandResults(@"example.org", profile, @[], [NSSet new], @[@"example organization"]);
    CHECK([address.firstObject[@"detail"] isEqual:@"Open address"], "a typed address still opens first");
    NSArray *idle = LTCommandResults(@"", profile, @[], [NSSet new], suggestions);
    CHECK(![[idle valueForKey:@"detail"] containsObject:@"Ecosia suggestion"], "an empty Command Bar lists no suggestions");
}

int main(void) {
    @autoreleasepool {
        requests = [NSMutableArray new];
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"lite-search-" stringByAppendingString:LTUUID()]];
        TestEngines();
        TestProfile(root);
        TestSuggestionRules();
        TestFetching();
        TestCommandBar();
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        printf("%d passed, %d failed\n", passed, failed);
        return failed ? 1 : 0;
    }
}
