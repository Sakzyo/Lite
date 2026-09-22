#import "../model/LTGitHub.h"
#import "../macos/LTShortcuts.h"
#import <Security/Security.h>
#import "../macos/LTFaviconCache.h"
#import "../migration/LTImporter.h"
#import "../model/LTCommandIndex.h"
#import "../model/LTLoginStore.h"
#import "../model/LTStore.h"
#import "../performance/LTPerformance.h"
#import <Foundation/Foundation.h>
static int passed = 0, failed = 0;
#define CHECK(condition, name)                                                                     \
    do {                                                                                           \
        if (condition) {                                                                           \
            passed++;                                                                              \
            printf("PASS %s\n", name);                                                             \
        } else {                                                                                   \
            failed++;                                                                              \
            fprintf(stderr, "FAIL %s (line %d)\n", name, __LINE__);                                \
        }                                                                                          \
    } while (0)
static NSData *JSON(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
}
static NSDictionary *Tab(NSString *identifier, NSString *title) {
    return
        @{@"id" : identifier, @"title" : title, @"url" : @"https://example.org/", @"kind" : @"tab"};
}
static NSDictionary *Fixture(void) {
    return @{
        @"spaces" :
            @[ @{@"id" : @"school", @"title" : @"School 📚", @"pinnedContainerID" : @"root"} ],
        @"items" : @[
            @{
                @"id" : @"root",
                @"data" : @{@"itemContainer" : @{}},
                @"childrenIds" : @[ @"folder", @"third" ]
            },
            @{
                @"id" : @"folder",
                @"title" : @"Physics",
                @"data" : @{@"list" : @{}},
                @"childrenIds" : @[ @"first", @"nested" ]
            },
            @{
                @"id" : @"nested",
                @"title" : @"实验",
                @"data" : @{@"list" : @{}},
                @"childrenIds" : @[ @"second" ]
            },
            Tab(@"first", @"Textbook"), Tab(@"second", @"Data"), Tab(@"third", @"Dictionary"),
            @{@"id" : @"favs",
              @"data" : @{@"itemContainer" : @{}},
              @"childrenIds" : @[ @"fav" ]},
            Tab(@"fav", @"Favorite")
        ],
        @"topAppsContainerID" : @"favs"
    };
}
int main(int argc, char **argv) {
    @autoreleasepool {
        NSError *e = nil;
        LTProfile *p = LTProfile.fresh;
        NSString *sid = p.activeSpaceID;
        CHECK([p validate:&e], "fresh profile validates");
        LTSpace *s = [p addSpace:@"Research"];
        NSString *second = s.identifier;
        s.name = @"School";
        p.activeSpaceID = second;
        CHECK([p.spaces count] == 2, "create space");
        CHECK([[p space:second].name isEqual:@"School"], "rename and switch space");
        LTNode *folder = [p addNode:@"folder" title:@"Physics" url:@"" space:sid parent:@""];
        LTNode *nested = [p addNode:@"folder"
                              title:@"Lab"
                                url:@""
                              space:sid
                             parent:folder.identifier];
        LTNode *a = [p addNode:@"pinned"
                         title:@"A"
                           url:@"https://example.org/a"
                         space:sid
                        parent:nested.identifier];
        LTNode *b = [p addNode:@"pinned"
                         title:@"B"
                           url:@"https://example.org/b"
                         space:sid
                        parent:nested.identifier];
        CHECK([p children:nested.identifier space:sid kind:nil].count == 2, "nested folders");
        CHECK([p moveNode:b.identifier space:sid parent:nested.identifier index:0 error:&e],
              "reorder pins");
        CHECK([[[p children:nested.identifier space:sid
                       kind:nil] firstObject].identifier isEqual:b.identifier],
              "pin order preserved");
        CHECK(![p moveNode:folder.identifier space:sid parent:nested.identifier index:0 error:&e],
              "reject folder cycle");
        CHECK([p moveNode:folder.identifier space:second parent:@"" index:0 error:&e] &&
                  [a.spaceID isEqual:second] && [b.spaceID isEqual:second],
              "move folder with descendants across spaces");
        a.url = @"https://example.org/navigation";
        a.customTitle = @"Personal name";
        CHECK([a.pinnedURL isEqual:@"https://example.org/a"] &&
                  [a.displayTitle isEqual:@"Personal name"],
              "pinned original URL and custom name");
        LTNode *fav = [p addNode:@"favorite"
                           title:@"Site"
                             url:@"https://example.org"
                           space:@""
                          parent:@""];
        LTNode *fav2 = [p addNode:@"favorite"
                            title:@"Second"
                              url:@"https://example.net"
                            space:@""
                           parent:@""];
        CHECK([p moveNode:fav2.identifier space:@"" parent:@"" index:0 error:&e],
              "reorder favorites");
        CHECK([p children:@"" space:@"" kind:@"favorite"].firstObject == fav2,
              "global favorite order");
        [p removeNode:fav.identifier];
        CHECK([p children:@"" space:@"" kind:@"favorite"].count == 1, "remove favorite");
        a.kind = @"temporary";
        a.parentID = @"";
        CHECK([p validate:&e], "unpin tab");
        a.kind = @"pinned";
        nested.expanded = NO;
        p.windows = [@[ @{
            @"space" : second,
            @"active" : a.identifier,
            @"secondary" : b.identifier,
            @"vertical" : @NO,
            @"ratio" : @0.35
        } ] mutableCopy];
        LTProfile *restored = [LTProfile fromJSON:p.JSON error:&e];
        CHECK(restored.nodes.count == p.nodes.count && ![restored node:nested.identifier].expanded,
              "restore nodes and folder expansion");
        CHECK([restored.windows.firstObject[@"ratio"] isEqual:@0.35],
              "restore split orientation and divider");
        [p removeSpace:sid];
        CHECK(p.spaces.count == 1 && [p validate:&e], "delete space and restore active workspace");
        [p removeSpace:second];
        CHECK(p.spaces.count == 1, "cannot delete last space");
        NSString *path = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[LTUUID() stringByAppendingString:@"/Lite.sqlite"]];
        LTStore *store = [[LTStore alloc] initWithPath:path error:&e];
        CHECK(store != nil, "open SQLite store");
        CHECK([store
                  commit:^(LTProfile *profile) {
                    [profile addSpace:@"Saved"];
                    [profile.nodes addObject:fav2];
                  }
                   error:&e],
              "transaction commits valid state");
        NSUInteger count = store.profile.spaces.count;
        CHECK(![store
                  commit:^(LTProfile *profile) {
                    [profile.spaces removeAllObjects];
                  }
                   error:&e] &&
                  store.profile.spaces.count == count,
              "failed transaction leaves state unchanged");
        store = nil;
        store = [[LTStore alloc] initWithPath:path error:&e];
        CHECK(store.profile.spaces.count == 2 && store.profile.nodes.count == 1,
              "SQLite session survives reopen");
        [store recordVisit:@"https://example.org" title:@"Example"];
        CHECK([store history:@"example" limit:10].count == 1, "history search");
        [store deleteHistoryURL:@"https://example.org"];
        CHECK([store history:@"" limit:10].count == 0, "delete history");
        LTStore *privateStore = [[LTStore alloc] initWithPath:nil error:&e];
        [privateStore recordVisit:@"https://private.example" title:@"Private"];
        CHECK([privateStore history:@"" limit:10].count == 0, "private history is never recorded");
        __block NSString *folderID, *childID;
        [store
            commit:^(LTProfile *profile) {
              LTNode *folder = [profile addNode:@"folder"
                                          title:@"Parent"
                                            url:@""
                                          space:profile.activeSpaceID
                                         parent:@""];
              folder.expanded = YES;
              folderID = folder.identifier;
              LTNode *child = [profile addNode:@"folder"
                                         title:@"Child"
                                           url:@""
                                         space:profile.activeSpaceID
                                        parent:folderID];
              child.expanded = YES;
              childID = child.identifier;
            }
             error:&e];
        [store
            commit:^(LTProfile *profile) {
              profile.settings[@"search"] = @"Google";
            }
             error:&e];
        CHECK([store.profile node:folderID].expanded && [store.profile node:childID].expanded,
              "unrelated saves preserve current-session folder expansion");
        store = nil;
        store = [[LTStore alloc] initWithPath:path error:&e];
        CHECK(![store.profile node:folderID].expanded && ![store.profile node:childID].expanded,
              "every folder starts collapsed when the profile reopens");
        CHECK([[store.profile node:childID].parentID isEqual:folderID] &&
                  [store.profile.settings[@"search"] isEqual:@"Google"],
              "startup collapse preserves hierarchy and settings");
        CHECK(
            [LTFaviconOrigin(@"HTTPS://Example.org:443/path?q=1#x") isEqual:@"https://example.org"],
            "favicon cache shares canonical origins across paths");
        CHECK(!LTFaviconOrigin(@"file:///tmp/icon.png") &&
                  !LTFaviconOrigin(@"https://user:pass@example.org") && !LTFaviconOrigin(nil),
              "favicon prefetch rejects local files and URL credentials");
        NSString *iconPath =
            [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Favicons"];
        LTFaviconCache *icons = [[LTFaviconCache alloc] initWithDirectory:iconPath];
        NSBitmapImageRep *pixels =
            [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                    pixelsWide:32
                                                    pixelsHigh:32
                                                 bitsPerSample:8
                                               samplesPerPixel:4
                                                      hasAlpha:YES
                                                      isPlanar:NO
                                                colorSpaceName:NSDeviceRGBColorSpace
                                                   bytesPerRow:128
                                                  bitsPerPixel:32];
        memset(pixels.bitmapData, 255, 4096);
        NSImage *icon = [[NSImage alloc] initWithSize:NSMakeSize(32, 32)];
        [icon addRepresentation:pixels];
        [icons storeImage:icon forURL:@"https://icons.example/a"];
        CHECK([icons imageForURL:@"https://icons.example/b"].size.width == 16,
              "favicon cache reuses a small image for unopened same-origin bookmarks");
        [icons shutdown];
        icons = [[LTFaviconCache alloc] initWithDirectory:iconPath];
        CHECK([icons imageForURL:@"https://icons.example/after-restart"] != nil,
              "favicons survive restart without a live page or network request");
        CHECK([icons imageForURL:@"https://different.example"] == nil,
              "favicon cache keeps different websites separate");
        NSBitmapImageRep *oversized =
            [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                    pixelsWide:1280
                                                    pixelsHigh:1024
                                                 bitsPerSample:8
                                               samplesPerPixel:4
                                                      hasAlpha:YES
                                                      isPlanar:NO
                                                colorSpaceName:NSDeviceRGBColorSpace
                                                   bytesPerRow:5120
                                                  bitsPerPixel:32];
        memset(oversized.bitmapData, 255, 5120 * 1024);
        NSImage *largeIcon = [[NSImage alloc] initWithSize:NSMakeSize(1280, 1024)];
        [largeIcon addRepresentation:oversized];
        [icons storeImage:largeIcon forURL:@"https://oversized.example"];
        CHECK([icons imageForURL:@"https://oversized.example"] == nil,
              "large pixel dimensions are rejected before favicon decoding");
        [icons shutdown];
        CHECK(
            [LTLoginOrigin(@"https://EXAMPLE.org:443/login?next=1") isEqual:@"https://example.org"],
            "logins match canonical HTTPS origins");
        CHECK([LTLoginOrigin(@"https://example.org:8443/login")
                  isEqual:@"https://example.org:8443"] &&
                  ![LTLoginOrigin(@"https://sub.example.org")
                      isEqual:LTLoginOrigin(@"https://example.org")],
              "login matching separates ports and subdomains");
        CHECK(!LTLoginOrigin(@"http://example.org") && !LTLoginOrigin(@"file:///login") &&
                  !LTLoginOrigin(@"https://user:pass@example.org") && !LTLoginOrigin(nil),
              "logins reject insecure remote origins and embedded credentials");
        CHECK([LTLoginOrigin(@"http://127.0.0.1:18743/login") isEqual:@"http://127.0.0.1:18743"],
              "loopback development logins retain their port");
        NSArray *arguments = NSProcessInfo.processInfo.arguments;
        if ([arguments containsObject:@"--check-icons"]) {
            icons = [[LTFaviconCache alloc] initWithDirectory:iconPath];
            LTProfile *sites = LTProfile.fresh;
            [sites addNode:@"pinned"
                     title:@"Unopened bookmark"
                       url:@"http://127.0.0.1:18743/icon-page"
                     space:sites.activeSpaceID
                    parent:@""];
            LTNode *large = [sites addNode:@"favorite"
                                     title:@"Oversized icon fallback"
                                       url:@"http://localhost:18743/icon-page"
                                     space:@""
                                    parent:@""];
            large.favicon = @"http://localhost:18743/oversized-icon";
            [icons prefetchNodes:sites.nodes];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
            while ((![icons imageForURL:sites.nodes.firstObject.url] ||
                    ![icons imageForURL:large.url]) &&
                   deadline.timeIntervalSinceNow > 0)
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
            CHECK([icons imageForURL:sites.nodes.firstObject.url] != nil,
                  "unopened bookmark icon discovered from a bounded HTML head");
            CHECK([icons imageForURL:large.url] != nil,
                  "oversized icon response rejected and replaced through HTML discovery");
            [icons shutdown];
            icons = [[LTFaviconCache alloc] initWithDirectory:iconPath];
            CHECK([icons imageForURL:large.url] != nil,
                  "prefetched icon available immediately at next startup");
            [icons shutdown];
        }
        if ([arguments containsObject:@"--check-keychain"]) {
            LTLoginStore *logins = [[LTLoginStore alloc] initWithProfilePath:path];
            NSDictionary *entry =
                @{@"origin" : @"https://synthetic.lite.invalid", @"username" : @"lite-test-user"};
            CHECK([logins saveUsername:entry[@"username"]
                              password:@"Synthetic-only-1!"
                                origin:entry[@"origin"]
                                 error:&e],
                  "save synthetic login to macOS Keychain");
            CHECK([logins entriesForOrigin:entry[@"origin"] error:&e].count == 1 &&
                      ![logins entriesForOrigin:entry[@"origin"] error:&e].firstObject[@"password"],
                  "login listings expose metadata without passwords");
            logins = [[LTLoginStore alloc] initWithProfilePath:path];
            CHECK([[logins passwordForEntry:entry error:&e] isEqual:@"Synthetic-only-1!"],
                  "Keychain login persists across store recreation");
            CHECK([logins saveUsername:entry[@"username"]
                              password:@"Synthetic-only-2!"
                                origin:entry[@"origin"]
                                 error:&e] &&
                      [[logins passwordForEntry:entry error:&e] isEqual:@"Synthetic-only-2!"] &&
                      [logins entriesForOrigin:entry[@"origin"] error:&e].count == 1,
                  "saving an existing login updates its password without duplicates");
            CHECK([logins entriesForOrigin:@"https://other.lite.invalid" error:&e].count == 0,
                  "saved logins are never suggested for a different origin");
            LTLoginStore *other =
                [[LTLoginStore alloc] initWithProfilePath:[path stringByAppendingString:@"-other"]];
            CHECK([other entriesForOrigin:nil error:&e].count == 0,
                  "isolated profiles cannot see each other's saved logins");
            CHECK(![logins saveUsername:@"invalid"
                               password:@"test"
                                 origin:@"http://remote.invalid"
                                  error:&e],
                  "Keychain store rejects unsafe website origins");
            CHECK([logins deleteEntry:entry error:&e] &&
                      [logins entriesForOrigin:nil error:&e].count == 0,
                  "delete synthetic login and leave no test credentials");
            NSString *host = [[NSUUID.UUID.UUIDString lowercaseString] stringByAppendingString:@".lite.invalid"];
            NSString *origin = [@"https://" stringByAppendingString:host];
            NSMutableDictionary *internet = [@{(id)kSecClass: (id)kSecClassInternetPassword,
                (id)kSecAttrServer: host, (id)kSecAttrProtocol: (id)kSecAttrProtocolHTTPS,
                (id)kSecAttrPort: @443, (id)kSecAttrAccount: @"synthetic-keychain-user",
                (id)kSecValueData: [@"Synthetic-Keychain-only!" dataUsingEncoding:NSUTF8StringEncoding]} mutableCopy];
            CHECK(SecItemAdd((__bridge CFDictionaryRef)internet, NULL) == errSecSuccess, "create synthetic system website Keychain entry");
            NSArray *websiteEntries = [logins keychainEntriesForOrigin:origin error:&e];
            CHECK(websiteEntries.count == 1 && !websiteEntries.firstObject[@"password"] && websiteEntries.firstObject[@"keychainReference"], "website Keychain lookup returns metadata and a reference only");
            if (websiteEntries.count) {
                CHECK([[logins passwordForEntry:websiteEntries.firstObject error:&e] isEqual:@"Synthetic-Keychain-only!"], "read only the selected website Keychain password");
                NSMutableDictionary *wrong = [websiteEntries.firstObject mutableCopy];
                wrong[@"origin"] = @"https://wrong.lite.invalid";
                CHECK(![logins passwordForEntry:wrong error:&e], "website Keychain reference cannot be used for another origin");
            }
            CHECK([logins keychainEntriesForOrigin:[origin stringByAppendingString:@":8443"] error:&e].count == 0 && [logins keychainEntriesForOrigin:@"http://remote.invalid" error:&e].count == 0, "website Keychain matches exact HTTPS port and rejects insecure hosts");
            [internet removeObjectForKey:(id)kSecValueData];
            CHECK(SecItemDelete((__bridge CFDictionaryRef)internet) == errSecSuccess, "remove synthetic system Keychain entry");
            CHECK([logins setGitHubToken:@"Synthetic-token-only" error:&e] && [[logins githubToken:&e] isEqual:@"Synthetic-token-only"] && [logins entriesForOrigin:nil error:&e].count == 0, "GitHub token is in Keychain, separate from website logins");
            CHECK([logins setGitHubToken:@"" error:&e] && [[logins githubToken:&e] isEqual:@""], "forget GitHub token removes its Keychain item");

        }
        CHECK([LTURLFromInput(@"example.org", @"DuckDuckGo") isEqual:@"https://example.org"],
              "URL normalization");
        CHECK([LTURLFromInput(@"two words", @"DuckDuckGo") containsString:@"q=two%20words"],
              "search encoding");
        CHECK(!LTValidURL(@"javascript:alert(1)") && !LTValidURL(@"https://") &&
                  !LTValidURL(@"https://user:password@example.org"),
              "reject unsafe persisted URL schemes and credentials");
        CHECK(LTFuzzyScore(@"nprv", @"New Private Window") > 0 &&
                  LTFuzzyScore(@"xyz", @"New Tab") == 0,
              "fuzzy matching");
        NSArray *results =
            LTCommandResults(@"example.org", p, @[], [NSSet setWithObject:a.identifier]);
        CHECK([results.firstObject[@"detail"] isEqual:@"Open address"] &&
                  [results.firstObject[@"value"] isEqual:@"https://example.org"],
              "bare web address opens directly");
        for (NSString *url in @[
                 @"https://unvisited.example/path?q=hello#section",
                 @"http://unvisited.example/path", @"http://127.0.0.1:18743/second"
             ]) {
            results = LTCommandResults(url, p, @[], [NSSet new]);
            CHECK(
                [results.firstObject[@"detail"] isEqual:@"Open address"] &&
                    [results.firstObject[@"value"] isEqual:url],
                "explicit HTTP or HTTPS link opens directly with path, query and fragment intact");
        }
        results = LTCommandResults(@"  example.org/path  ", p, @[], [NSSet new]);
        CHECK([results.firstObject[@"value"] isEqual:@"https://example.org/path"],
              "bare link trims surrounding whitespace and preserves path");
        results = LTCommandResults(@"localhost:18743/second", p, @[], [NSSet new]);
        CHECK([results.firstObject[@"value"] isEqual:@"http://localhost:18743/second"],
              "local address opens directly");
        results = LTCommandResults(@"learn example.org", p, @[], [NSSet new]);
        CHECK([results.firstObject[@"icon"] isEqual:@"magnifyingglass"],
              "search text containing a domain remains a search");
        results = LTCommandResults(@"Personal name", p, @[], [NSSet setWithObject:a.identifier]);
        CHECK([results.firstObject[@"value"] isEqual:a.identifier], "open-tab search");
        results = LTCommandResults(@"Split Right", p, @[], [NSSet new]);
        CHECK([results.firstObject[@"icon"] isEqual:@"magnifyingglass"] &&
                  [[results valueForKey:@"value"] containsObject:@"splitRight"],
              "search leads while browser commands remain selectable");
        results = LTCommandResults(@"Personal", p, @[], [NSSet setWithObject:a.identifier]);
        CHECK([results.firstObject[@"icon"] isEqual:@"magnifyingglass"] &&
                  ![[results valueForKey:@"type"] containsObject:@"tab"],
              "partial titles do not suggest saved tabs");
        results = LTCommandResults(@"Prsnlnm", p, @[], [NSSet setWithObject:a.identifier]);
        CHECK(![[results valueForKey:@"type"] containsObject:@"tab"],
              "fuzzy titles do not suggest saved tabs");
        results = LTCommandResults(@"personal name", p, @[], [NSSet setWithObject:a.identifier]);
        CHECK([results.firstObject[@"icon"] isEqual:@"magnifyingglass"],
              "title matching is case sensitive");
        results = LTCommandResults([@"  " stringByAppendingFormat:@"%@  ", a.url], p, @[],
                                   [NSSet setWithObject:a.identifier]);
        CHECK([results.firstObject[@"detail"] isEqual:@"Open address"] &&
                  [results.firstObject[@"value"] isEqual:a.url],
              "typed link opens directly even when it matches a saved tab");
        NSArray *history = @[ @{@"title" : @"Saved Page", @"url" : @"https://saved.example/Path"} ];
        results = LTCommandResults(@"Saved", p, history, [NSSet new]);
        CHECK([results.firstObject[@"icon"] isEqual:@"magnifyingglass"] &&
                  ![[results valueForKey:@"icon"] containsObject:@"clock"],
              "partial history matches are omitted");
        results = LTCommandResults(@"Saved Page", p, history, [NSSet new]);
        CHECK([results.firstObject[@"value"] isEqual:@"https://saved.example/Path"],
              "exact history title wins");
        results = LTCommandResults(@"https://saved.example/Path", p, history, [NSSet new]);
        CHECK([results.firstObject[@"detail"] isEqual:@"Open address"] &&
                  [results.firstObject[@"value"] isEqual:@"https://saved.example/Path"],
              "typed link opens directly even when it matches history");
        results = LTCommandResults(@"https://saved.example/path", p, history, [NSSet new]);
        CHECK([results.firstObject[@"value"] isEqual:@"https://saved.example/path"] &&
                  ![[results valueForKey:@"icon"] containsObject:@"clock"],
              "typed URL path case is preserved without suggesting a different history URL");
        CHECK([LTSearchURL(@"example.com?a=1&b=2", @"Google")
                  hasPrefix:@"https://www.google.com/search?q=example.com?a%3D1%26b%3D2"],
              "search provider receives the literal query even for URL-like input");
        [store recordVisit:@"https://old.example/exact" title:@"Exact History"];
        for (int i = 0; i < 35; i++)
            [store recordVisit:[NSString stringWithFormat:@"https://recent.example/%d", i]
                         title:[NSString stringWithFormat:@"Exact History extended %d", i]];
        NSArray *exactHistory = [store history:@"Exact History" limit:30 exact:YES];
        CHECK(exactHistory.count == 1 &&
                  [exactHistory.firstObject[@"url"] isEqual:@"https://old.example/exact"],
              "older exact history match survives newer partial matches and result limit");
        LTImportResult *import = [LTImporter parseArcData:JSON(Fixture()) error:&e];
        CHECK(import != nil, "import one space fixture");
        CHECK(import.profile.nodes.count == 6,
              "import folder, nested folder, pins and favorite counts");
        CHECK([import.profile.spaces.firstObject.name isEqual:@"School 📚"], "Unicode Space names");
        NSArray<LTNode *> *roots = [import.profile children:@""
                                                      space:import.profile.activeSpaceID
                                                       kind:nil];
        CHECK([roots.firstObject.title isEqual:@"Physics"] &&
                  [roots.lastObject.title isEqual:@"Dictionary"],
              "preserve pinned and folder order");
        NSMutableDictionary *bad = [Fixture() mutableCopy];
        NSMutableArray *items = [bad[@"items"] mutableCopy];
        [items addObject:items.firstObject];
        bad[@"items"] = items;
        CHECK([LTImporter parseArcData:JSON(bad) error:&e] == nil, "reject duplicate import IDs");
        bad = [Fixture() mutableCopy];
        items = [bad[@"items"] mutableCopy];
        [items removeObjectAtIndex:3];
        bad[@"items"] = items;
        CHECK([LTImporter parseArcData:JSON(bad) error:&e] == nil,
              "reject missing reference without partial import");
        CHECK([LTImporter parseArcData:[@"{broken" dataUsingEncoding:NSUTF8StringEncoding]
                                 error:&e] == nil,
              "reject malformed JSON");
        CHECK([LTImporter parseArcData:JSON(
                                           @{@"spaces" : @[],
                                             @"items" : @[]})
                                 error:&e] != nil,
              "empty Arc profile");
        NSMutableArray *pairedItems = [NSMutableArray new];
        for (NSDictionary *item in Fixture()[@"items"]) {
            [pairedItems addObject:item[@"id"]];
            [pairedItems addObject:item];
        }
        NSDictionary *current = @{
            @"sidebar" : @{
                @"containers" : @[
                    @{@"global" : @{}},
                    @{
                        @"spaces" : @[
                            @"school", @{
                                @"id" : @"school",
                                @"title" : @"School",
                                @"newContainerIDs" : @[
                                    @{@"unpinned" : @{}}, @"ignored",
                                    @{@"pinned" : @{}}, @"root"
                                ]
                            }
                        ],
                        @"items" : pairedItems,
                        @"topAppsContainerIDs" : @[ @{@"default" : @YES}, @"favs" ]
                    }
                ]
            }
        };
        CHECK([LTImporter parseArcData:JSON(current) error:&e].profile.nodes.count == 6,
              "current Swift Codable array schema");
        NSMutableDictionary *map = [NSMutableDictionary new];
        for (NSDictionary *item in Fixture()[@"items"])
            map[item[@"id"]] = @{@"value" : item};
        NSDictionary *sync = @{
            @"sidebarSyncState" : @{
                @"spaceModels" : @{@"school" : @{@"value" : Fixture()[@"spaces"][0]}},
                @"items" : map,
                @"container" : @{
                    @"value" :
                        @{@"topAppsContainerID" : @"favs", @"orderedSpaceIDs" : @[ @"school" ]}
                }
            }
        };
        CHECK([LTImporter parseArcData:JSON(sync) error:&e].profile.nodes.count == 6,
              "sync dictionary schema");
        NSDictionary *multi = @{@"containers" : @[ Fixture(), Fixture() ]};
        CHECK([LTImporter parseArcData:JSON(multi) error:&e].profile.spaces.count == 2,
              "multiple containers and same source IDs");
        NSMutableArray *many = [NSMutableArray new], *children = [NSMutableArray new];
        for (int i = 0; i < 2000; i++) {
            NSString *key = [NSString stringWithFormat:@"tab%d", i];
            [many addObject:Tab(key, key)];
            [children addObject:key];
        }
        [many addObject:@{
            @"id" : @"root",
            @"data" : @{@"itemContainer" : @{}},
            @"childrenIds" : children
        }];
        double start = NSDate.date.timeIntervalSince1970;
        CHECK([LTImporter parseArcData:JSON(@{@"spaces" : Fixture()[@"spaces"], @"items" : many})
                                 error:&e]
                      .profile.nodes.count == 2000,
              "large profile with 2000 pins");
        printf("Large import: %.1f ms\n", (NSDate.date.timeIntervalSince1970 - start) * 1000);
        NSString *html = @"<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><DT><H3>School</H3><DL><DT><A "
                         @"HREF=\"https://example.org/?a=1&amp;b=2\">A &amp; B</A></DL></DL>";
        LTImportResult *bookmarks =
            [LTImporter parseBookmarks:[html dataUsingEncoding:NSUTF8StringEncoding]
                                format:@"html"
                                 error:&e];
        CHECK(bookmarks.profile.nodes.count == 3 &&
                  [bookmarks.profile.nodes.lastObject.title isEqual:@"A & B"],
              "HTML bookmarks preserve folders and entities");
        CHECK(LTPolicy(@"Efficient", 150, NO, NO) == LTLifecycleFreeze, "background freeze");
        CHECK(LTPolicy(@"Efficient", 601, NO, NO) == LTLifecycleDiscard,
              "discard inactive renderer");
        CHECK(LTPolicy(@"Maximum Saving", 999, YES, YES) == LTLifecycleKeep,
              "media/forms/visible tabs protected under pressure");
        CHECK(LTPolicy(@"Balanced", 1, NO, YES) == LTLifecycleDiscard,
              "memory pressure reclamation");
        if (argc > 1) {
            NSString *dir = @(argv[1]);
            for (NSString *name in @[ @"simple.json", @"codable.json", @"sync.json" ]) {
                NSData *fixture =
                    [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]];
                CHECK([LTImporter parseArcData:fixture error:&e].profile.nodes.count == 6,
                      "stored sanitized fixture regression");
            }
        }
        if (argc > 2 && [@(argv[2]) isEqual:@"--check-arc"]) {
            for (NSURL *u in [LTImporter discoverArcFiles]) {
                NSData *data = [NSData dataWithContentsOfURL:u];
                LTImportResult *r = [LTImporter parseArcData:data error:&e];
                printf("Local read-only schema check: %s\n",
                       r ? r.summary.UTF8String : e.localizedDescription.UTF8String);
            }
        }
        NSDictionary *shiftedShortcut = LTNormalizeShortcut(@"T", NSEventModifierFlagCommand);
        CHECK([shiftedShortcut isEqual:LTNormalizeShortcut(@"t", NSEventModifierFlagCommand | NSEventModifierFlagShift)], "shortcut case normalization detects equivalent bindings");
        CHECK([LTNormalizeShortcut(@"{", NSEventModifierFlagCommand) isEqual:LTNormalizeShortcut(@"[", NSEventModifierFlagCommand | NSEventModifierFlagShift)], "shifted punctuation does not evade shortcut conflicts");
        CHECK(LTValidShortcut(shiftedShortcut) && LTValidShortcut(LTNormalizeShortcut(@"", 0)), "valid shortcut and explicit unbinding");
        CHECK(!LTValidShortcut(LTNormalizeShortcut(@"x", 0)) && !LTValidShortcut(@{@"key": @"two", @"modifiers": @(NSEventModifierFlagCommand)}), "plain typing and multi-key shortcuts rejected");
        CHECK(!LTValidShortcut(@{@"key": @"q"}) && !LTValidShortcut((id)@"invalid"), "malformed shortcut preferences rejected");
        CHECK(LTValidShortcut(LTNormalizeShortcut(@"\t", NSEventModifierFlagControl)) && LTValidShortcut(LTNormalizeShortcut(@"\r", NSEventModifierFlagCommand)), "modified Tab and Return are supported shortcuts");
        LTProfile *githubProfile = LTProfile.fresh;
        LTNode *githubFolder = [githubProfile addNode:@"folder" title:@"GitHub" url:@"" space:githubProfile.activeSpaceID parent:@""];
        NSDictionary *config = @{@"username": @"octocat", @"repository": @"cli/cli", @"mode": @"authored", @"draft": @"ready"};
        CHECK([LTGitHubQuery(config, &e) isEqual:@"is:pr is:open author:octocat repo:cli/cli draft:false"], "GitHub filters produce a scoped open PR query");
        CHECK(!LTGitHubQuery(@{@"username": @"octocat is:closed", @"repository": @"", @"mode": @"authored", @"draft": @"all"}, &e), "GitHub username cannot inject search qualifiers");
        CHECK(!LTGitHubQuery(@{@"username": @"", @"repository": @"", @"mode": @"repository", @"draft": @"all"}, &e) && !LTGitHubQuery(@{}, &e), "GitHub repository mode requires a valid repository");
        CHECK([LTGitHubQuery(@{@"username": @"octocat", @"repository": @"", @"mode": @"review", @"draft": @"draft"}, &e) containsString:@"review-requested:octocat draft:true"] && [LTGitHubQuery(@{@"username": @"octocat", @"repository": @"", @"mode": @"assigned", @"draft": @"all"}, &e) hasSuffix:@"assignee:octocat"], "GitHub review, assignee and draft filters");
        NSDictionary *pr = @{@"html_url": @"https://github.com/cli/cli/pull/123", @"title": @"Fix browser", @"pull_request": @{}};
        NSDictionary *response = @{@"items": @[pr], @"total_count": @1, @"incomplete_results": @NO};
        NSArray *pulls = LTGitHubPullRequests(response, &e);
        CHECK(pulls.count == 1 && [pulls[0][@"title"] containsString:@"#123"], "GitHub response parses real pull request fields");
        CHECK(!LTGitHubPullRequests(@{@"items": @[pr], @"total_count": @1, @"incomplete_results": @YES}, &e), "incomplete GitHub searches cannot replace folder contents");
        CHECK(!LTGitHubPullRequests(@{@"items": @[pr], @"total_count": @1001, @"incomplete_results": @NO}, &e), "GitHub search cap requires narrower filters");
        CHECK(!LTGitHubPullRequests(@{@"items": @[@{@"html_url": @"https://evil.invalid/", @"title": @"Wrong", @"pull_request": @{}}], @"total_count": @1, @"incomplete_results": @NO}, &e), "GitHub response rejects non-GitHub URLs");
        githubProfile.settings[@"githubLiveFolders"] = @{githubFolder.identifier: config};
        LTApplyGitHubPullRequests(githubProfile, githubFolder.identifier, pulls, [NSSet set]);
        LTNode *managed = [githubProfile children:githubFolder.identifier space:githubProfile.activeSpaceID kind:nil].firstObject;
        NSString *managedID = managed.identifier;
        managed.customTitle = @"Keep my title";
        managed.url = @"https://github.com/cli/cli/issues";
        LTApplyGitHubPullRequests(githubProfile, githubFolder.identifier, pulls, [NSSet setWithObject:managedID]);
        CHECK([githubProfile children:githubFolder.identifier space:githubProfile.activeSpaceID kind:nil].count == 1 && [[githubProfile node:managedID].customTitle isEqual:@"Keep my title"] && [[githubProfile node:managedID].url hasSuffix:@"/issues"], "GitHub refresh preserves tab identity, custom titles and current navigation");
        LTNode *ordinary = [githubProfile addNode:@"pinned" title:@"Personal bookmark" url:@"https://example.org/" space:githubProfile.activeSpaceID parent:githubFolder.identifier];
        LTApplyGitHubPullRequests(githubProfile, githubFolder.identifier, @[], [NSSet setWithObject:managedID]);
        CHECK([[githubProfile node:managedID].kind isEqual:@"temporary"] && ![githubProfile node:managedID].parentID.length && [githubProfile node:ordinary.identifier], "closed PR retains its open tab and leaves ordinary bookmarks untouched");
        LTApplyGitHubPullRequests(githubProfile, githubFolder.identifier, pulls, [NSSet set]);
        NSString *newID = githubProfile.settings[@"githubLiveFolders"][githubFolder.identifier][@"items"][pr[@"html_url"]];
        LTApplyGitHubPullRequests(githubProfile, githubFolder.identifier, @[], [NSSet set]);
        CHECK(![githubProfile node:newID] && [githubProfile validate:&e], "closed unopened PR removed without invalidating the profile");
        [githubProfile removeNode:githubFolder.identifier];
        CHECK([githubProfile.settings[@"githubLiveFolders"] count] == 0, "deleting a Live Folder removes its refresh configuration");
        printf("\n%d passed, %d failed\n", passed, failed);
        return failed ? 1 : 0;
    }
}
