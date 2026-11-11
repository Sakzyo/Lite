// Custom network and cosmetic filters: bounded input, precedence, policy replacement,
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
// Decode the actual JavaScript payload so quotes and commas in attribute values
// are checked as CSS data, without accidentally matching the surrounding code.
static NSSet<NSString *> *Hidden(LTBlockingPolicy *policy, NSString *url, NSString *top) {
    NSString *script = [policy cosmeticScriptForURL:url topURL:top];
    NSRange begin = [script rangeOfString:@"s.replaceSync("];
    if (!script.length || begin.location == NSNotFound) return nil;
    NSString *tail = [script substringFromIndex:NSMaxRange(begin)];
    NSRange end = [tail rangeOfString:@"[0]);"];
    if (end.location == NSNotFound) return nil;
    NSArray *json = [NSJSONSerialization JSONObjectWithData:[[tail substringToIndex:end.location] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![json isKindOfClass:NSArray.class] || json.count != 1 || ![json[0] isKindOfClass:NSString.class]) return nil;
    NSString *css = json[0], *prefix = @":is(", *suffix = @"){display:none!important;}";
    if (![css hasPrefix:prefix] || ![css hasSuffix:suffix]) return nil;
    NSString *selectors = [css substringWithRange:NSMakeRange(prefix.length, css.length - prefix.length - suffix.length)];
    return selectors.length ? [NSSet setWithArray:[selectors componentsSeparatedByString:@",\n"]] : [NSSet set];
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
    NSDictionary *cosmetic = replacement ? @{@"generic": @[@".replacement"], @"specific": @{}, @"exceptions": @{}} :
        @{@"generic": @[@".bundled", @".upstream-excepted"],
          @"specific": @{@"page.example": @[@".bundled-specific"],
                         @"groups.example": @[@"#bio_ep, #bio_ep_bg",
                            @".outer:is(.left,.right), [data-ad=\"x,y\"]",
                            @".escaped\\,comma, .commented/* a,b */", @"#gone_one, #gone_two"]},
          @"exceptions": @{@"page.example": @[@".upstream-excepted"],
                           @"groups.example": @[@"#gone_one, #gone_two"]}};
    NSDictionary *files = @{@"network.json": rules, @"cosmetic.json": cosmetic,
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
    for (NSString *header in @[@"[Adblock]", @"[Adblock Plus 2.0]"]) {
        NSString *text = [NSString stringWithFormat:@" \t\r\n\t%@ \r\n  ! Pasted filters\n\t||ads.example^  \n  @@||ads.example/safe\t", header];
        CHECK(LTValidateCustomFilters(text, nil) && [Profile(text).settings[@"contentBlocking"][@"customFilters"] isEqual:text],
              "a first nonempty supported header and surrounding spaces or tabs are accepted without changing stored text");
        LTBlockingPolicy *policy = Policy(text);
        CHECK(Blocks(policy, @"https://ads.example/a") && !Blocks(policy, @"https://ads.example/safe"),
              "trimmed pasted patterns retain block and exception behavior");
    }
    for (NSString *text in @[@"\n! Comment\n[Adblock]\n||ads.example^", @"[Adblock]\n\n[Adblock Plus 2.0]"]) {
        NSError *error = nil;
        CHECK(!LTValidateCustomFilters(text, &error) && [error.localizedDescription.lowercaseString containsString:@"line 3"] &&
              [error.localizedDescription.lowercaseString containsString:@"remove"] && !Profile(text),
              "a misplaced list header is refused with its original line number and removal guidance");
    }
    for (NSString *header in @[@"[AdBlock]", @"[Adblock Plus]", @"[Adblock Plus 3.0]", @"[Unsupported List]"]) {
        NSError *error = nil;
        CHECK(!LTValidateCustomFilters(header, &error) && [error.localizedDescription.lowercaseString containsString:@"header"] && !Profile(header),
              "unknown list headers are refused rather than compiled as URL patterns");
    }
    for (id value in @[@42, @[], @{}, NSNull.null]) {
        NSError *error = nil;
        CHECK(!LTValidateCustomFilters(value, &error) && error != nil && !Profile(value),
              "wrong types are refused by editor and profile validator");
    }
    CHECK(!LTValidateCustomFilters(nil, nil), "a non-string nil value is not custom filter text");
    for (NSArray *example in @[@[@"||ads.example^$third-party", @"option"],
                               @[@"page.example#?#.advert", @"cosmetic"], @[@"/(?=ads)/", @"regular expression"]]) {
        NSError *error = nil;
        CHECK(!LTValidateCustomFilters(example[0], &error) && [error.localizedDescription.lowercaseString containsString:example[1]],
              "unsupported filter errors name the kind of syntax that was refused");
    }
    NSArray *invalid = @[
        @"||ads.example^$third-party", @"||ads.example^$domain=page.example",
        @"page.example##.advert:hover", @"page.example#@#.advert::before", @"page.example#?#div:has(.advert)",
        @"/(?=ads)/", @"@@/(?=ads)/", @"//", @"@@//", @"@@", @"|", @"||", @"|||ads.example^",
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
    NSString *padded = [Repeated(@" ", 2047) stringByAppendingString:@"/"];
    CHECK(LTValidateCustomFilters(padded, nil) && !LTValidateCustomFilters([padded stringByAppendingString:@"\t"], nil) &&
          !Profile([padded stringByAppendingString:@"\t"]), "the original line length is limited before surrounding whitespace is trimmed");
    NSString *rules = Repeated(@"||bounded.example^\n", 1000);
    CHECK(LTValidateCustomFilters(rules, nil) && Profile(rules), "1000 active rules are accepted");
    CHECK(LTValidateCustomFilters([@"[Adblock Plus 2.0]\n \t\n ! Comment\n" stringByAppendingString:rules], nil),
          "the accepted header, blank lines and comments do not count as active rules");
    NSString *tooMany = [rules stringByAppendingString:@"||one-more.example^"];
    CHECK(!LTValidateCustomFilters(tooMany, nil) && !Profile(tooMany), "1001 active rules are refused in the editor and profile");
    NSString *comment = [NSString stringWithFormat:@"!%@\n", Repeated(@"é", 1023)];
    NSString *limit = Repeated(comment, 128);
    CHECK([limit lengthOfBytesUsingEncoding:NSUTF8StringEncoding] == 256 * 1024 && LTValidateCustomFilters(limit, nil) && Profile(limit),
          "256 KiB UTF-8 total is accepted, including Unicode comments");
    NSString *oversized = [limit stringByAppendingString:@"!"];
    CHECK(!LTValidateCustomFilters(oversized, nil) && !Profile(oversized), "the UTF-8 byte limit is enforced even below the character limit");
    CHECK(!LTValidateCustomFilters([limit stringByAppendingString:@" "], nil) && !Profile([limit stringByAppendingString:@" "]),
          "the original UTF-8 size is limited before whitespace-only lines are ignored");
}

static void TestRegex(void) {
    LTBlockingPolicy *policy = Policy(@"/track(er|ing)[0-9]+[.]js$/\n@@/tracker12[.]js$/");
    CHECK(LTValidateCustomFilters(@"/track(er|ing)[0-9]+[.]js$/\n@@/tracker12[.]js$/", nil) &&
          Blocks(policy, @"https://cdn.example/TRACKING34.JS") && !Blocks(policy, @"https://cdn.example/tracker12.js") &&
          !Blocks(policy, @"https://cdn.example/tracker.js") && !Blocks(policy, @"https://cdn.example/tracking34.js?extra"),
          "regex blocks and exceptions preserve alternation, repetition, case folding and end anchors");
    for (NSString *text in @[@"||bundled.example^\n@@/bundled[.]example/", @"@@/bundled[.]example/\n||bundled.example^",
                             @"/bundled[.]example/\n@@||bundled.example^"])
        CHECK(!Blocks(Policy(text), @"https://bundled.example/a"), "regex and glob exceptions override custom and bundled blocks in either order");
    CHECK(Blocks(Policy(@"/allowed[.]example/"), @"https://allowed.example/a"), "a regex block overrides a bundled exception");
    CHECK(![policy blocksURL:@"https://cdn.example/tracking34.js" initiator:@"" type:@"main_frame" method:@"GET" topURL:@"https://cdn.example/"],
          "custom regex rules do not block main-frame navigation");
    CHECK(!Blocks(Policy(@"/tracker/"), @"file:///tracker.js"), "regex rules leave non-network schemes alone");
    CHECK(LTValidateCustomFilters(@"/foo##bar/", nil) && Profile(@"/foo#@#bar/"), "cosmetic delimiters inside regex bodies stay regex data");
    NSArray *invalid = @[@"/(/", @"/[z-a]/", @"/a(?=b)/", @"/(a)\\1/", @"/a++/", @"/a{33}/", @"/é/", @"/a\x01b/"];
    for (NSString *line in invalid) {
        NSError *error = nil;
        NSString *text = [@"##.kept\n" stringByAppendingString:line];
        CHECK(!LTValidateCustomFilters(text, &error) && [error.localizedDescription containsString:@"line 2"] && !Profile(text),
              "invalid, unsupported and non-ASCII regex input refuses the whole profile edit");
    }
    unichar nul[] = {'/', 'a', 0, 'b', '/'};
    NSString *withNul = [NSString stringWithCharacters:nul length:5];
    CHECK(!LTValidateCustomFilters(withNul, nil) && !Profile(withNul), "a regex containing NUL is refused without truncating its pattern");
    NSString *rules32 = Repeated(@"/z/\n", 32);
    CHECK(LTValidateCustomFilters(rules32, nil) && Profile(rules32) &&
          !LTValidateCustomFilters([rules32 stringByAppendingString:@"/z/"], nil) && !Profile([rules32 stringByAppendingString:@"/z/"]),
          "32 regex rules are accepted and a 33rd is refused");
    NSString *pattern512 = [NSString stringWithFormat:@"/[%@]/", Repeated(@"a", 510)];
    NSString *pattern513 = [NSString stringWithFormat:@"/[%@]/", Repeated(@"a", 511)];
    CHECK(LTValidateCustomFilters(pattern512, nil) && Profile(pattern512) && !LTValidateCustomFilters(pattern513, nil) && !Profile(pattern513),
          "regex source limit is 512 ASCII bytes independently of compiled size");
    NSString *program256 = [NSString stringWithFormat:@"/%@/\n", Repeated(@"a", 255)];
    NSString *program257 = [NSString stringWithFormat:@"/%@/", Repeated(@"a", 256)];
    CHECK(LTValidateCustomFilters(program256, nil) && !LTValidateCustomFilters(program257, nil) && !Profile(program257),
          "a regex may compile to 256 instructions including its final match, but not 257");
    NSString *total2048 = Repeated(program256, 8);
    CHECK(LTValidateCustomFilters(total2048, nil) && Profile(total2048) &&
          !LTValidateCustomFilters([total2048 stringByAppendingString:program256], nil) && !Profile([total2048 stringByAppendingString:program256]),
          "the entire list is limited to 2048 compiled regex instructions");
    NSString *base = @"https://ordinary.example/over-limit/";
    NSString *url8192 = [base stringByAppendingString:Repeated(@"x", 8192 - base.length)];
    NSString *url8193 = [url8192 stringByAppendingString:@"x"];
    CHECK(Blocks(Policy(@"/over-limit/"), url8192) && !Blocks(Policy(@"/over-limit/"), url8193),
          "regex matches an 8192-byte URL but does not truncate a longer URL");
    CHECK(Blocks(Policy(@"over-limit\n/not-found/"), url8193), "oversized regex URLs still use custom glob rules");
    NSString *bundledLong = [@"https://bundled.example/" stringByAppendingString:Repeated(@"a", 8193)];
    CHECK(Blocks(Policy(@"@@/bundled[.]example/"), bundledLong), "skipping regex on a long URL preserves bundled network decisions");
    NSString *expensive = Repeated(@"/a+a+a+a+a+b$/\n", 31);
    NSString *tail = Repeated(@"a", 600);
    NSString *ordinary = [@"https://ordinary.example/" stringByAppendingString:tail];
    NSString *bundled = [@"https://bundled.example/" stringByAppendingString:tail];
    CHECK(Blocks(Policy(@"/ordinary[.]example/"), ordinary) &&
          !Blocks(Policy([expensive stringByAppendingString:@"/ordinary[.]example/"]), ordinary),
          "exhausting the block-regex pass skips a later matching regex rather than exceeding its budget");
    CHECK(!Blocks(Policy([expensive stringByAppendingString:@"@@/bundled[.]example/"]), bundled) &&
          Blocks(Policy(expensive), bundled), "expensive block regexes cannot starve a later exception, and budget fallback preserves bundled blocking");
    NSString *expensiveExceptions = Repeated(@"@@/a+a+a+a+a+b$/\n", 31);
    CHECK(!Blocks(Policy([expensiveExceptions stringByAppendingString:@"/ordinary[.]example/"]), ordinary) &&
          Blocks(Policy([expensiveExceptions stringByAppendingString:@"||ordinary.example^"]), ordinary),
          "exhausting regex exceptions skips all regex decisions but preserves custom glob decisions");
}

static void TestCosmeticInput(void) {
    NSArray *valid = @[@"example.com##.ad", @"EXAMPLE.COM.###ad", @"##.ad, #Keep", @"localhost#@#.ad",
        @"127.0.0.1##div.banner > a + * ~ #id", @"xn--bcher-kva.example##[data-ad]",
        @"##div[data-test = value]", @"##[data-x^='abc']", @"##[data-x$=\"abc\"]", @"##[data-x*=x]",
        @"##[data-x~=x]", @"##[data-x|=en]", @"##[data-x='']", @"##[data-x='a,b'] , .keep",
        @"##[data-x='};@import']", @"##-custom.--x#_id[data-x=--value]", @"##div .ad[attr]"];
    for (NSString *line in valid)
        CHECK(LTValidateCustomFilters(line, nil) && Profile(line), "supported CSS compounds, lists, attributes and scopes validate in both editor and profile");
    NSArray *invalid = @[@"##", @"##div,", @"##,div", @"##div,,span", @"##div >", @"##div > + span",
        @"##div:not(.ad)", @"##.ad::before", @"##.a\\:b", @"##[data-x=123]", @"##[data-x='x' i]",
        @"##[data-x!='x']", @"##[data-x=]", @"##[data-x='unterminated]", @"##[data-x='x' garbage]",
        @"##div){display:none}@import url(x)", @"##.ad;@import", @"##.ad{color:red}", @"##[data-x='x'];body",
        @"example.com,other.com##.ad", @"~example.com##.ad", @"example.*##.ad", @"https://example.com##.ad",
        @"example.com:80##.ad", @"example..com##.ad", @"-example.com##.ad", @"example-.com##.ad",
        @"999.0.0.1##.ad", @"example.com#?#div", @"example.com##+js(test)", @"##div\t.ad", @"##.é", @"K.example##.ad",
        @"##svg|rect", @"##[x|name=foo]", @"##.1bad", @"##-", @"##*div", @"##[x='escaped\\value']"];
    for (NSString *line in invalid) {
        NSError *error = nil;
        NSString *text = [@"/valid-regex/\n" stringByAppendingString:line];
        CHECK(!LTValidateCustomFilters(text, &error) && [error.localizedDescription containsString:@"line 2"] && !Profile(text),
              "unsupported or injection-shaped cosmetic syntax rejects the whole mixed edit with its line number");
    }
    NSString *thousand = Repeated(@"##.a,.b\n", 500);
    CHECK(LTValidateCustomFilters(thousand, nil) && Profile(thousand) &&
          !LTValidateCustomFilters([thousand stringByAppendingString:@"##.c"], nil) && !Profile([thousand stringByAppendingString:@"##.c"]),
          "1000 expanded cosmetic selectors are accepted but a 1001st is refused below the line-count limit");
}

static void TestCosmetics(LTContentBlocker *bundle, LTContentBlocker *replacement) {
    [LTContentBlocker install:bundle];
    NSString *groups = @"https://groups.example/";
    NSSet *bundledOnly = Hidden(Policy(@""), groups, groups);
    CHECK([bundledOnly containsObject:@"#bio_ep, #bio_ep_bg"] &&
          [bundledOnly containsObject:@".outer:is(.left,.right), [data-ad=\"x,y\"]"],
          "bundled-only styles retain their original grouped selector strings");
    NSSet *oneException = Hidden(Policy(@"groups.example#@##bio_ep"), groups, groups);
    CHECK(![oneException containsObject:@"#bio_ep"] && ![oneException containsObject:@"#bio_ep, #bio_ep_bg"] &&
          [oneException containsObject:@"#bio_ep_bg"],
          "one custom exception removes only its member of a bundled selector list");
    NSSet *twoExceptions = Hidden(Policy(@"groups.example#@##bio_ep, #bio_ep_bg"), groups, groups);
    CHECK(![twoExceptions containsObject:@"#bio_ep"] && ![twoExceptions containsObject:@"#bio_ep_bg"] &&
          ![twoExceptions containsObject:@"#bio_ep, #bio_ep_bg"],
          "a custom exception list removes both bundled selector-list members");
    CHECK([oneException containsObject:@".outer:is(.left,.right)"] &&
          [oneException containsObject:@"[data-ad=\"x,y\"]"] &&
          [oneException containsObject:@".escaped\\,comma"] &&
          [oneException containsObject:@".commented/* a,b */"],
          "bundle composition preserves commas inside functions, quotes, escapes and comments");
    CHECK(![oneException containsObject:@"#gone_one"] && ![oneException containsObject:@"#gone_two"] &&
          ![oneException containsObject:@"#gone_one, #gone_two"],
          "bundled exceptions are applied before selector lists are split for custom composition");
    NSString *page = @"https://page.example/";
    NSString *text = @"##.generic\nPAGE.EXAMPLE.##.scoped\npage.example##.a,.b\npage.example#@#.a\n#@#.bundled\n"
        @"page.example##.upstream-excepted\n##.quoted[data-value=\"a,b\"] > #KeEp\npage.example#@#.generic";
    LTBlockingPolicy *policy = Policy(text);
    NSSet *expected = [NSSet setWithArray:@[@".bundled-specific", @".scoped", @".b", @".upstream-excepted", @".quoted[data-value=\"a,b\"] > #KeEp"]];
    CHECK([Hidden(policy, page, page) isEqual:expected], "one composed stylesheet applies custom exceptions to bundled/custom rules and custom hides over bundled exceptions");
    CHECK([Hidden(policy, @"https://SUB.PAGE.EXAMPLE./", page) isEqual:expected], "cosmetic host scope includes subdomains and normalizes host case and trailing dots");
    for (NSString *url in @[@"https://notpage.example/", @"https://page.example.evil/"]) {
        NSSet *selectors = Hidden(policy, url, page);
        CHECK([selectors containsObject:@".generic"] && ![selectors containsObject:@".scoped"] && ![selectors containsObject:@".b"],
              "generic selectors reach other hosts without crossing a scoped hostname boundary");
    }
    for (NSString *rules in @[@"##.same\n#@#.same", @"#@#.same\n##.same"])
        CHECK(![Hidden(Policy(rules), page, page) containsObject:@".same"], "cosmetic exceptions win regardless of line order");
    CHECK(![Hidden(Policy(@"##.a,.b\n#@#.a"), page, page) containsObject:@".a"] &&
          [Hidden(Policy(@"##.a,.b\n#@#.a"), page, page) containsObject:@".b"], "an exception removes one expanded list member without removing its neighbors");
    CHECK([Hidden(Policy(@"@@||page.example^\n##.custom"), page, page) containsObject:@".custom"],
          "network exceptions do not disable cosmetic hiding");
    CHECK(![policy cosmeticScriptForURL:@"file:///tmp/example" topURL:page].length &&
          ![policy cosmeticScriptForURL:@"about:blank" topURL:page].length, "cosmetic scripts do not run on internal or file documents");
    for (NSDictionary *pause in @[@{@"disabled": @YES}, @{@"cosmeticDisabled": @YES}, @{@"disabledSites": @[@"page.example"]}]) {
        NSMutableDictionary *preferences = [pause mutableCopy]; preferences[@"customFilters"] = text;
        [policy updatePreferences:preferences];
        CHECK(![policy cosmeticScriptForURL:@"https://frame.example/" topURL:page].length,
              "global, cosmetic and top-host pause each suppress the entire composed stylesheet");
    }
    [policy updatePreferences:@{@"customFilters": text, @"disabledSites": @[@"frame.example"]}];
    CHECK([Hidden(policy, @"https://frame.example/", page) containsObject:@".generic"],
          "embedded-frame cosmetics retain the existing top-page pause policy");
    [policy updatePreferences:@{@"customFilters": text}];
    [policy updatePreferences:@{@"customFilters": @"/new-block/\n##.broken:hover", @"disabled": @YES}];
    CHECK([Hidden(policy, page, page) isEqual:expected] && !Blocks(policy, @"https://ordinary.example/new-block"),
          "a bad selector preserves the previous whole policy and installs no accompanying regex");
    [LTContentBlocker install:replacement];
    NSSet *changed = Hidden(policy, page, page);
    CHECK([changed containsObject:@".replacement"] && [changed containsObject:@".scoped"] && ![changed containsObject:@".bundled-specific"],
          "replacing shared filters preserves custom cosmetics and uses the new bundled selector snapshot");
    LTBlockingPolicy *exception = Policy(@"#@#.replacement\n##.private-only");
    CHECK(![Hidden(exception, page, page) containsObject:@".replacement"] &&
          [Hidden(exception, page, page) containsObject:@".private-only"] && ![Hidden(policy, page, page) containsObject:@".private-only"],
          "independent contexts keep their own cosmetic exceptions and additions after replacement");
    [policy updatePreferences:@{@"customFilters": @""}];
    CHECK(([Hidden(policy, page, page) isEqual:[NSSet setWithObject:@".replacement"]]), "removing custom filters leaves only the current bundled stylesheet");
    [LTContentBlocker install:bundle];
}

static void TestMatching(LTContentBlocker *bundle, LTContentBlocker *replacement) {
    [LTContentBlocker install:bundle];
    CHECK([bundle decisionForURL:@"https://bundled.example/a" initiator:@"https://page.example" type:@"script" method:@"GET"] == LTNetworkBlock &&
          [bundle decisionForURL:@"https://allowed.example/a" initiator:@"https://page.example" type:@"script" method:@"GET"] == LTNetworkAllow &&
          [bundle decisionForURL:@"https://unmatched.example/a" initiator:@"https://page.example" type:@"script" method:@"GET"] == LTNetworkNoMatch,
          "bundled matcher distinguishes block, allow and no match");
    LTBlockingPolicy *policy = Policy(@"||ads.example^\n|https://exact.example/path|\n/track*pixel^\n/Case.js|");
    CHECK(LTValidateCustomFilters(@"/", nil) && Blocks(Policy(@"/"), @"https://plain.example/path"),
          "a single slash is a literal path pattern, not an empty regular expression");
    CHECK(LTValidateCustomFilters(@"@@/", nil) && !Blocks(Policy(@"@@/"), @"https://bundled.example/path"),
          "a single slash exception matches a normally blocked request");
    LTBlockingPolicy *segmented = Policy(@"ab*cd^MandatoryTail|");
    CHECK(Blocks(segmented, @"https://cdn.example/ab--cd/MANDATORYTAIL"),
          "a mandatory literal after wildcard and separator segments matches with ASCII case folding");
    CHECK(!Blocks(segmented, @"https://cdn.example/xx--cd/MandatoryTail") &&
          !Blocks(segmented, @"https://cdn.example/ab--cd/MandatoryTail/extra"),
          "finding a mandatory literal still requires the full pattern and end anchor to match");
    LTBlockingPolicy *anchored = Policy(@"||MixedAds.Example^\n@@||MixedAds.Example/safe*AllowedSuffix|");
    CHECK(Blocks(anchored, @"https://sub.MIXEDADS.example/blocked") &&
          !Blocks(anchored, @"https://sub.MIXEDADS.example/safe-ALLOWEDSUFFIX") &&
          Blocks(anchored, @"https://sub.MIXEDADS.example/else-ALLOWEDSUFFIX"),
          "mandatory literals preserve domain-anchored custom blocks and exceptions");
    CHECK(!Blocks(anchored, @"https://good.example/MixedAds.Example/blocked"),
          "a domain literal in the URL path does not bypass the hostname anchor");
    for (NSString *pattern in @[@"*", @"^"])
        CHECK(Blocks(Policy(pattern), @"https://plain.example/path"), "patterns without a literal still use full matching");
    LTBlockingPolicy *shortPattern = Policy(@"ab*cd^");
    CHECK(Blocks(shortPattern, @"https://plain.example/ab--cd/") && !Blocks(shortPattern, @"https://plain.example/ab--cdef"),
          "short literal segments retain wildcard and separator behavior");
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
    [policy updatePreferences:@{@"customFilters": @"||new.example^\nsite.example##.ad:hover", @"disabled": @YES}];
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
    NSString *text = @" \t\r\n[Adblock Plus 2.0]\r\n ! Kept exactly\r\n\t||saved.example^  \r\n @@||saved.example/safe\t\r\n"
        @" /saved-regex/ \r\n ##.saved-cosmetic \r\n #@#.bundled \r\n";
    CHECK(store && [store commit:^(LTProfile *p) { p.settings[@"contentBlocking"] = @{@"customFilters": text}; } error:&error],
          "valid custom filter text commits through the real store");
    error = nil;
    CHECK(![store commit:^(LTProfile *p) { p.settings[@"contentBlocking"] = @{@"customFilters": @"||new.example^\n/(?=ad)/"}; } error:&error] && error &&
          [store.profile.settings[@"contentBlocking"][@"customFilters"] isEqual:text],
          "a failed profile commit keeps the entire previous custom filter text");
    [store close];
    store = [[LTStore alloc] initWithPath:path error:&error];
    CHECK([store.profile.settings[@"contentBlocking"][@"customFilters"] isEqual:text], "custom filters persist exactly across reopening SQLite");
    LTBlockingPolicy *regular = [LTBlockingPolicy new];
    [regular updatePreferences:store.profile.settings[@"contentBlocking"]];
    CHECK(Blocks(regular, @"https://saved.example/a") && !Blocks(regular, @"https://saved.example/safe") &&
          Blocks(regular, @"https://ordinary.example/saved-regex") &&
          [Hidden(regular, @"https://page.example/", @"https://page.example/") containsObject:@".saved-cosmetic"] &&
          ![Hidden(regular, @"https://page.example/", @"https://page.example/") containsObject:@".bundled"],
          "reopened custom filters retain glob, regex and cosmetic behavior");
    LTStore *privateStore = [[LTStore alloc] initWithPath:nil error:nil];
    CHECK([privateStore commit:^(LTProfile *p) { p.settings[@"contentBlocking"] = @{@"customFilters": text}; } error:nil],
          "a copied custom filter snapshot can be stored in a private profile");
    LTBlockingPolicy *privatePolicy = [LTBlockingPolicy new];
    [privatePolicy updatePreferences:privateStore.profile.settings[@"contentBlocking"]];
    CHECK(Blocks(privatePolicy, @"https://saved.example/a") && Blocks(privatePolicy, @"https://ordinary.example/saved-regex") &&
          [Hidden(privatePolicy, @"https://page.example/", @"https://page.example/") containsObject:@".saved-cosmetic"],
          "copied private filters initially enforce the complete regular snapshot");
    [privateStore commit:^(LTProfile *p) { p.settings[@"contentBlocking"] = @{@"customFilters": @"||private.example^\n/private-regex/\n##.private-cosmetic"}; } error:nil];
    [privatePolicy updatePreferences:privateStore.profile.settings[@"contentBlocking"]];
    CHECK(Blocks(privatePolicy, @"https://private.example/a") && !Blocks(privatePolicy, @"https://saved.example/a") &&
          Blocks(regular, @"https://saved.example/a") && !Blocks(regular, @"https://private.example/a") &&
          Blocks(privatePolicy, @"https://ordinary.example/private-regex") && !Blocks(privatePolicy, @"https://ordinary.example/saved-regex") &&
          Blocks(regular, @"https://ordinary.example/saved-regex") && !Blocks(regular, @"https://ordinary.example/private-regex") &&
          [Hidden(privatePolicy, @"https://page.example/", @"https://page.example/") containsObject:@".private-cosmetic"] &&
          ![Hidden(privatePolicy, @"https://page.example/", @"https://page.example/") containsObject:@".saved-cosmetic"] &&
          [Hidden(regular, @"https://page.example/", @"https://page.example/") containsObject:@".saved-cosmetic"] &&
          ![Hidden(regular, @"https://page.example/", @"https://page.example/") containsObject:@".private-cosmetic"],
          "private edits change only their own glob, regex and cosmetic matchers");
    [privateStore close];
    [store close];
    store = [[LTStore alloc] initWithPath:path error:nil];
    CHECK([store.profile.settings[@"contentBlocking"][@"customFilters"] isEqual:text], "private edits do not reach regular profile storage");
    [store close];
    // Bypass the store writer, as an outside editor can, then use the normal disk reader.
    NSMutableDictionary *malformed = [LTProfile.fresh.JSON mutableCopy];
    malformed[@"settings"] = @{@"contentBlocking": @{@"customFilters": @"||saved.example^\nsite.example##.ad:hover"}};
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
    // Both complete sets enforce the same network and cosmetic decisions. Different sizes and
    // ordering expose a partially rebuilt set without depending on which set won.
    NSString *first = [Repeated(@"||other.example^\n", 128)
        stringByAppendingString:@"||always.example^\n@@||bundled.example^\n/regex-always/\n##.alwaysHidden\n#@#.bundled"];
    NSString *second = [@"#@#.bundled\n##.alwaysHidden\n/regex-always/\n@@||bundled.example^\n||always.example^\n"
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
                    NSSet *hidden = Hidden(policy, @"https://page.example/", @"https://page.example/");
                    if (!Blocks(policy, @"https://always.example/a") || Blocks(policy, @"https://bundled.example/a") ||
                        !Blocks(policy, @"https://ordinary.example/regex-always") ||
                        ![hidden containsObject:@".alwaysHidden"] || [hidden containsObject:@".bundled"])
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

static void TestRequestCost(void) {
    NSMutableString *rules = [NSMutableString new];
    for (NSUInteger i = 0; i < 998; ++i) {
        if (i % 2) [rules appendFormat:@"metrics*segment-%lu*pixel^\n", (unsigned long)i];
        else [rules appendFormat:@"||host-%lu.metrics.example^\n", (unsigned long)i];
    }
    [rules appendString:@"/late-block\n@@/late-block/allowed"];
    LTBlockingPolicy *policy = Policy(rules);
    NSMutableArray<NSString *> *requests = [NSMutableArray new];
    NSString *base = [@"https://cdn.example/assets/metrics/" stringByAppendingString:Repeated(@"segment/", 24)];
    BOOL bounded = YES;
    for (NSUInteger i = 0; i < 3000; ++i) {
        NSString *url = [NSString stringWithFormat:@"%@ordinary/resource-%lu.js?version=1", base, (unsigned long)i];
        bounded &= url.length <= 512;
        [requests addObject:url];
    }
    CHECK(bounded && LTValidateCustomFilters(rules, nil), "request-cost fixture has 1000 valid rules and URLs of at most 512 characters");
    CHECK(Blocks(policy, [base stringByAppendingString:@"late-block/resource.js"]) &&
          !Blocks(policy, [base stringByAppendingString:@"late-block/allowed/resource.js"]),
          "the last block and exception both take effect in a 1000-rule set");
    for (NSUInteger i = 0; i < 30; ++i) Blocks(policy, requests[i]);
    NSUInteger mismatches = 0;
    double elapsed = 0, slowest = 0;
    for (NSString *url in requests) {
        @autoreleasepool {
            double started = NSProcessInfo.processInfo.systemUptime;
            BOOL blocked = Blocks(policy, url);
            double duration = NSProcessInfo.processInfo.systemUptime - started;
            elapsed += duration;
            if (duration > slowest) slowest = duration;
            if (blocked) ++mismatches;
        }
    }
    double meanMS = elapsed * 1000 / requests.count;
    CHECK(mismatches == 0, "1000 custom rules preserve every nonmatching request");
    // About 3x the initial 0.113 ms arm64 mean, with another 2x for slower Intel runners.
#if defined(__x86_64__)
    const double budgetMS = .700;
#else
    const double budgetMS = .350;
#endif
    CHECK(meanMS < budgetMS, "1000 custom rules stay within the architecture's mean request budget");
    printf("Custom filter request cost: 1000 rules, %lu nonmatching requests, mean %.3f ms, slowest %.3f ms (mean budget %.3f ms)\n",
           (unsigned long)requests.count, meanMS, slowest * 1000, budgetMS);
}

static void TestMixedRequestCost(void) {
    NSMutableString *rules = [NSMutableString new];
    for (NSUInteger i = 0; i < 966; ++i) {
        if (i % 2) [rules appendFormat:@"metrics*segment-%lu*pixel^\n", (unsigned long)i];
        else [rules appendFormat:@"||host-%lu.metrics.example^\n", (unsigned long)i];
    }
    [rules appendString:@"/late-block\n@@/late-block/allowed\n"];
    for (NSUInteger i = 0; i < 32; ++i)
        [rules appendFormat:@"/regex-%lu-.*pixel$/\n", (unsigned long)i];
    LTBlockingPolicy *policy = Policy(rules);
    NSMutableArray<NSString *> *requests = [NSMutableArray new];
    NSString *base = [@"https://cdn.example/assets/metrics/" stringByAppendingString:Repeated(@"segment/", 24)];
    BOOL bounded = YES;
    for (NSUInteger i = 0; i < 3000; ++i) {
        NSString *url = [NSString stringWithFormat:@"%@ordinary/resource-%lu.js?version=1", base, (unsigned long)i];
        bounded &= url.length <= 512;
        [requests addObject:url];
    }
    CHECK(bounded && LTValidateCustomFilters(rules, nil), "mixed request-cost fixture has 968 globs, 32 regexes and URLs of at most 512 characters");
    CHECK(Blocks(policy, [base stringByAppendingString:@"late-block/resource.js"]) &&
          !Blocks(policy, [base stringByAppendingString:@"late-block/allowed/resource.js"]) &&
          Blocks(policy, @"https://cdn.example/regex-31-pixel"), "last glob block, glob exception and regex take effect in a mixed 1000-rule set");
    for (NSUInteger i = 0; i < 30; ++i) Blocks(policy, requests[i]);
    NSUInteger mismatches = 0;
    double elapsed = 0, slowest = 0;
    for (NSString *url in requests) {
        @autoreleasepool {
            double started = NSProcessInfo.processInfo.systemUptime;
            BOOL blocked = Blocks(policy, url);
            double duration = NSProcessInfo.processInfo.systemUptime - started;
            elapsed += duration;
            if (duration > slowest) slowest = duration;
            if (blocked) ++mismatches;
        }
    }
    double meanMS = elapsed * 1000 / requests.count;
    CHECK(mismatches == 0, "1000 mixed custom rules preserve every nonmatching request");
#if defined(__x86_64__)
    const double budgetMS = .700;
#else
    const double budgetMS = .350;
#endif
    CHECK(meanMS < budgetMS, "1000 mixed custom rules stay within the architecture's mean request budget");
    printf("Custom mixed filter request cost: 968 globs + 32 regexes, %lu nonmatching requests, mean %.3f ms, slowest %.3f ms (mean budget %.3f ms)\n",
           (unsigned long)requests.count, meanMS, slowest * 1000, budgetMS);
}

static void TestCosmeticCacheLifecycle(LTContentBlocker *bundle, LTContentBlocker *replacement) {
    [LTContentBlocker install:bundle];
    NSString *page = @"https://page.example/";
    LTBlockingPolicy *regular = Policy(@"##.regular-old\n#@#.bundled");
    LTBlockingPolicy *privatePolicy = Policy(@"##.private\n#@#.bundled");
    NSSet *regularInitial = Hidden(regular, page, page), *privateInitial = Hidden(privatePolicy, page, page);
    BOOL stable = YES;
    for (NSUInteger i = 0; i < 100; ++i) {
        NSString *url = [NSString stringWithFormat:@"https://PAGE.EXAMPLE./reload-%lu", (unsigned long)i];
        stable &= [Hidden(regular, url, page) isEqual:regularInitial] && [Hidden(privatePolicy, url, page) isEqual:privateInitial];
    }
    CHECK(stable && [regularInitial containsObject:@".regular-old"] && ![regularInitial containsObject:@".private"] &&
          [privateInitial containsObject:@".private"] && ![privateInitial containsObject:@".regular-old"],
          "repeated same-host styles normalize hostname and remain isolated between regular and private policies");
    [regular updatePreferences:@{@"customFilters": @"##.regular-new"}];
    NSSet *edited = Hidden(regular, page, page);
    CHECK([edited containsObject:@".regular-new"] && [edited containsObject:@".bundled"] && ![edited containsObject:@".regular-old"] &&
          [Hidden(privatePolicy, page, page) isEqual:privateInitial],
          "editing custom rules replaces warmed style content without changing another policy");
    [regular updatePreferences:@{@"customFilters": @"##.regular-new", @"disabledSites": @[@"paused.example"]}];
    CHECK(![regular cosmeticScriptForURL:page topURL:@"https://paused.example/"].length &&
          [Hidden(regular, page, page) isEqual:edited], "a warm stylesheet still obeys each request's top-page pause");
    [regular updatePreferences:@{@"customFilters": @"##.regular-new", @"cosmeticDisabled": @YES}];
    CHECK(![regular cosmeticScriptForURL:page topURL:page].length, "cosmetic pause suppresses an already warmed stylesheet");
    [regular updatePreferences:@{@"customFilters": @"##.regular-new"}];
    CHECK([Hidden(regular, page, page) isEqual:edited], "resuming cosmetic hiding restores the current custom snapshot");
    [LTContentBlocker install:replacement];
    NSSet *regularUpdated = Hidden(regular, page, page), *privateUpdated = Hidden(privatePolicy, page, page);
    CHECK([regularUpdated containsObject:@".replacement"] && [regularUpdated containsObject:@".regular-new"] &&
          ![regularUpdated containsObject:@".bundled"] && [privateUpdated containsObject:@".replacement"] &&
          [privateUpdated containsObject:@".private"] && ![privateUpdated containsObject:@".bundled-specific"],
          "installing bundled filters refreshes warmed styles in every policy while preserving their custom rules");
    [regular updatePreferences:@{@"customFilters": @"##.regular-new\n#@#.replacement"}];
    CHECK(![Hidden(regular, page, page) containsObject:@".replacement"] &&
          [Hidden(privatePolicy, page, page) isEqual:privateUpdated],
          "a new custom exception removes a warmed bundled selector in only its own policy");
    [LTContentBlocker install:bundle];
    CHECK([Hidden(regular, page, page) containsObject:@".bundled"] && ![Hidden(regular, page, page) containsObject:@".replacement"] &&
          [Hidden(privatePolicy, page, page) isEqual:privateInitial],
          "reinstalling an earlier bundle does not reuse styles from the intervening bundle");
    [regular updatePreferences:@{@"customFilters": @""}];
    CHECK([[regular cosmeticScriptForURL:page topURL:page] isEqual:[bundle cosmeticScriptForURL:page]] &&
          [Hidden(privatePolicy, page, page) isEqual:privateInitial],
          "removing custom filters restores bundled-only output without clearing another policy's custom styles");
    LTBlockingPolicy *racing = Policy(@"##.race");
    NSSet *first = Hidden(racing, page, page);
    [LTContentBlocker install:replacement];
    NSSet *second = Hidden(racing, page, page);
    dispatch_group_t group = dispatch_group_create();
    dispatch_semaphore_t ready = dispatch_semaphore_create(0), start = dispatch_semaphore_create(0);
    NSObject *lock = [NSObject new];
    __block NSUInteger mismatches = 0;
    for (NSUInteger worker = 0; worker < 4; ++worker) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            dispatch_semaphore_signal(ready);
            dispatch_semaphore_wait(start, DISPATCH_TIME_FOREVER);
            NSUInteger local = 0;
            for (NSUInteger request = 0; request < 500; ++request) {
                @autoreleasepool {
                    NSSet *selectors = Hidden(racing, page, page);
                    if (![selectors isEqual:first] && ![selectors isEqual:second]) ++local;
                }
            }
            @synchronized (lock) { mismatches += local; }
        });
    }
    for (NSUInteger worker = 0; worker < 4; ++worker) dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
    for (NSUInteger worker = 0; worker < 4; ++worker) dispatch_semaphore_signal(start);
    for (NSUInteger update = 0; update < 400; ++update) [LTContentBlocker install:update % 2 ? bundle : replacement];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    [LTContentBlocker install:bundle];
    CHECK(mismatches == 0 && [Hidden(racing, page, page) isEqual:first],
          "concurrent bundled installs yield complete styles and cannot leave a stale result after the final install");
}

static void TestCosmeticCompositionCost(NSString *directory) {
    LTContentBlocker *bundled = [[LTContentBlocker alloc] initWithDirectory:directory];
    CHECK(bundled != nil, "the cosmetic composition benchmark loads the real bundled filter set");
    if (!bundled) return;
    [LTContentBlocker install:bundled];
    NSArray<NSString *> *hosts = @[@"google.com", @"youtube.com", @"facebook.com", @"wikipedia.org", @"reddit.com",
        @"amazon.com", @"yahoo.com", @"bing.com", @"instagram.com", @"twitter.com", @"x.com", @"linkedin.com",
        @"netflix.com", @"twitch.tv", @"github.com", @"stackoverflow.com", @"apple.com", @"microsoft.com",
        @"bbc.com", @"cnn.com", @"nytimes.com", @"theguardian.com", @"reuters.com", @"washingtonpost.com",
        @"espn.com", @"imdb.com", @"fandom.com", @"pinterest.com", @"ebay.com", @"weather.com",
        @"accuweather.com", @"forbes.com", @"bloomberg.com", @"medium.com", @"quora.com", @"tumblr.com",
        @"wordpress.com", @"dailymotion.com", @"vimeo.com", @"spotify.com", @"soundcloud.com", @"dropbox.com",
        @"office.com", @"zoom.us", @"discord.com", @"slack.com", @"duckduckgo.com", @"brave.com",
        @"4j.com", @"1024tera.com"];
    CHECK(hosts.count == 50, "the real-bundle cosmetic benchmark covers 50 distinct representative hosts");
    for (NSArray<NSString *> *fixture in @[@[@"bundled only", @""], @[@"custom generic", @"##.lite-benchmark-hide"],
                                           @[@"custom unrelated scope", @"unrelated.example##.lite-benchmark-hide"]]) {
        LTBlockingPolicy *policy = Policy(fixture[1]);
        double elapsed = 0, slowest = 0;
        BOOL complete = YES;
        for (NSString *host in hosts) {
            @autoreleasepool {
                NSString *url = [NSString stringWithFormat:@"https://%@/", host];
                double started = NSProcessInfo.processInfo.systemUptime;
                NSString *script = [policy cosmeticScriptForURL:url topURL:url];
                double duration = NSProcessInfo.processInfo.systemUptime - started;
                elapsed += duration;
                if (duration > slowest) slowest = duration;
                complete &= script.length > 100000;
            }
        }
        CHECK(complete, "each measured host composes the full bundled cosmetic payload");
        printf("Cosmetic composition (%s): 50 distinct hosts, mean %.3f ms, slowest %.3f ms\n",
               fixture[0].UTF8String, elapsed * 1000 / hosts.count, slowest * 1000);
        NSString *url = @"https://www.reddit.com/";
        NSString *expected = [policy cosmeticScriptForURL:url topURL:url];
        elapsed = slowest = 0;
        BOOL stable = YES;
        for (NSUInteger i = 0; i < 100; ++i) {
            @autoreleasepool {
                double started = NSProcessInfo.processInfo.systemUptime;
                NSString *script = [policy cosmeticScriptForURL:url topURL:url];
                double duration = NSProcessInfo.processInfo.systemUptime - started;
                elapsed += duration;
                if (duration > slowest) slowest = duration;
                stable &= [script isEqual:expected];
            }
        }
        CHECK(stable, "repeated full-bundle cosmetic requests preserve the composed stylesheet");
        // A separate cosmetic budget: the uncached baseline was about 11.6 ms,
        // while a warm request should only select the current immutable result.
        CHECK(elapsed * 1000 / 100 < 1.0, "warm full-bundle cosmetic requests average less than 1 ms");
        printf("Cosmetic composition (%s): 100 same-host requests after warm-up, mean %.3f ms, slowest %.3f ms\n",
               fixture[0].UTF8String, elapsed * 1000 / 100, slowest * 1000);
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        LTContentBlocker *bundle = Bundle([directory stringByAppendingPathComponent:@"original"], NO);
        LTContentBlocker *replacement = Bundle([directory stringByAppendingPathComponent:@"replacement"], YES);
        CHECK(bundle && replacement, "local bundled filter fixtures load");
        [LTContentBlocker install:bundle];
        TestInput();
        TestRegex();
        TestCosmeticInput();
        TestMatching(bundle, replacement);
        TestCosmetics(bundle, replacement);
        TestCosmeticCacheLifecycle(bundle, replacement);
        TestConcurrentReplacement();
        TestRequestCost();
        TestMixedRequestCost();
        TestPersistence(directory);
        CHECK(argc == 2, "the real bundled-filter directory is supplied to the custom-filter suite");
        if (argc == 2) TestCosmeticCompositionCost([NSString stringWithUTF8String:argv[1]]);
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
        printf("%d custom filter checks passed, %d failed\n", passed, failed);
        return failed ? 1 : 0;
    }
}
