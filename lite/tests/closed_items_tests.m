// Recently closed tabs and windows: what the profile records, its limit, reopening, persistence
// across launches, and removal when history is deleted, including from recovery backups.
#import "../model/LTStore.h"
#import <sqlite3.h>
static int passed, failed;
#define CHECK(condition, name) do { if (condition) { passed++; printf("PASS %s\n", name); } else { failed++; fprintf(stderr, "FAIL %s (line %d)\n", name, __LINE__); } } while (0)

static NSString *NewPath(NSString *root) {
    NSString *directory = [root stringByAppendingPathComponent:LTUUID()];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return [directory stringByAppendingPathComponent:@"Lite.sqlite"];
}
static LTStore *OpenStore(NSString *path) {
    NSError *error = nil;
    LTStore *store = [[LTStore alloc] initWithPath:path error:&error];
    if (!store) { NSLog(@"store: %@", error); exit(2); }
    [store waitForWrites];
    return store;
}
static LTNode *Tab(LTProfile *profile, NSString *url) {
    return [profile addNode:@"temporary" title:url url:url space:profile.activeSpaceID parent:@""];
}
static NSDictionary *WindowState(LTProfile *profile, NSDictionary *sessions) {
    return @{@"space" : profile.activeSpaceID, @"active" : @"", @"secondary" : @"",
             @"frame" : NSStringFromRect(NSMakeRect(10, 20, 900, 700)), @"sessions" : sessions};
}
static NSDictionary *Session(NSString *url) { return @{@"url" : url, @"scrollX" : @0, @"scrollY" : @120}; }
static NSArray *ClosedURLs(LTProfile *profile) {
    NSMutableArray *urls = [NSMutableArray new];
    for (NSDictionary *entry in profile.closed)
        [urls addObject:[entry[@"type"] isEqual:@"tab"] ? entry[@"node"][@"url"] : @"window"];
    return urls;
}
// The profile JSON saved in a database file, or nil.
static NSString *SavedProfile(NSString *path) {
    sqlite3 *db = NULL;
    NSString *json = nil;
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
        sqlite3_stmt *s = NULL;
        if (sqlite3_prepare_v2(db, "SELECT json FROM profile WHERE id=1", -1, &s, NULL) == SQLITE_OK &&
            sqlite3_step(s) == SQLITE_ROW)
            json = [[NSString alloc] initWithBytes:sqlite3_column_blob(s, 0) length:sqlite3_column_bytes(s, 0)
                                          encoding:NSUTF8StringEncoding];
        sqlite3_finalize(s);
    }
    sqlite3_close(db);
    return json;
}

static void ModelTests(void) {
    LTProfile *profile = [LTProfile fresh];
    LTNode *tab = Tab(profile, @"https://example.com/a");
    [profile noteClosedTab:tab time:100];
    LTNode *pinned = [profile addNode:@"pinned" title:@"Pinned" url:@"https://example.com/p" space:profile.activeSpaceID parent:@""];
    [profile noteClosedTab:pinned time:101];
    LTNode *blank = [tab copy];
    blank.url = @"javascript:void(0)";
    [profile noteClosedTab:blank time:102];
    CHECK([ClosedURLs(profile) isEqual:@[@"https://example.com/a"]], "only temporary tabs with reopenable addresses are recorded");

    [profile noteClosedWindow:WindowState(profile, @{}) time:103];
    [profile noteClosedWindow:@{@"frame" : @"{{0, 0}, {0, 0}}"} time:104];
    CHECK(profile.closed.count == 2 && [[profile latestClosed:nil][@"type"] isEqual:@"window"], "a valid window state is recorded, an invalid one is not");
    CHECK([[profile latestClosed:@"tab"][@"node"][@"url"] isEqual:@"https://example.com/a"], "latest tab skips a newer window");

    tab.url = @"https://example.com/changed";
    CHECK([[profile latestClosed:@"tab"][@"node"][@"url"] isEqual:@"https://example.com/a"], "an entry keeps a copy, not the live node");

    NSString *identifier = [profile latestClosed:@"tab"][@"id"];
    CHECK([profile takeClosed:identifier] != nil && [profile takeClosed:identifier] == nil, "an entry can be taken only once");

    for (int i = 0; i < 40; i++) [profile noteClosedTab:Tab(profile, [NSString stringWithFormat:@"https://example.com/%d", i]) time:200 + i];
    CHECK(profile.closed.count == LTClosedLimit && [ClosedURLs(profile).firstObject isEqual:@"https://example.com/10"] &&
              [ClosedURLs(profile).lastObject isEqual:@"https://example.com/39"],
          "the list keeps the newest LTClosedLimit entries");

    NSError *error = nil;
    LTProfile *copy = [LTProfile fromJSON:profile.JSON error:&error];
    CHECK(copy && [copy.closed isEqual:profile.closed], "closed entries survive a JSON round trip");
    LTProfile *transaction = [profile transactionCopy];
    [transaction.closed removeAllObjects];
    CHECK(profile.closed.count == LTClosedLimit, "a transaction copy does not share the closed list");

    NSMutableDictionary *legacy = [profile.JSON mutableCopy];
    [legacy removeObjectForKey:@"closed"];
    LTProfile *old = [LTProfile fromJSON:legacy error:&error];
    CHECK(old && old.closed.count == 0, "a profile saved before this change loads with an empty list");

    NSDictionary *validTab = profile.closed.lastObject;
    NSMutableDictionary *pinnedNode = [validTab[@"node"] mutableCopy];
    pinnedNode[@"kind"] = @"pinned";
    NSMutableDictionary *badURL = [validTab[@"node"] mutableCopy];
    badURL[@"url"] = @"javascript:alert(1)";
    NSArray *invalid = @[
        @{@"id" : @"x", @"type" : @"tab", @"closed" : @1},
        @{@"id" : @"x", @"type" : @"group", @"closed" : @1, @"node" : validTab[@"node"]},
        @{@"id" : @"", @"type" : @"tab", @"closed" : @1, @"node" : validTab[@"node"]},
        @{@"id" : @"x", @"type" : @"tab", @"closed" : @"yesterday", @"node" : validTab[@"node"]},
        @{@"id" : @"x", @"type" : @"tab", @"closed" : @1, @"node" : pinnedNode},
        @{@"id" : @"x", @"type" : @"tab", @"closed" : @1, @"node" : badURL},
        @{@"id" : @"x", @"type" : @"window", @"closed" : @1, @"state" : @{@"frame" : @"{{0, 0}, {-1, 5}}"}},
    ];
    BOOL rejected = YES;
    for (NSDictionary *entry in invalid) {
        NSMutableDictionary *json = [profile.JSON mutableCopy];
        json[@"closed"] = @[entry];
        rejected &= [LTProfile fromJSON:json error:nil] == nil;
    }
    NSMutableDictionary *tooMany = [profile.JSON mutableCopy];
    tooMany[@"closed"] = [profile.closed arrayByAddingObject:validTab];
    rejected &= [LTProfile fromJSON:tooMany error:nil] == nil;
    CHECK(rejected, "malformed or oversized closed lists are rejected");
}

static void ForgetTests(void) {
    LTProfile *profile = [LTProfile fresh];
    [profile noteClosedTab:Tab(profile, @"https://old.example/") time:100];
    [profile noteClosedWindow:WindowState(profile, @{@"a" : Session(@"https://kept.example/"), @"b" : Session(@"https://gone.example/")}) time:150];
    [profile noteClosedTab:Tab(profile, @"https://gone.example/") time:200];
    [profile noteClosedTab:Tab(profile, @"https://new.example/") time:300];

    CHECK(([profile forgetClosedURL:@"https://gone.example/"] &&
           [ClosedURLs(profile) isEqual:@[@"https://old.example/", @"window", @"https://new.example/"]]),
          "deleting an address drops its closed tabs");
    NSDictionary *sessions = [profile latestClosed:@"window"][@"state"][@"sessions"];
    CHECK(sessions.count == 1 && [sessions[@"a"][@"url"] isEqual:@"https://kept.example/"],
          "deleting an address drops its scroll position from closed windows");
    CHECK(![profile forgetClosedURL:@"https://unknown.example/"], "an unknown address changes nothing");
    CHECK([profile forgetClosedSince:150] && [ClosedURLs(profile) isEqual:@[@"https://old.example/"]],
          "clearing recent history drops what closed in that period");
    CHECK(![profile forgetClosedSince:150], "clearing the same period again changes nothing");
    CHECK([profile forgetClosedSince:0] && profile.closed.count == 0, "clearing all history drops everything");
}

static void StoreTests(NSString *root) {
    NSString *path = NewPath(root);
    LTStore *store = OpenStore(path);
    NSError *error = nil;
    __block NSString *tabID = nil;
    CHECK([store commit:^(LTProfile *p) {
              LTNode *tab = Tab(p, @"https://persisted.example/");
              tabID = tab.identifier;
              [p noteClosedTab:tab time:1000];
              [p removeNode:tab.identifier];
              [p noteClosedWindow:WindowState(p, @{@"s" : Session(@"https://window.example/")}) time:1001];
          } error:&error],
          "closing a tab and a window saves");
    [store close];

    store = OpenStore(path);
    CHECK(([ClosedURLs(store.profile) isEqual:@[@"https://persisted.example/", @"window"]]),
          "recently closed tabs and windows survive quitting");

    NSString *entryID = [store.profile latestClosed:@"tab"][@"id"];
    __block NSString *reopened = nil;
    [store commit:^(LTProfile *p) {
        NSDictionary *taken = [p takeClosed:entryID];
        LTNode *n = [LTNode fromJSON:taken[@"node"]];
        [p.nodes addObject:n];
        reopened = n.identifier;
    } error:&error];
    CHECK([reopened isEqual:tabID] && [store.profile node:tabID] && ![store.profile latestClosed:@"tab"],
          "reopening restores the tab and removes it from the list");

    // Deletion runs as a history operation, not a profile change, but must still publish the profile.
    [store commit:^(LTProfile *p) {
        for (NSString *url in @[@"https://delete-one.example/", @"https://cleared.example/"]) {
            LTNode *tab = Tab(p, url);
            [p noteClosedTab:tab time:[url containsString:@"delete-one"] ? 2000 : NSDate.date.timeIntervalSince1970];
            [p removeNode:tab.identifier];
        }
    } error:&error];
    [store recordVisit:@"https://delete-one.example/" title:@"Delete one"];
    CHECK([store deleteHistoryURL:@"https://delete-one.example/" error:&error] &&
              ![ClosedURLs(store.profile) containsObject:@"https://delete-one.example/"] &&
              [ClosedURLs(store.profile) containsObject:@"https://cleared.example/"],
          "deleting a history address removes it from recently closed tabs");
    double hourAgo = NSDate.date.timeIntervalSince1970 - 3600;
    CHECK([store clearHistorySince:hourAgo error:&error] &&
              [ClosedURLs(store.profile) isEqual:@[@"window"]],
          "clearing the last hour removes tabs closed in it and keeps older entries");
    NSString *backup = SavedProfile([path stringByAppendingString:@".backup"]);
    CHECK(backup && ![backup containsString:@"cleared.example"] && ![backup containsString:@"delete-one.example"] &&
              [backup containsString:@"window.example"],
          "the recovery backup holds the list after deletion, not before");
    CHECK([store clearHistorySince:0 error:&error] && store.profile.closed.count == 0 &&
              ![SavedProfile(path) containsString:@"window.example"],
          "clearing all history empties the saved list");
    [store close];
    CHECK(OpenStore(path).profile.closed.count == 0, "a cleared list stays empty after relaunch");

    LTStore *privateStore = OpenStore(nil);
    [privateStore commit:^(LTProfile *p) { [p noteClosedTab:Tab(p, @"https://private.example/") time:1]; } error:&error];
    CHECK(privateStore.privateMode && [ClosedURLs(privateStore.profile) isEqual:@[@"https://private.example/"]] &&
              ![SavedProfile(path) containsString:@"private.example"],
          "a private window's list stays in its own in-memory store");
}

int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"lite-closed-" stringByAppendingString:LTUUID()]];
        ModelTests();
        ForgetTests();
        StoreTests(root);
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        printf("%d passed, %d failed\n", passed, failed);
        return failed ? 1 : 0;
    }
}
