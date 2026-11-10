// Custom network filters: bounded input, matching and precedence, policy replacement,
// and the real profile validation/persistence path. All fixtures stay on this Mac.
#import "../browser/LTContentBlocker.h"
#import "../model/LTStore.h"
#import <sqlite3.h>
static int passed, failed;
#define CHECK(condition, name) do { if (condition) { passed++; printf("PASS %s\n", name); } else { failed++; fprintf(stderr, "FAIL %s (line %d)\n", name, __LINE__); } } while (0)

static NSData *JSON(id object) { return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil]; }
static LTProfile *Profile(id text) {
    NSMutableDictionary *json = [LTProfile.fresh.JSON mutableCopy];
    json[@"settings"] = @{@"contentBlocking": @{@"customFilters": text}};
    return [LTProfile fromJSON:[NSJSONSerialization JSONObjectWithData:JSON(json) options:0 error:nil] error:nil];
}
static LTBlockingPolicy *Policy(NSString *text) {
    LTBlockingPolicy *policy = [LTBlockingPolicy new];
    [policy updatePreferences:@{@"customFilters": text}];
    return policy;
}
static BOOL Blocks(LTBlockingPolicy *policy, NSString *url) {
    return [policy blocksURL:url initiator:@"https://page.example/" type:@"script" method:@"GET" topURL:@"https://page.example/"];
}
static NSString *Repeated(NSString *text, NSUInteger count) {
    NSMutableString *result = [NSMutableString new];
    for (NSUInteger i = 0; i < count; ++i) [result appendString:text];
    return result;
}
static LTContentBlocker *Bundle(NSString *directory, BOOL replacement) {
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray *rules = replacement ? @[
        @{@"action": @{@"type": @"block"}, @"condition": @{@"urlFilter": @"||replacement.example^"}}
    ] : @[
        @{@"action": @{@"type": @"block"}, @"condition": @{@"urlFilter": @"||bundled.example^"}},
        @{@"action": @{@"type": @"allow"}, @"condition": @{@"urlFilter": @"||allowed.example^"}},
        @{@"action": @{@"type": @"block"}, @"condition": @{@"urlFilter": @"||navigation.example^", @"resourceTypes": @[@"main_frame"]}}
    ];
    NSDictionary *files = @{@"network.json": rules,
        @"cosmetic.json": @{@"generic": @[], @"specific": @{}, @"exceptions": @{}},
        @"provenance.json": @{@"networkRules": @(rules.count), @"serial": replacement ? @202611100002 : @202611100001}};
    for (NSString *name in files)
        [JSON(files[name]) writeToFile:[directory stringByAppendingPathComponent:name] atomically:YES];
    [@"com\nexample\n" writeToFile:[directory stringByAppendingPathComponent:@"suffixes.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return [[LTContentBlocker alloc] initWithDirectory:directory];
}

static void TestInput(void) {
    CHECK(LTValidateCustomFilters(@"", nil), "empty text removes custom rules");
    CHECK(LTValidateCustomFilters(@"! Local filters\r\n\r\n||ads.example^\r\n@@||ads.example/safe|\r\n", nil),
          "comments, blank lines, exceptions and CRLF are accepted");
    for (id value in @[@42, @[], @{}, NSNull.null]) {
        NSError *error = nil;
        CHECK(!LTValidateCustomFilters(value, &error) && error != nil && !Profile(value),
              "wrong types are refused by editor and profile validator");
    }
    CHECK(!LTValidateCustomFilters(nil, nil), "a non-string nil value is not custom filter text");
    for (NSArray *example in @[@[@"||ads.example^$third-party", @"option"],
                               @[@"page.example##.advert", @"cosmetic"], @[@"/ads[0-9]+/", @"regular expression"]]) {
        NSError *error = nil;
        CHECK(!LTValidateCustomFilters(example[0], &error) && [error.localizedDescription.lowercaseString containsString:example[1]],
              "unsupported filter errors name the kind of syntax that was refused");
    }
    NSArray *invalid = @[
        @"||ads.example^$third-party", @"||ads.example^$domain=page.example",
        @"page.example##.advert", @"page.example#@#.advert", @"page.example#?#div:has(.advert)",
        @"/ads[0-9]+/", @"@@/ads[0-9]+/", @"@@", @"|", @"||", @"|||ads.example^",
        @"ad|vert", @"||ads.example^||", @"space here", @"tab\there", @"café.example",
        @"control\x01here", @"newline\rhere"
    ];
    for (NSString *line in invalid) {
        NSError *error = nil;
        NSString *text = [@"||kept.example^\n" stringByAppendingString:line];
        CHECK(!LTValidateCustomFilters(text, &error) && [error.localizedDescription.lowercaseString containsString:@"line 2"] && !Profile(text),
              "unsupported or malformed line rejects the whole text and names its line");
    }
    NSString *line = Repeated(@"a", 2048);
    CHECK(LTValidateCustomFilters(line, nil) && Profile(line), "2048-character pattern is accepted");
    CHECK(!LTValidateCustomFilters([line stringByAppendingString:@"a"], nil) && !Profile([line stringByAppendingString:@"a"]),
          "2049-character pattern is refused in the editor and profile");
    CHECK(!LTValidateCustomFilters([@"!" stringByAppendingString:line], nil), "comments obey the same line-length limit");
    NSString *rules = Repeated(@"||bounded.example^\n", 1000);
    CHECK(LTValidateCustomFilters(rules, nil) && Profile(rules), "1000 active rules are accepted");
    NSString *tooMany = [rules stringByAppendingString:@"||one-more.example^"];
    CHECK(!LTValidateCustomFilters(tooMany, nil) && !Profile(tooMany), "1001 active rules are refused in the editor and profile");
    NSString *comment = [NSString stringWithFormat:@"!%@\n", Repeated(@"é", 1023)];
    NSString *limit = Repeated(comment, 128);
    CHECK([limit lengthOfBytesUsingEncoding:NSUTF8StringEncoding] == 256 * 1024 && LTValidateCustomFilters(limit, nil) && Profile(limit),
          "256 KiB UTF-8 total is accepted, including Unicode comments");
    NSString *oversized = [limit stringByAppendingString:@"!"];
    CHECK(!LTValidateCustomFilters(oversized, nil) && !Profile(oversized), "the UTF-8 byte limit is enforced even below the character limit");
}

static void TestMatching(LTContentBlocker *bundle, LTContentBlocker *replacement) {
    [LTContentBlocker install:bundle];
    CHECK([bundle decisionForURL:@"https://bundled.example/a" initiator:@"https://page.example" type:@"script" method:@"GET"] == LTNetworkBlock &&
          [bundle decisionForURL:@"https://allowed.example/a" initiator:@"https://page.example" type:@"script" method:@"GET"] == LTNetworkAllow &&
          [bundle decisionForURL:@"https://unmatched.example/a" initiator:@"https://page.example" type:@"script" method:@"GET"] == LTNetworkNoMatch,
          "bundled matcher distinguishes block, allow and no match");
    LTBlockingPolicy *policy = Policy(@"||ads.example^\n|https://exact.example/path|\n/track*pixel^\n/Case.js|");
    NSArray *vectors = @[
        @[@"https://ads.example/a", @YES], @[@"https://sub.ads.example/a", @YES],
        @[@"https://notads.example/a", @NO], @[@"https://ads.example.evil/a", @NO],
        @[@"https://good.example/path/ads.example/a", @NO], @[@"https://ADS.EXAMPLE/a", @YES],
        @[@"https://exact.example/path", @YES], @[@"http://exact.example/path", @NO],
        @[@"https://exact.example/path/more", @NO], @[@"https://cdn.example/track-long-pixel?x=1", @YES],
        @[@"https://cdn.example/track-long-pixelated", @NO], @[@"https://cdn.example/case.js", @YES],
        @[@"https://cdn.example/Case.js?query", @NO], @[@"file:///ads.example/a", @NO]
    ];
    for (NSArray *vector in vectors)
        CHECK(Blocks(policy, vector[0]) == [vector[1] boolValue], "URL globs preserve anchors, separators, case and hostname boundaries");
    CHECK(![policy blocksURL:@"https://ads.example/" initiator:@"https://page.example" type:@"main_frame" method:@"GET" topURL:@"https://ads.example/"],
          "custom domain blocks do not block top-level navigation");
    CHECK([policy blocksURL:@"https://navigation.example/" initiator:@"https://page.example" type:@"main_frame" method:@"GET" topURL:@"https://navigation.example/"],
          "bundled rules explicitly targeting main_frame keep their existing behavior");
    for (NSString *text in @[@"||ads.example^\n@@||ads.example/safe", @"@@||ads.example/safe\n||ads.example^"]) {
        policy = Policy(text);
        CHECK(Blocks(policy, @"https://ads.example/blocked") && !Blocks(policy, @"https://ads.example/safe"),
              "custom exception beats a custom block in either line order");
    }
    policy = Policy(@"@@||bundled.example^\n||allowed.example^\n||custom.example^");
    CHECK(!Blocks(policy, @"https://bundled.example/a"), "custom exception overrides a bundled block");
    CHECK(Blocks(policy, @"https://allowed.example/a"), "custom block overrides a bundled exception");
    CHECK(!Blocks(policy, @"https://unmatched.example/a"), "an unmatched URL remains allowed");
    NSString *text = @"||custom.example^";
    [policy updatePreferences:@{@"customFilters": text, @"disabledSites": @[@"page.example"]}];
    CHECK(!Blocks(policy, @"https://custom.example/a") && !Blocks(policy, @"https://bundled.example/a"),
          "site pause covers both custom and bundled rules");
    CHECK([policy blocksURL:@"https://custom.example/a" initiator:@"https://other.example" type:@"script" method:@"GET" topURL:@"https://other.example"],
          "site pause leaves another top-level hostname filtered");
    [policy updatePreferences:@{@"customFilters": text, @"disabled": @YES}];
    CHECK(!Blocks(policy, @"https://custom.example/a") && !Blocks(policy, @"https://bundled.example/a"),
          "global pause covers both custom and bundled rules");
    [policy updatePreferences:@{@"customFilters": text, @"cosmeticDisabled": @YES}];
    CHECK(Blocks(policy, @"https://custom.example/a") && ![policy cosmeticEnabledForURL:@"https://page.example"],
          "disabling cosmetic hiding keeps custom network blocks active");
    [policy updatePreferences:@{@"customFilters": @"||new.example^\nsite.example##.ad", @"disabled": @YES}];
    CHECK(Blocks(policy, @"https://custom.example/a") && !Blocks(policy, @"https://new.example/a") &&
          [policy enabledForURL:@"https://page.example"] && ![policy cosmeticEnabledForURL:@"https://page.example"],
          "invalid update preserves the previous whole policy and applies no partial rules");
    [policy updatePreferences:@{@"customFilters": @42, @"disabled": @YES}];
    CHECK(Blocks(policy, @"https://custom.example/a"), "wrong-type policy update preserves prior rules");
    LTBlockingPolicy *exception = Policy(@"@@||replacement.example^");
    [LTContentBlocker install:replacement];
    CHECK(Blocks(policy, @"https://custom.example/a") && Blocks(policy, @"https://replacement.example/a") && !Blocks(policy, @"https://bundled.example/a"),
          "installing a new bundled filter set preserves custom rules and changes bundled decisions");
    CHECK(!Blocks(exception, @"https://replacement.example/a"), "custom exceptions also survive replacement of the shared blocker");
    [policy updatePreferences:@{@"customFilters": @""}];
    CHECK(!Blocks(policy, @"https://custom.example/a") && Blocks(policy, @"https://replacement.example/a"),
          "saving empty text removes only custom rules");
    [LTContentBlocker install:bundle];
}

static void TestPersistence(NSString *directory) {
    NSString *path = [directory stringByAppendingPathComponent:@"profile.sqlite"];
    NSError *error = nil;
    LTStore *store = [[LTStore alloc] initWithPath:path error:&error];
    NSString *text = @"! Kept exactly\r\n||saved.example^\r\n@@||saved.example/safe\r\n";
    CHECK(store && [store commit:^(LTProfile *p) { p.settings[@"contentBlocking"] = @{@"customFilters": text}; } error:&error],
          "valid custom filter text commits through the real store");
    error = nil;
    CHECK(![store commit:^(LTProfile *p) { p.settings[@"contentBlocking"] = @{@"customFilters": @"||new.example^\n/ad[0-9]/"}; } error:&error] && error &&
          [store.profile.settings[@"contentBlocking"][@"customFilters"] isEqual:text],
          "a failed profile commit keeps the entire previous custom filter text");
    [store close];
    store = [[LTStore alloc] initWithPath:path error:&error];
    CHECK([store.profile.settings[@"contentBlocking"][@"customFilters"] isEqual:text], "custom filters persist exactly across reopening SQLite");
    LTBlockingPolicy *regular = [LTBlockingPolicy new];
    [regular updatePreferences:store.profile.settings[@"contentBlocking"]];
    CHECK(Blocks(regular, @"https://saved.example/a") && !Blocks(regular, @"https://saved.example/safe"),
          "reopened custom filters retain block and exception behavior");
    LTStore *privateStore = [[LTStore alloc] initWithPath:nil error:nil];
    CHECK([privateStore commit:^(LTProfile *p) { p.settings[@"contentBlocking"] = @{@"customFilters": text}; } error:nil],
          "a copied custom filter snapshot can be stored in a private profile");
    LTBlockingPolicy *privatePolicy = [LTBlockingPolicy new];
    [privatePolicy updatePreferences:privateStore.profile.settings[@"contentBlocking"]];
    CHECK(Blocks(privatePolicy, @"https://saved.example/a"), "copied private filters initially enforce the regular snapshot");
    [privateStore commit:^(LTProfile *p) { p.settings[@"contentBlocking"] = @{@"customFilters": @"||private.example^"}; } error:nil];
    [privatePolicy updatePreferences:privateStore.profile.settings[@"contentBlocking"]];
    CHECK(Blocks(privatePolicy, @"https://private.example/a") && !Blocks(privatePolicy, @"https://saved.example/a") &&
          Blocks(regular, @"https://saved.example/a") && !Blocks(regular, @"https://private.example/a"),
          "private edits change only their own matcher");
    [privateStore close];
    [store close];
    store = [[LTStore alloc] initWithPath:path error:nil];
    CHECK([store.profile.settings[@"contentBlocking"][@"customFilters"] isEqual:text], "private edits do not reach regular profile storage");
    [store close];
    // Bypass the store writer, as an outside editor can, then use the normal disk reader.
    NSMutableDictionary *malformed = [LTProfile.fresh.JSON mutableCopy];
    malformed[@"settings"] = @{@"contentBlocking": @{@"customFilters": @"||saved.example^\nsite.example##.ad"}};
    NSData *data = JSON(malformed);
    sqlite3 *db = NULL; sqlite3_stmt *statement = NULL;
    sqlite3_open(path.fileSystemRepresentation, &db);
    sqlite3_prepare_v2(db, "UPDATE profile SET json=? WHERE id=1", -1, &statement, NULL);
    sqlite3_bind_blob(statement, 1, data.bytes, (int)data.length, SQLITE_TRANSIENT);
    CHECK(sqlite3_step(statement) == SQLITE_DONE, "malformed filter fixture is written directly to SQLite");
    sqlite3_finalize(statement); sqlite3_close(db);
    error = nil;
    store = [[LTStore alloc] initWithPath:path error:&error];
    CHECK(!store && error, "the normal disk reader refuses a whole profile with unsupported custom filters");
}

static void TestConcurrentReplacement(void) {
    // Both complete sets enforce these same two decisions. Different sizes and
    // ordering expose a partially rebuilt set without depending on which set won.
    NSString *first = [Repeated(@"||other.example^\n", 128)
        stringByAppendingString:@"||always.example^\n@@||bundled.example^"];
    NSString *second = [@"@@||bundled.example^\n||always.example^\n"
        stringByAppendingString:Repeated(@"||another.example^\n", 64)];
    LTBlockingPolicy *policy = Policy(first);
    dispatch_group_t group = dispatch_group_create();
    dispatch_semaphore_t ready = dispatch_semaphore_create(0), start = dispatch_semaphore_create(0);
    NSObject *resultLock = [NSObject new];
    __block NSUInteger mismatches = 0;
    for (NSUInteger worker = 0; worker < 4; ++worker) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            dispatch_semaphore_signal(ready);
            dispatch_semaphore_wait(start, DISPATCH_TIME_FOREVER);
            NSUInteger localMismatches = 0;
            for (NSUInteger request = 0; request < 2000; ++request) {
                @autoreleasepool {
                    if (!Blocks(policy, @"https://always.example/a") || Blocks(policy, @"https://bundled.example/a"))
                        ++localMismatches;
                }
            }
            @synchronized (resultLock) { mismatches += localMismatches; }
        });
    }
    for (NSUInteger worker = 0; worker < 4; ++worker) dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
    for (NSUInteger worker = 0; worker < 4; ++worker) dispatch_semaphore_signal(start);
    for (NSUInteger update = 0; update < 400; ++update) {
        @autoreleasepool { [policy updatePreferences:@{@"customFilters": update % 2 ? first : second}]; }
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    CHECK(mismatches == 0, "concurrent requests see complete immutable custom rules while preferences change");
}

int main(void) {
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        LTContentBlocker *bundle = Bundle([directory stringByAppendingPathComponent:@"original"], NO);
        LTContentBlocker *replacement = Bundle([directory stringByAppendingPathComponent:@"replacement"], YES);
        CHECK(bundle && replacement, "local bundled filter fixtures load");
        TestInput();
        TestMatching(bundle, replacement);
        TestConcurrentReplacement();
        TestPersistence(directory);
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
        printf("%d custom filter checks passed, %d failed\n", passed, failed);
        return failed ? 1 : 0;
    }
}
