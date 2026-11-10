// Data export: the bookmarks file other browsers import, the Lite organization file, reading the
// organization file back, and what each one leaves out.
#import "../migration/LTExporter.h"
#import "../migration/LTImporter.h"
static int passed, failed;
#define CHECK(condition, name) do { if (condition) { passed++; printf("PASS %s\n", name); } else { failed++; fprintf(stderr, "FAIL %s (line %d)\n", name, __LINE__); } } while (0)

static NSData *JSON(id object) { return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil]; }
static NSString *Text(NSData *data) { return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]; }
static NSDictionary *Organization(NSArray *spaces, NSArray *favorites) {
    return @{@"format" : LTOrganizationFormat, @"version" : @1, @"spaces" : spaces, @"favorites" : favorites};
}
static LTImportResult *Read(id file, NSError **error) {
    return [LTImporter parseOrganization:JSON(file) error:error];
}
static void Tree(LTProfile *p, NSDictionary *children, NSString *parent, NSMutableString *out) {
    for (LTNode *n in children[parent]) {
        if ([n.kind isEqual:@"folder"]) {
            [out appendFormat:@"[%@ %@ ", n.title, n.expanded ? @"open" : @"closed"];
            Tree(p, children, n.identifier, out);
            [out appendString:@"]"];
        } else if ([n.kind isEqual:@"pinned"])
            [out appendFormat:@"(%@|%@|%@) ", n.title, n.customTitle, n.pinnedURL.length ? n.pinnedURL : n.url];
    }
}
// Everything the organization file is meant to carry, independent of identifiers.
static NSString *Shape(LTProfile *p) {
    NSMutableString *out = [NSMutableString new];
    NSDictionary *themes = p.settings[@"spaceThemes"];
    for (LTSpace *s in p.spaces) {
        [out appendFormat:@"{%@ %@ ", s.name, themes[s.identifier] ?: @"auto"];
        Tree(p, [p childrenInSpace:s.identifier], @"", out);
        [out appendString:@"}"];
    }
    for (LTNode *n in [p children:@"" space:@"" kind:@"favorite"])
        [out appendFormat:@"<%@|%@|%@>", n.title, n.customTitle, n.pinnedURL.length ? n.pinnedURL : n.url];
    return out;
}
static NSUInteger Count(LTProfile *p, NSString *kind) {
    NSUInteger count = 0;
    for (LTNode *n in p.nodes) count += [n.kind isEqual:kind];
    return count;
}
static BOOL HasKey(id value, NSSet *keys) {
    if ([value isKindOfClass:NSDictionary.class]) {
        for (NSString *key in value)
            if ([keys containsObject:key] || HasKey(value[key], keys)) return YES;
    } else if ([value isKindOfClass:NSArray.class])
        for (id item in value) if (HasKey(item, keys)) return YES;
    return NO;
}

// Two Spaces, one with a chosen color; nested folders, one closed; a renamed tab; a pinned tab that
// has navigated away; a temporary tab; Favorites; and text that needs escaping.
static LTProfile *Sample(void) {
    LTProfile *p = LTProfile.fresh;
    NSString *personal = p.activeSpaceID;
    LTSpace *work = [p addSpace:@"Work & \"Play\" 🚀"];
    p.settings[@"spaceThemes"] = @{work.identifier : @"Graphite"};
    LTNode *folder = [p addNode:@"folder" title:@"Reading <list>" url:@"" space:personal parent:@""];
    LTNode *nested = [p addNode:@"folder" title:@"实验" url:@"" space:personal parent:folder.identifier];
    nested.expanded = NO;
    [p addNode:@"pinned" title:@"Data" url:@"https://example.org/data?a=1&b='2'" space:personal parent:nested.identifier];
    LTNode *renamed = [p addNode:@"pinned" title:@"Example Domain" url:@"https://example.com/" space:personal parent:folder.identifier];
    renamed.customTitle = @"My example";
    LTNode *moved = [p addNode:@"pinned" title:@"Docs" url:@"https://docs.example.net/start" space:personal parent:@""];
    moved.url = @"https://docs.example.net/elsewhere";
    [p addNode:@"temporary" title:@"Open page" url:@"https://temporary.example/" space:personal parent:@""];
    [p addNode:@"folder" title:@"Empty" url:@"" space:work.identifier parent:@""];
    [p addNode:@"pinned" title:@"Mail" url:@"https://mail.example.com/" space:work.identifier parent:@""];
    LTNode *second = [p addNode:@"favorite" title:@"Second" url:@"https://two.example/" space:@"" parent:@""];
    LTNode *first = [p addNode:@"favorite" title:@"First" url:@"https://one.example/" space:@"" parent:@""];
    first.order = 0; second.order = 1;
    first.customTitle = @"Uno";
    return p;
}

int main(void) {
    @autoreleasepool {
        NSError *e = nil;
        LTProfile *source = Sample();
        CHECK([source validate:&e], "sample profile validates");

        // Bookmarks file.
        NSString *html = Text([LTExporter bookmarksHTML:source]);
        CHECK([html hasPrefix:@"<!DOCTYPE NETSCAPE-Bookmark-file-1>"] && [html containsString:@"charset=UTF-8"],
              "bookmarks file has the Netscape header");
        CHECK([html containsString:@"<H3 PERSONAL_TOOLBAR_FOLDER=\"true\">Favorites</H3>"],
              "Favorites become the bookmarks bar folder");
        CHECK([html rangeOfString:@"Uno"].location < [html rangeOfString:@">Second<"].location,
              "Favorites keep their order under their shown names");
        CHECK([html containsString:@"<H3>Work &amp; &quot;Play&quot; 🚀</H3>"] &&
                  [html containsString:@"<H3>Reading &lt;list&gt;</H3>"] &&
                  [html containsString:@"HREF=\"https://example.org/data?a=1&amp;b=&#39;2&#39;\""],
              "names and addresses are escaped");
        CHECK([html containsString:@">My example</A>"] && ![html containsString:@">Example Domain</A>"],
              "a renamed tab is written under its Lite name");
        CHECK([html containsString:@"https://docs.example.net/start"] && ![html containsString:@"elsewhere"],
              "a pinned tab is written with its pinned address");
        CHECK(![html containsString:@"temporary.example"], "temporary tabs are left out of bookmarks");
        CHECK([html containsString:@"<H3>Empty</H3>"], "empty folders are kept");

        LTImportResult *back = [LTImporter parseBookmarks:[LTExporter bookmarksHTML:source] format:@"html" error:&e];
        LTProfile *bp = back.profile;
        NSMutableArray *topFolders = [NSMutableArray new];
        LTNode *root = [bp children:@"" space:bp.activeSpaceID kind:@"folder"].firstObject;
        for (LTNode *n in [bp children:root.identifier space:bp.activeSpaceID kind:@"folder"]) [topFolders addObject:n.title];
        CHECK([topFolders isEqual:(@[ @"Favorites", @"Personal", @"Work & \"Play\" 🚀" ])],
              "Lite reads its own bookmarks file back as Favorites and a folder per Space");
        CHECK(Count(bp, @"pinned") == Count(source, @"pinned") + Count(source, @"favorite"),
              "every saved tab survives a bookmarks round trip");
        BOOL decoded = NO;
        for (LTNode *n in bp.nodes) decoded |= [n.url isEqual:@"https://example.org/data?a=1&b='2'"];
        CHECK(decoded, "escaped addresses read back exactly");

        LTProfile *plain = LTProfile.fresh;
        [plain addNode:@"pinned" title:@"Only" url:@"https://only.example/" space:plain.activeSpaceID parent:@""];
        CHECK(![Text([LTExporter bookmarksHTML:plain]) containsString:@"Favorites"],
              "no Favorites folder is written when there are none");

        // Organization file.
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:1794268800];
        NSData *organization = [LTExporter organizationJSON:source date:date];
        NSDictionary *file = [NSJSONSerialization JSONObjectWithData:organization options:0 error:nil];
        CHECK([file[@"format"] isEqual:@"lite-organization"] && [file[@"version"] isEqual:@1] &&
                  [file[@"exported"] isEqual:@"2026-11-10T00:00:00Z"],
              "organization file names its format, version and date");
        CHECK(!HasKey(file, [NSSet setWithArray:@[ @"id", @"lastUsed", @"favicon", @"selected", @"windows", @"closed" ]]),
              "organization file carries no identifiers, history, favicons or window state");
        CHECK(![Text(organization) containsString:@"temporary.example"], "temporary tabs are left out of the organization file");
        CHECK([Text(organization) isEqual:Text([LTExporter organizationJSON:source date:date])],
              "the same sidebar always writes the same file");

        LTImportResult *imported = [LTImporter parseBookmarks:organization format:@"json" error:&e];
        CHECK(imported && imported.warnings.count == 0, "Import Bookmarks recognizes an organization file");
        LTProfile *copy = LTProfile.fresh;
        [copy.spaces removeAllObjects];
        copy.activeSpaceID = @"";
        [LTImporter merge:imported into:copy];
        CHECK([Shape(copy) isEqual:Shape(source)] && [copy validate:&e],
              "an organization round trip keeps Spaces, colors, folders, open state, names and Favorites");
        NSMutableSet *sourceIDs = [NSMutableSet new];
        for (LTNode *n in source.nodes) [sourceIDs addObject:n.identifier];
        for (LTSpace *s in source.spaces) [sourceIDs addObject:s.identifier];
        BOOL fresh = YES;
        for (LTNode *n in imported.profile.nodes) fresh &= ![sourceIDs containsObject:n.identifier];
        for (LTSpace *s in imported.profile.spaces) fresh &= ![sourceIDs containsObject:s.identifier];
        CHECK(fresh, "imported items get new identifiers");
        CHECK([imported.summary isEqual:@"2 Spaces · 3 folders · 4 pinned tabs · 2 Favorites"],
              "the import preview counts what the file holds");

        // Merging into a profile that already has things.
        LTProfile *existing = Sample();
        NSString *existingSpace = existing.spaces.lastObject.identifier;
        NSUInteger spacesBefore = existing.spaces.count;
        [LTImporter merge:[LTImporter parseOrganization:organization error:nil] into:existing];
        NSArray *favoriteOrders = [[existing children:@"" space:@"" kind:@"favorite"] valueForKey:@"order"];
        CHECK(existing.spaces.count == spacesBefore + 2 && [existing validate:&e] &&
                  [existing.settings[@"spaceThemes"][existingSpace] isEqual:@"Graphite"] &&
                  [existing.settings[@"spaceThemes"] count] == 2 &&
                  [favoriteOrders isEqual:(@[ @0, @1, @2, @3 ])],
              "merging adds Spaces and Favorites and keeps existing colors");
        LTProfile *reloaded = [LTProfile fromJSON:[NSJSONSerialization JSONObjectWithData:JSON(existing.JSON) options:0 error:nil] error:&e];
        CHECK(reloaded && [Shape(reloaded) isEqual:Shape(existing)], "a merged profile saves and loads");

        // Files Lite did not write, or did not write this way.
        NSDictionary *tab = @{@"type" : @"tab", @"title" : @"T", @"url" : @"https://ok.example/"};
        NSDictionary *one = @{@"name" : @"S", @"items" : @[ tab ]};
        CHECK(Read(Organization(@[ one ], @[]), &e) != nil, "a minimal organization file imports");
        e = nil;
        CHECK(!Read(@{@"version" : @1, @"spaces" : @[ one ]}, &e) && [e.localizedDescription containsString:@"not a Lite organization file"],
              "a file without the format marker is refused");
        NSMutableDictionary *newer = [Organization(@[ one ], @[]) mutableCopy];
        newer[@"version"] = @2;
        e = nil;
        CHECK(!Read(newer, &e) && [e.localizedDescription containsString:@"newer version of Lite"],
              "a file from a newer Lite asks for an update");
        newer[@"version"] = @YES;
        CHECK(!Read(newer, nil), "a boolean version is refused");
        CHECK(!Read(Organization(@[], @[]), nil), "a file with no Spaces is refused");
        CHECK(!Read(Organization(@[ @{@"name" : @"S", @"items" : @[ @{@"type" : @"window"} ]} ], @[]), &e) &&
                  [e.localizedDescription containsString:@"Nothing was imported"],
              "an unknown item type imports nothing");
        CHECK(!Read(Organization(@[ @{@"name" : @"S", @"items" : @[ @{@"type" : @"folder", @"open" : @"yes"} ]} ], @[]), nil),
              "a folder whose open state is not a boolean is refused");
        CHECK(!Read(Organization(@[ @{@"name" : @7} ], @[]), nil), "a Space name that is not text is refused");
        CHECK(!Read(Organization(@[ one ], @[ @"https://x.example/" ]), nil), "a Favorite that is not an object is refused");
        CHECK(!Read(Organization(@[ one ], @[ @{@"title" : @"no address"} ]), nil), "a Favorite without an address is refused");
        CHECK(!Read(Organization(@[ @{@"name" : @"S", @"theme" : [@"" stringByPaddingToLength:65 withString:@"x" startingAtIndex:0]} ], @[]), nil),
              "an overlong color name is refused");

        LTImportResult *skipped = Read(Organization(@[ @{@"name" : @"S", @"items" : @[
            tab, @{@"type" : @"tab", @"url" : @"javascript:alert(1)"}, @{@"type" : @"tab", @"url" : @"file:///etc/passwd"}
        ]} ], @[ @{@"url" : @"https://user:pw@x.example/"} ]), nil);
        CHECK(skipped && Count(skipped.profile, @"pinned") == 1 && Count(skipped.profile, @"favorite") == 0 &&
                  [skipped.warnings.firstObject containsString:@"3 tabs"],
              "addresses Lite cannot open are skipped with a warning");
        LTImportResult *untitled = Read(Organization(@[ @{@"items" : @[ @{@"type" : @"tab", @"url" : @"https://host.example/x"}, @{@"type" : @"folder"} ]} ], @[]), nil);
        LTNode *untitledTab = [untitled.profile children:@"" space:untitled.profile.activeSpaceID kind:@"pinned"].firstObject;
        CHECK([untitled.profile.spaces.firstObject.name isEqual:@"Imported Space"] && [untitledTab.title isEqual:@"host.example"] &&
                  [[untitled.profile children:@"" space:untitled.profile.activeSpaceID kind:@"folder"].firstObject.title isEqual:@"Imported Folder"],
              "missing names are filled in");

        NSMutableArray *deep = [NSMutableArray arrayWithObject:tab];
        for (int i = 0; i < 64; i++) deep = [NSMutableArray arrayWithObject:@{@"type" : @"folder", @"items" : deep}];
        CHECK(Read(Organization(@[ @{@"name" : @"S", @"items" : deep[0][@"items"]} ], @[]), nil) != nil, "folders 64 deep import");
        e = nil;
        CHECK(!Read(Organization(@[ @{@"name" : @"S", @"items" : deep} ], @[]), &e) && [e.localizedDescription containsString:@"64 deep"],
              "folders nested deeper than 64 are refused");
        NSMutableArray *many = [NSMutableArray new];
        for (int i = 0; i <= 100000; i++) [many addObject:tab];
        e = nil;
        CHECK(!Read(Organization(@[ @{@"name" : @"S", @"items" : many} ], @[]), &e) && [e.localizedDescription containsString:@"100,000"],
              "more than 100,000 items are refused");

        CHECK([LTImporter parseBookmarks:JSON(@{@"roots" : @{@"bookmark_bar" : @{@"children" : @[ @{@"name" : @"C", @"url" : @"https://c.example/"} ]}}})
                                  format:@"json" error:nil] != nil,
              "Chromium Bookmarks files still import");
        e = nil;
        CHECK(![LTImporter parseBookmarks:JSON(@[ @1 ]) format:@"json" error:&e] && e,
              "a JSON file that is not an object is refused without crashing");

        // A large sidebar: 10,000 saved tabs in 500 folders across 10 Spaces.
        LTProfile *large = LTProfile.fresh;
        for (int s = 0; s < 10; s++) {
            NSString *space = s ? [large addSpace:[NSString stringWithFormat:@"Space %d", s]].identifier : large.activeSpaceID;
            for (int f = 0; f < 50; f++) {
                LTNode *folder = [large addNode:@"folder" title:@"F" url:@"" space:space parent:@""];
                for (int t = 0; t < 20; t++) {
                    LTNode *n = [LTNode new];
                    n.kind = @"pinned"; n.spaceID = space; n.parentID = folder.identifier; n.order = t;
                    n.title = @"Tab"; n.url = n.pinnedURL = [NSString stringWithFormat:@"https://example.org/%d/%d/%d", s, f, t];
                    [large.nodes addObject:n];
                }
            }
        }
        [large seal];
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        NSData *largeHTML = [LTExporter bookmarksHTML:large];
        NSData *largeJSON = [LTExporter organizationJSON:large date:date];
        double exportMs = (CFAbsoluteTimeGetCurrent() - start) * 1000;
        start = CFAbsoluteTimeGetCurrent();
        LTImportResult *largeBack = [LTImporter parseOrganization:largeJSON error:nil];
        double importMs = (CFAbsoluteTimeGetCurrent() - start) * 1000;
        printf("10,000 tabs: both exports %.1f ms (%lu + %lu bytes), organization import %.1f ms\n", exportMs,
               (unsigned long)largeHTML.length, (unsigned long)largeJSON.length, importMs);
        CHECK(Count(largeBack.profile, @"pinned") == 10000 && Count(largeBack.profile, @"folder") == 500,
              "a 10,000-tab organization file reads back whole");
        CHECK(exportMs < 2000 && importMs < 2000, "a 10,000-tab sidebar exports and imports in under 2 seconds");

        printf("%d passed, %d failed\n", passed, failed);
        return failed ? 1 : 0;
    }
}
