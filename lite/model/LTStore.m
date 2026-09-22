#import "LTStore.h"
#import <sqlite3.h>
#include <sys/stat.h>
NSNotificationName const LTStoreChanged = @"LTStoreChanged";
@implementation LTStore {
    sqlite3 *_db;
}
- (instancetype)initWithPath:(NSString *)path error:(NSError **)error {
    if ((self = [super init])) {
        _privateMode = path == nil;
        if (path && ![NSFileManager.defaultManager
                              createDirectoryAtPath:path.stringByDeletingLastPathComponent
                        withIntermediateDirectories:YES
                                         attributes:@{NSFilePosixPermissions : @0700}
                                              error:error])
            return nil;
        if (sqlite3_open_v2(path ? path.UTF8String : ":memory:", &_db,
                            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                            NULL) != SQLITE_OK) {
            if (error)
                *error = LTError(@"Could not open Lite's database.");
            return nil;
        }
        sqlite3_busy_timeout(_db, 3000);
        const char *schema =
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS profile "
            "(id INTEGER PRIMARY KEY CHECK(id=1), json BLOB NOT NULL); CREATE TABLE IF NOT EXISTS "
            "history (url TEXT PRIMARY KEY, title TEXT NOT NULL, visited REAL NOT NULL); CREATE "
            "INDEX IF NOT EXISTS history_time ON history(visited); PRAGMA user_version=1;";
        sqlite3_stmt *version = NULL;
        sqlite3_prepare_v2(_db, "PRAGMA user_version", -1, &version, NULL);
        int v = sqlite3_step(version) == SQLITE_ROW ? sqlite3_column_int(version, 0) : 0;
        sqlite3_finalize(version);
        if (v > 1 || sqlite3_exec(_db, schema, NULL, NULL, NULL) != SQLITE_OK) {
            if (error)
                *error = LTError(
                    @"Unsupported or unreadable Lite database. No organization was replaced.");
            return nil;
        }
        sqlite3_stmt *stmt = NULL;
        sqlite3_prepare_v2(_db, "SELECT json FROM profile WHERE id=1", -1, &stmt, NULL);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            NSData *d = [NSData dataWithBytes:sqlite3_column_blob(stmt, 0)
                                       length:sqlite3_column_bytes(stmt, 0)];
            id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:error];
            _profile = [LTProfile fromJSON:j error:error];
        } else
            _profile = LTProfile.fresh;
        sqlite3_finalize(stmt);
        if (!_profile)
            return nil;
        for (LTNode *node in _profile.nodes)
            if ([node.kind isEqual:@"folder"])
                node.expanded = NO;
        if (path)
            chmod(path.fileSystemRepresentation, 0600);
    }
    return self;
}
- (void)dealloc {
    if (_db)
        sqlite3_close(_db);
}
- (BOOL)commit:(void (^)(LTProfile *))change error:(NSError **)error {
    LTProfile *candidate = [LTProfile fromJSON:_profile.JSON error:error];
    if (!candidate)
        return NO;
    change(candidate);
    if (![candidate validate:error])
        return NO;
    NSData *json = [NSJSONSerialization dataWithJSONObject:candidate.JSON
                                                   options:NSJSONWritingSortedKeys
                                                     error:error];
    if (!json)
        return NO;
    if (sqlite3_exec(_db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) {
        if (error)
            *error = LTError(@"Lite could not begin saving. Your previous data is intact.");
        return NO;
    }
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(
        _db,
        "INSERT INTO profile(id,json) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
        -1, &stmt, NULL);
    if (rc == SQLITE_OK) {
        sqlite3_bind_blob(stmt, 1, json.bytes, (int)json.length, SQLITE_TRANSIENT);
        rc = sqlite3_step(stmt);
    }
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE || sqlite3_exec(_db, "COMMIT", NULL, NULL, NULL) != SQLITE_OK) {
        sqlite3_exec(_db, "ROLLBACK", NULL, NULL, NULL);
        if (error)
            *error = LTError(
                @"Lite could not save. Your previous data is intact; check available disk space.");
        return NO;
    }
    _profile = candidate;
    [NSNotificationCenter.defaultCenter postNotificationName:LTStoreChanged object:self];
    return YES;
}
- (void)recordVisit:(NSString *)url title:(NSString *)title {
    if (_privateMode || ![url hasPrefix:@"http"])
        return;
    sqlite3_stmt *s = NULL;
    sqlite3_prepare_v2(_db,
                       "INSERT INTO history(url,title,visited) VALUES(?,?,?) ON CONFLICT(url) DO "
                       "UPDATE SET title=excluded.title,visited=excluded.visited",
                       -1, &s, NULL);
    sqlite3_bind_text(s, 1, url.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(s, 2, title.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_double(s, 3, NSDate.date.timeIntervalSince1970);
    sqlite3_step(s);
    sqlite3_finalize(s);
}
- (NSArray<NSDictionary *> *)history:(NSString *)query limit:(NSInteger)limit {
    return [self history:query limit:limit exact:NO];
}
- (NSArray<NSDictionary *> *)history:(NSString *)query limit:(NSInteger)limit exact:(BOOL)exact {
    NSMutableArray *rows = [NSMutableArray new];
    sqlite3_stmt *s = NULL;
    const char *sql =
        exact ? "SELECT url,title,visited FROM history WHERE url=? OR title=? ORDER BY visited "
                "DESC LIMIT ?"
              : "SELECT url,title,visited FROM history WHERE instr(lower(url),lower(?))>0 "
                "OR instr(lower(title),lower(?))>0 ORDER BY visited DESC LIMIT ?";
    sqlite3_prepare_v2(_db, sql, -1, &s, NULL);
    sqlite3_bind_text(s, 1, query.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(s, 2, query.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(s, 3, (int)limit);
    while (sqlite3_step(s) == SQLITE_ROW) {
        NSString *u = @((const char *)sqlite3_column_text(s, 0));
        NSString *t = @((const char *)sqlite3_column_text(s, 1));
        [rows addObject:@{@"url" : u, @"title" : t, @"visited" : @(sqlite3_column_double(s, 2))}];
    }
    sqlite3_finalize(s);
    return rows;
}
- (void)clearHistorySince:(double)time {
    sqlite3_stmt *s = NULL;
    sqlite3_prepare_v2(_db, "DELETE FROM history WHERE visited>=?", -1, &s, NULL);
    sqlite3_bind_double(s, 1, time);
    sqlite3_step(s);
    sqlite3_finalize(s);
}
- (void)deleteHistoryURL:(NSString *)url {
    sqlite3_stmt *s = NULL;
    sqlite3_prepare_v2(_db, "DELETE FROM history WHERE url=?", -1, &s, NULL);
    sqlite3_bind_text(s, 1, url.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_step(s);
    sqlite3_finalize(s);
}
@end
