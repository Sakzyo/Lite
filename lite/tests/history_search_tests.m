// History search: matching, frecency ranking, retention, the version 1 -> 2 migration, and the
// Command Bar's query time at the retention cap. `--measure` prints the timings as JSON instead.
#import "../model/LTCommandIndex.h"
#import "../model/LTStore.h"
#import <sqlite3.h>
#include <math.h>
static int passed, failed;
#define CHECK(condition, name) do { if (condition) { passed++; printf("PASS %s\n", name); } else { failed++; fprintf(stderr, "FAIL %s (line %d)\n", name, __LINE__); } } while (0)
static const double FrameBudgetMs = 1000.0 / 60;

static double Now(void) { return NSProcessInfo.processInfo.systemUptime; }
static NSString *NewPath(NSString *root) {
    return [[root stringByAppendingPathComponent:LTUUID()] stringByAppendingPathComponent:@"Lite.sqlite"];
}
static sqlite3 *Open(NSString *path) {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        fprintf(stderr, "open %s failed\n", path.UTF8String);
        exit(2);
    }
    sqlite3_busy_timeout(db, 3000);
    return db;
}
static void SQL(NSString *path, NSString *sql) {
    sqlite3 *db = Open(path);
    if (sqlite3_exec(db, sql.UTF8String, NULL, NULL, NULL) != SQLITE_OK) {
        fprintf(stderr, "SQL fixture failed: %s\n", sqlite3_errmsg(db));
        exit(2);
    }
    sqlite3_close(db);
}
static BOOL Run(NSString *path, NSString *sql) {
    sqlite3 *db = Open(path);
    BOOL ok = sqlite3_exec(db, sql.UTF8String, NULL, NULL, NULL) == SQLITE_OK;
    sqlite3_close(db);
    return ok;
}
static NSString *Text(NSString *path, NSString *sql) {
    sqlite3 *db = Open(path);
    sqlite3_stmt *stmt = NULL;
    NSString *value = nil;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW &&
        sqlite3_column_text(stmt, 0))
        value = @((const char *)sqlite3_column_text(stmt, 0));
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return value;
}
// The store's `words` for ASCII text, for rows a test writes directly: lowercase runs of letters and
// digits from the title, then the address, each after one space.
static NSString *Words(NSString *title, NSString *address) {
    NSMutableString *words = [NSMutableString new];
    NSCharacterSet *separators = NSCharacterSet.alphanumericCharacterSet.invertedSet;
    for (NSString *text in @[title, address])
        for (NSString *token in [text.lowercaseString componentsSeparatedByCharactersInSet:separators])
            if (token.length) [words appendFormat:@" %@", token];
    return words;
}
static NSArray<NSString *> *URLs(NSArray<NSDictionary *> *rows) { return [rows valueForKey:@"url"]; }
// Moves a URL's visits `days` into the past, exactly as if they had happened then.
static void Age(NSString *path, NSString *url, double days) {
    double seconds = days * 86400;
    SQL(path, [NSString stringWithFormat:@"UPDATE history SET visited=visited-%.17g, rank=rank-%.17g WHERE url='%@'",
                                         seconds, seconds * M_LN2 / LTHistoryHalfLife, url]);
}
static LTStore *OpenStore(NSString *path) {
    NSError *error = nil;
    LTStore *store = [[LTStore alloc] initWithPath:path error:&error];
    if (!store) { NSLog(@"store: %@", error); exit(2); }
    [store waitForWrites];
    return store;
}

static void MatchingTests(NSString *root) {
    NSString *path = NewPath(root);
    LTStore *store = OpenStore(path);
    [store recordVisit:@"https://github.com/anthropics" title:@"Anthropic · GitHub"];
    [store recordVisit:@"https://www.gitlab.com/explore" title:@"Explore projects"];
    [store recordVisit:@"https://developer.apple.com/documentation/swift" title:@"Swift Documentation"];
    [store recordVisit:@"https://news.example/story" title:@"Café opening hours"];
    [store recordVisit:@"https://example.org/github-mirror" title:@"Mirror"];
    [store waitForWrites];

    NSArray *rows = [store searchHistory:@"gith" limit:10];
    CHECK([URLs(rows).firstObject isEqual:@"https://github.com/anthropics"] &&
              [rows.firstObject[@"match"] isEqual:LTHistoryMatchAddress],
          "partial host text finds the host by address prefix");
    CHECK([URLs(rows) containsObject:@"https://example.org/github-mirror"] &&
              [rows.lastObject[@"match"] isEqual:LTHistoryMatchWord] && rows.count == 2,
          "a word that starts later in the URL is a word match below the address match");
    CHECK([URLs([store searchHistory:@"GITH" limit:10]).firstObject isEqual:@"https://github.com/anthropics"],
          "matching ignores case");
    for (NSString *typed in @[@"www.gith", @"https://gith", @"http://www.github.com/ant"])
        CHECK([[store searchHistory:typed limit:10].firstObject[@"match"] isEqual:LTHistoryMatchAddress],
              "a typed scheme or www. does not stop an address-prefix match");
    CHECK([URLs([store searchHistory:@"gitl" limit:10]) isEqual:@[@"https://www.gitlab.com/explore"]],
          "a stored www. does not stop an address-prefix match");
    rows = [store searchHistory:@"doc" limit:10];
    CHECK([URLs(rows) isEqual:@[@"https://developer.apple.com/documentation/swift"]] &&
              [rows.firstObject[@"match"] isEqual:LTHistoryMatchWord],
          "a word prefix in a title or path matches");
    CHECK([URLs([store searchHistory:@"swift doc" limit:10]) isEqual:@[@"https://developer.apple.com/documentation/swift"]] &&
              [store searchHistory:@"doc swift" limit:10].count == 1 && [store searchHistory:@"swift gith" limit:10].count == 0,
          "every typed word must start a word, in any order");
    CHECK([URLs([store searchHistory:@"cafe" limit:10]) isEqual:@[@"https://news.example/story"]],
          "full-text search ignores diacritics");
    CHECK([store searchHistory:@"thub" limit:10].count == 0, "text inside a word does not match");
    CHECK([store searchHistory:@"\"* OR NEAR(" limit:10].count == 0 && [store searchHistory:@"-" limit:10].count == 0,
          "FTS syntax in the query is treated as text");
    rows = [store searchHistory:@"Swift Documentation" limit:10];
    CHECK([rows.firstObject[@"match"] isEqual:LTHistoryMatchExact], "a whole title is an exact match");
    CHECK([store searchHistory:@"" limit:2].count == 2 && ![store searchHistory:@"" limit:2].firstObject[@"match"],
          "an empty query lists the most frecent rows");

    // An exact match survives any number of more frecent partial matches and the limit.
    [store recordVisit:@"https://old.example/exact" title:@"Exact History"];
    for (int i = 0; i < 35; i++)
        for (int visit = 0; visit < 2; visit++)
            [store recordVisit:[NSString stringWithFormat:@"https://recent.example/%d", i]
                         title:[NSString stringWithFormat:@"Exact History extended %d", i]];
    [store waitForWrites];
    rows = [store searchHistory:@"Exact History" limit:30];
    CHECK(rows.count == 30 && [rows.firstObject[@"url"] isEqual:@"https://old.example/exact"],
          "an older exact match leads newer, more visited partial matches");

    // A title change on an open page renames the visit without counting another one.
    [store recordVisit:@"https://mail.example/inbox" title:@"Inbox"];
    [store updateVisitTitle:@"Inbox (3) unread" url:@"https://mail.example/inbox"];
    [store updateVisitTitle:@"Never visited" url:@"https://unvisited.example/"];
    [store waitForWrites];
    rows = [store searchHistory:@"unread" limit:10];
    CHECK([URLs(rows) isEqual:@[@"https://mail.example/inbox"]] && [rows.firstObject[@"visits"] isEqual:@1] &&
              [rows.firstObject[@"title"] isEqual:@"Inbox (3) unread"],
          "a title update renames the visit and keeps its count");
    CHECK([store searchHistory:@"never" limit:10].count == 0, "a title update never creates a visit");

    // Deletion reaches the full-text index too.
    [store recordVisit:@"https://secret.example/" title:@"Surprise party plans"];
    [store waitForWrites];
    CHECK([store searchHistory:@"surprise" limit:10].count == 1, "a new title is searchable");
    NSError *error = nil;
    CHECK([store deleteHistoryURL:@"https://secret.example/" error:&error] &&
              [store searchHistory:@"surprise" limit:10].count == 0 && [store searchHistory:@"secr" limit:10].count == 0,
          "a deleted URL leaves the search results");
    CHECK([Text(path, @"SELECT count(*) FROM history_fts WHERE history_fts MATCH 'surprise'") isEqual:@"0"] &&
              [Text(path, @"PRAGMA integrity_check") isEqual:@"ok"] &&
              Run(path, @"INSERT INTO history_fts(history_fts) VALUES('integrity-check')"),
          "the full-text index stays in step with the table");
    CHECK([store clearHistorySince:0 error:&error] && [store searchHistory:@"" limit:10].count == 0 &&
              [store searchHistory:@"gith" limit:10].count == 0,
          "clearing history empties search");
    [store recordVisit:@"https://after.example/" title:@"After clearing"];
    [store waitForWrites];
    CHECK([store searchHistory:@"after" limit:10].count == 1 && [store deleteHistoryURL:@"https://after.example/" error:&error] &&
              [store searchHistory:@"after" limit:10].count == 0 &&
              Run(path, @"INSERT INTO history_fts(history_fts) VALUES('integrity-check')"),
          "after clearing everything the index still follows new visits and deletions");

    LTStore *privateStore = [[LTStore alloc] initWithPath:nil error:&error];
    [privateStore recordVisit:@"https://github.com/private" title:@"Private"];
    [privateStore updateVisitTitle:@"Private renamed" url:@"https://github.com/private"];
    [privateStore waitForWrites];
    CHECK([privateStore searchHistory:@"gith" limit:10].count == 0 && [privateStore searchHistory:@"" limit:10].count == 0 &&
              [privateStore history:@"" limit:10].count == 0,
          "private stores record and find nothing");
}

static void RankingTests(NSString *root) {
    NSString *path = NewPath(root);
    LTStore *store = OpenStore(path);
    for (int i = 0; i < 5; i++) [store recordVisit:@"https://alpha.example/" title:@"Alpha"];
    [store recordVisit:@"https://alphabet.example/" title:@"Alphabet"];
    [store waitForWrites];
    NSArray *rows = [store searchHistory:@"alp" limit:10];
    CHECK([URLs(rows) isEqual:(@[@"https://alpha.example/", @"https://alphabet.example/"])] &&
              [rows.firstObject[@"visits"] isEqual:@5] && [rows.lastObject[@"visits"] isEqual:@1],
          "more visits rank higher and each URL counts its visits");
    store = nil;
    // Three visits two half-lives ago weigh 0.75 now, less than one visit today.
    SQL(path, @"UPDATE history SET visits=3 WHERE url='https://alpha.example/'");
    sqlite3 *db = Open(path);
    double rank, visited = 0;
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(db, "SELECT visited FROM history WHERE url='https://alpha.example/'", -1, &stmt, NULL);
    if (sqlite3_step(stmt) == SQLITE_ROW) visited = sqlite3_column_double(stmt, 0);
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    rank = visited * M_LN2 / LTHistoryHalfLife + log(3);
    SQL(path, [NSString stringWithFormat:@"UPDATE history SET rank=%.17g WHERE url='https://alpha.example/'", rank]);
    Age(path, @"https://alpha.example/", 2 * LTHistoryHalfLife / 86400);
    store = OpenStore(path);
    CHECK([URLs([store searchHistory:@"alp" limit:10]).firstObject isEqual:@"https://alphabet.example/"],
          "recent visits outweigh older ones: 3 visits 60 days ago rank below 1 today");
    for (int i = 0; i < 2; i++) [store recordVisit:@"https://alphabet.example/" title:@"Alphabet"];
    [store waitForWrites];
    // A visit now to the older URL adds 1 to its 0.75, still below alphabet's 3.
    [store recordVisit:@"https://alpha.example/" title:@"Alpha"];
    [store waitForWrites];
    CHECK([URLs([store searchHistory:@"alp" limit:10]).firstObject isEqual:@"https://alphabet.example/"],
          "a new visit adds to a decayed weight rather than resetting it");
    for (int i = 0; i < 2; i++) [store recordVisit:@"https://alpha.example/" title:@"Alpha"];
    [store waitForWrites];
    CHECK([URLs([store searchHistory:@"alp" limit:10]).firstObject isEqual:@"https://alpha.example/"],
          "frequency overtakes once the decayed weight is higher");

    // Match type comes before frecency.
    for (int i = 0; i < 10; i++) [store recordVisit:@"https://docs.example/zebra" title:@"Zebra handbook"];
    [store recordVisit:@"https://zebra.example/" title:@"Home"];
    [store waitForWrites];
    NSArray *zebra = [store searchHistory:@"zeb" limit:10];
    CHECK([URLs(zebra) isEqual:(@[@"https://zebra.example/", @"https://docs.example/zebra"])],
          "an address-prefix match ranks above a more visited word match");

    // The Command Bar keeps the store's order and puts only the best address match above web search.
    LTProfile *profile = store.profile;
    NSArray *results = LTCommandResults(@"zeb", profile, zebra, [NSSet new], nil);
    CHECK([results[0][@"value"] isEqual:@"https://zebra.example/"] && [results[1][@"icon"] isEqual:@"magnifyingglass"] &&
              [results[2][@"value"] isEqual:@"https://docs.example/zebra"],
          "Command Bar: the best address match leads, web search next, other history after");
    results = LTCommandResults(@"handbook", profile, [store searchHistory:@"handbook" limit:30], [NSSet new], nil);
    CHECK([results[0][@"icon"] isEqual:@"magnifyingglass"] && [results[1][@"value"] isEqual:@"https://docs.example/zebra"],
          "Command Bar: a word match follows web search");
    results = LTCommandResults(@"zebra.example", profile, [store searchHistory:@"zebra.example" limit:30], [NSSet new], nil);
    CHECK([results[0][@"detail"] isEqual:@"Open address"], "Command Bar: a typed address still opens first");
}

static void RetentionTests(NSString *root) {
    NSString *path = NewPath(root);
    LTStore *store = OpenStore(path);
    [store recordVisit:@"https://old.example/" title:@"Old"];
    [store recordVisit:@"https://fresh.example/" title:@"Fresh"];
    [store waitForWrites];
    store = nil;
    Age(path, @"https://old.example/", LTHistoryMaxAge / 86400 + 1);
    store = OpenStore(path);
    CHECK([store searchHistory:@"" limit:10].count == 2, "opening the store leaves retention to the writer");
    // The first visit of a session applies retention on the writer; the main thread only queues it.
    double start = Now();
    [store recordVisit:@"https://next.example/" title:@"Next"];
    double queued = (Now() - start) * 1000;
    [store waitForWrites];
    CHECK([URLs([store searchHistory:@"" limit:10]) isEqual:(@[@"https://next.example/", @"https://fresh.example/"])] &&
              [store searchHistory:@"old" limit:10].count == 0,
          "visits older than the maximum age are dropped after the first visit");
    CHECK(queued < FrameBudgetMs, "recording a visit returns without waiting for retention");
    NSError *error = nil;

    for (int i = 0; i < 30; i++)
        for (int visit = 0; visit <= i % 3; visit++)
            [store recordVisit:[NSString stringWithFormat:@"https://count.example/%02d", i] title:@"Count"];
    [store waitForWrites];
    CHECK([store pruneHistoryBefore:0 keeping:10 error:&error] &&
              [Text(path, @"SELECT count(*) FROM history") isEqual:@"10"] &&
              [Text(path, @"SELECT min(visits) FROM history") isEqual:@"3"],
          "beyond the URL limit the least frecent URLs are dropped");

    // More than one batch: retention deletes in steps so queued saves can run in between.
    path = NewPath(root);
    store = OpenStore(path);
    SQL(path, [NSString stringWithFormat:
        @"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<2600) "
        @"INSERT INTO history(url,title,address,words,visited,visits,rank) SELECT 'https://bulk.example/'||i,'Bulk '||i,"
        @"'bulk.example/'||i,' bulk '||i||' bulk example '||i,%.17g-i,1,(%.17g-i)*%.17g FROM n",
        NSDate.date.timeIntervalSince1970, NSDate.date.timeIntervalSince1970, M_LN2 / LTHistoryHalfLife]);
    CHECK([store pruneHistoryBefore:NSDate.date.timeIntervalSince1970 - 1500.5 keeping:1000 error:&error] &&
              [Text(path, @"SELECT count(*) FROM history") isEqual:@"1000"] &&
              [Text(path, @"SELECT max(CAST(substr(url,22) AS INTEGER)) FROM history") isEqual:@"1000"] &&
              Run(path, @"INSERT INTO history_fts(history_fts) VALUES('integrity-check')"),
          "retention runs over several batches and keeps the full-text index in step");
    CHECK(LTHistoryMaxAge == 90 * 86400 && LTHistoryMaxURLs == 100000, "the default retention is 90 days and 100,000 URLs");
}

static void MigrationTests(NSString *root) {
    // Build a version 1 database the way Lite 0.1.0 wrote it.
    NSString *path = NewPath(root);
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *json = [NSJSONSerialization dataWithJSONObject:LTProfile.fresh.JSON options:0 error:nil];
    sqlite3 *db = NULL;
    sqlite3_open(path.fileSystemRepresentation, &db);
    sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE profile (id INTEGER PRIMARY KEY CHECK(id=1), json BLOB NOT NULL);"
                     "CREATE TABLE history (url TEXT PRIMARY KEY, title TEXT NOT NULL, visited REAL NOT NULL);"
                     "CREATE INDEX history_time ON history(visited);"
                     "INSERT INTO history VALUES('https://www.GitHub.com/lite','Lite repository',strftime('%s','now')-100);"
                     "INSERT INTO history VALUES('http://notes.example/a','Meeting notes',strftime('%s','now')-50);"
                     "INSERT INTO history VALUES('https://ancient.example/','Ancient',strftime('%s','now')-200*86400);"
                     "PRAGMA user_version=1;", NULL, NULL, NULL);
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(db, "INSERT INTO profile VALUES(1,?)", -1, &stmt, NULL);
    sqlite3_bind_blob(stmt, 1, json.bytes, (int)json.length, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    sqlite3_close(db);

    LTStore *store = OpenStore(path);
    CHECK(([Text(path, @"PRAGMA user_version") isEqual:[NSString stringWithFormat:@"%d", LTStoreSchemaVersion]] && LTStoreSchemaVersion == 2),
          "a version 1 database is migrated to version 2");
    CHECK([Text(path, @"PRAGMA journal_mode") isEqual:@"wal"] && [Text(path, @"PRAGMA integrity_check") isEqual:@"ok"],
          "the migrated database stays in WAL mode and passes integrity_check");
    CHECK([Text(path, @"SELECT address||' '||visits FROM history WHERE url='https://www.GitHub.com/lite'") isEqual:@"github.com/lite 1"],
          "migrated rows keep their URL and get an address and one visit");
    CHECK([URLs([store searchHistory:@"gith" limit:10]) isEqual:@[@"https://www.GitHub.com/lite"]] &&
              [URLs([store searchHistory:@"meet" limit:10]) isEqual:@[@"http://notes.example/a"]],
          "migrated rows are searchable by address prefix and full text");
    CHECK([URLs([store searchHistory:@"" limit:10]) isEqual:(@[@"http://notes.example/a", @"https://www.GitHub.com/lite", @"https://ancient.example/"])],
          "migrated rows rank by their last visit");
    [store recordVisit:@"https://www.GitHub.com/lite" title:@"Lite repository"];
    [store waitForWrites];
    CHECK([[store searchHistory:@"gith" limit:1].firstObject[@"visits"] isEqual:@2], "a migrated URL keeps counting visits");
    CHECK([store searchHistory:@"ancient" limit:10].count == 0, "retention drops migrated rows past the maximum age");
    store = nil;
    store = OpenStore(path);
    CHECK([store searchHistory:@"gith" limit:10].count == 1, "a migrated profile reopens without migrating again");
    store = nil;

    // A version 1 database without a history table, as test fixtures write it.
    NSString *bare = NewPath(root);
    [NSFileManager.defaultManager createDirectoryAtPath:bare.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    sqlite3_open(bare.fileSystemRepresentation, &db);
    sqlite3_exec(db, "CREATE TABLE profile (id INTEGER PRIMARY KEY CHECK(id=1), json BLOB NOT NULL); PRAGMA user_version=1;", NULL, NULL, NULL);
    sqlite3_prepare_v2(db, "INSERT INTO profile VALUES(1,?)", -1, &stmt, NULL);
    sqlite3_bind_blob(stmt, 1, json.bytes, (int)json.length, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    store = OpenStore(bare);
    [store recordVisit:@"https://github.com/" title:@"GitHub"];
    [store waitForWrites];
    CHECK([store searchHistory:@"gith" limit:10].count == 1, "a version 1 database without history gains a working history");
    store = nil;

    // A newer schema still fails closed, and the store never writes to it.
    SQL(bare, [NSString stringWithFormat:@"PRAGMA user_version=%d", LTStoreSchemaVersion + 1]);
    NSError *error = nil;
    NSData *before = [NSData dataWithContentsOfFile:bare];
    CHECK(![[LTStore alloc] initWithPath:bare error:&error] && [before isEqual:[NSData dataWithContentsOfFile:bare]],
          "a database newer than version 2 is refused unchanged");
}

// Synthetic history at the retention cap: hosts, paths and titles drawn from a fixed vocabulary, with
// visits over the whole retention window. The same seed always gives the same rows.
static void SeedLargeHistory(NSString *path, NSUInteger count) {
    NSArray *syllables = @[@"ga", @"gi", @"git", @"hub", @"lab", @"news", @"doc", @"mail", @"shop", @"code", @"map", @"tube",
                           @"book", @"wiki", @"cloud", @"dev", @"app", @"note", @"pay", @"bank", @"film", @"game", @"art"];
    NSArray *words = @[@"the", @"swift", @"guide", @"release", @"notes", @"how", @"to", @"build", @"issue", @"pull",
                       @"request", @"weather", @"today", @"recipe", @"pasta", @"travel", @"flight", @"hotel", @"music",
                       @"review", @"python", @"error", @"stack", @"overflow", @"apple", @"design", @"system", @"video"];
    srand48(42);
    sqlite3 *db = Open(path);
    sqlite3_exec(db, "BEGIN", NULL, NULL, NULL);
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO history(url,title,address,visited,visits,rank,words) VALUES(?,?,?,?,?,?,?)", -1, &stmt, NULL);
    double now = NSDate.date.timeIntervalSince1970, decay = M_LN2 / LTHistoryHalfLife;
    for (NSUInteger i = 0; i < count; i++) {
        NSString *host = [NSString stringWithFormat:@"%@%@%lu.example", syllables[lrand48() % syllables.count],
                                                    syllables[lrand48() % syllables.count], (unsigned long)(lrand48() % 150)];
        NSMutableArray *title = [NSMutableArray new];
        for (int w = 0; w < 5; w++) [title addObject:words[lrand48() % words.count]];
        NSString *address = [NSString stringWithFormat:@"%@/%@/%lu", host, [title componentsJoinedByString:@"-"], (unsigned long)i];
        int visits = 1 + (int)(lrand48() % 20 == 0 ? lrand48() % 50 : lrand48() % 3);
        double visited = now - drand48() * (LTHistoryMaxAge - 86400);
        sqlite3_bind_text(stmt, 1, [@"https://" stringByAppendingString:address].UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, [[title componentsJoinedByString:@" "] capitalizedString].UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 3, address.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_double(stmt, 4, visited);
        sqlite3_bind_int(stmt, 5, visits);
        sqlite3_bind_double(stmt, 6, log(visits) + visited * decay);
        sqlite3_bind_text(stmt, 7, Words([[title componentsJoinedByString:@" "] capitalizedString], address).UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_reset(stmt);
    }
    sqlite3_finalize(stmt);
    sqlite3_exec(db, "COMMIT", NULL, NULL, NULL);
    sqlite3_close(db);
}
static double Median(NSMutableArray<NSNumber *> *values) {
    [values sortUsingSelector:@selector(compare:)];
    return ([values[(values.count - 1) / 2] doubleValue] + [values[values.count / 2] doubleValue]) / 2;
}
// Times what the Command Bar does on the main thread for each keystroke: the history query and the
// ranking of every result. Each query also runs once first so it is measured warm, as it is while typing.
static NSDictionary *MeasureCommandBar(NSString *root, NSUInteger rows, int runs) {
    NSString *path = NewPath(root);
    LTStore *store = OpenStore(path);
    store = nil;
    double start = Now();
    SeedLargeHistory(path, rows);
    double seeded = (Now() - start) * 1000;
    start = Now();
    store = OpenStore(path);
    double reopened = (Now() - start) * 1000;
    NSMutableArray *queries = [NSMutableArray new];
    double worst = 0;
    NSArray *typed = @[@"g", @"gi", @"gith", @"githu", @"gihub7", @"news", @"swift g", @"swift guide rel", @"the",
                       @"https://www.", @"https://www.githu", @"zzzz", @"pull request", @"a"];
    for (NSString *query in typed) {
        NSMutableArray *times = [NSMutableArray new];
        NSUInteger found = 0;
        [store searchHistory:query limit:30];
        for (int run = 0; run < runs; run++) {
            double t = Now();
            NSArray *history = [store searchHistory:query limit:30];
            LTCommandResults(query, store.profile, history, [NSSet new], nil);
            [times addObject:@((Now() - t) * 1000)];
            found = history.count;
        }
        double median = Median(times), max = [[times valueForKeyPath:@"@max.self"] doubleValue];
        worst = MAX(worst, median);
        [queries addObject:@{@"query": query, @"results": @(found), @"median_ms": @(median), @"max_ms": @(max)}];
    }
    // Writer costs, for the record: one visit, retention at the cap, and an index merge after a deletion.
    NSMutableArray *visits = [NSMutableArray new];
    for (int i = 0; i < runs; i++) {
        double t = Now();
        [store recordVisit:[NSString stringWithFormat:@"https://measure.example/%d", i] title:@"Measured visit"];
        [store waitForWrites];
        [visits addObject:@((Now() - t) * 1000)];
    }
    NSError *error = nil;
    start = Now();
    [store pruneHistoryBefore:NSDate.date.timeIntervalSince1970 - LTHistoryMaxAge keeping:LTHistoryMaxURLs error:&error];
    double prune = (Now() - start) * 1000;
    NSDictionary *size = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    start = Now();
    [store deleteHistoryURL:@"https://measure.example/0" error:&error];
    double deletion = (Now() - start) * 1000;
    start = Now();
    [store clearHistorySince:0 error:&error];
    double clearing = (Now() - start) * 1000;
    store = nil;
    return @{@"rows": @(rows), @"runs": @(runs), @"frame_budget_ms": @(FrameBudgetMs), @"worst_median_ms": @(worst),
             @"queries": queries, @"seed_ms": @(seeded), @"open_ms": @(reopened),
             @"record_visit_durable_median_ms": @(Median(visits)), @"retention_at_cap_ms": @(prune),
             @"delete_one_url_with_index_merge_and_backup_ms": @(deletion),
             @"clear_all_history_with_backup_ms": @(clearing), @"database_bytes": size[NSFileSize] ?: @0};
}

int main(int argc, char **argv) { @autoreleasepool {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"lite-history-" stringByAppendingString:LTUUID()]];
    if (argc == 2 && !strcmp(argv[1], "--measure")) {
        NSDictionary *result = MeasureCommandBar(root, LTHistoryMaxURLs, 25);
        NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"workload": @"Command Bar history query plus result ranking, "
            "warm, 30 results, synthetic history at the retention cap", @"results": result}
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        putchar('\n');
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        return 0;
    }
    CHECK(sqlite3_compileoption_used("ENABLE_FTS5"), "the linked SQLite has FTS5");
    MatchingTests(root);
    RankingTests(root);
    RetentionTests(root);
    MigrationTests(root);
    NSDictionary *measured = MeasureCommandBar(root, LTHistoryMaxURLs, 5);
    for (NSDictionary *query in measured[@"queries"])
        printf("  %-30s %6.2f ms median, %3lu results\n", [query[@"query"] UTF8String], [query[@"median_ms"] doubleValue],
               (unsigned long)[query[@"results"] unsignedIntegerValue]);
    CHECK([measured[@"worst_median_ms"] doubleValue] < FrameBudgetMs,
          "every Command Bar history query at 100,000 URLs fits in one 60 Hz frame");
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    printf("\n%d passed, %d failed\n", passed, failed);
    return failed ? 1 : 0;
}}
