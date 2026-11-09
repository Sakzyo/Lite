#import "LTStore.h"
#import <sqlite3.h>
#import <os/lock.h>
#import <os/log.h>
#include <math.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
NSNotificationName const LTStoreChanged = @"LTStoreChanged";
NSNotificationName const LTStoreBackupFailed = @"LTStoreBackupFailed";
NSNotificationName const LTStoreWriteFailed = @"LTStoreWriteFailed";
NSString *const LTStoreWriteErrorKey = @"LTStoreWriteError";
NSString *const LTStoreChangeQuietObserverKey = @"LTStoreChangeQuietObserver";
static const NSUInteger MaxProfileBytes = 64 * 1024 * 1024;
static const NSTimeInterval BackupInterval = 60;
const int LTStoreSchemaVersion = 2;
const NSTimeInterval LTHistoryMaxAge = 90 * 86400;
const NSUInteger LTHistoryMaxURLs = 100000;
const NSTimeInterval LTHistoryHalfLife = 30 * 86400;
NSString *const LTHistoryMatchExact = @"exact";
NSString *const LTHistoryMatchAddress = @"address";
NSString *const LTHistoryMatchWord = @"word";
// Retention runs at most this often, and deletes this many rows per turn of the writer so that
// queued saves never wait behind a large prune.
static const NSTimeInterval HistoryPruneInterval = 3600;
static const int HistoryPruneBatch = 1000;
static NSString *DatabasePath(NSString *path) {
    // macOS temporary directories commonly traverse /var -> /private/var.
    // Resolve the parent only; never follow a database or backup symlink.
    if (!path) return nil;
    NSString *parent = path.stringByDeletingLastPathComponent;
    char resolved[PATH_MAX];
    NSString *directory = realpath(parent.fileSystemRepresentation, resolved)
        ? [NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved length:strlen(resolved)]
        : DatabasePath(parent);
    return [directory stringByAppendingPathComponent:path.lastPathComponent];
}

static BOOL StoreError(NSError **error, NSString *message) {
    if (error) *error = LTError(message);
    return NO;
}
// Frecency is a visit count in which each visit's weight halves every LTHistoryHalfLife. Stored
// as rank = ln(weight) + decay * time, it orders rows by their weight now without being updated as
// time passes, because every row decays by the same factor. A visit adds one to the weight:
// rank' = logaddexp(rank, decay * time), which also stays correct if the clock steps backwards.
static double HistoryDecay(void) { return M_LN2 / LTHistoryHalfLife; }
static double HistoryRankAddingVisit(double rank, BOOL visited, double time) {
    double visit = time * HistoryDecay();
    if (!visited) return visit;
    double high = MAX(rank, visit), low = MIN(rank, visit);
    return high + log1p(exp(low - high));
}
// The part of a URL or typed text that address-prefix matching compares: lowercase, without the
// scheme or a leading "www.". "https://www.GitHub.com/x" and "github.com/x" both give "github.com/x".
static NSString *HistoryAddress(NSString *text) {
    NSString *address = text.lowercaseString ?: @"";
    for (NSString *scheme in @[@"https://", @"http://"])
        if ([address hasPrefix:scheme]) { address = [address substringFromIndex:scheme.length]; break; }
    if ([address hasPrefix:@"www."]) address = [address substringFromIndex:4];
    return address;
}
// Used only while migrating rows written before the address column existed.
static void HistoryAddressFunction(sqlite3_context *context, int count, sqlite3_value **values) {
    const char *text = (const char *)sqlite3_value_text(values[0]);
    NSString *address = HistoryAddress(text ? [NSString stringWithUTF8String:text] : nil);
    sqlite3_result_text(context, address.UTF8String ?: "", -1, SQLITE_TRANSIENT);
}
#define HistoryDeleteTrigger \
    "CREATE TRIGGER IF NOT EXISTS history_fts_delete AFTER DELETE ON history BEGIN " \
    "INSERT INTO history_fts(history_fts,rowid,title,address) VALUES('delete',old.id,old.title,old.address); END;"
static BOOL Exec(sqlite3 *db, const char *sql) { return sqlite3_exec(db, sql, NULL, NULL, NULL) == SQLITE_OK; }
static int UserVersion(sqlite3 *db) {
    sqlite3_stmt *stmt = NULL;
    int version = -1;
    if (sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW)
        version = sqlite3_column_int(stmt, 0);
    sqlite3_finalize(stmt);
    return version;
}
static BOOL HasColumn(sqlite3 *db, const char *table, const char *column) {
    sqlite3_stmt *stmt = NULL;
    BOOL found = NO;
    if (sqlite3_prepare_v2(db, "SELECT 1 FROM pragma_table_info(?) WHERE name=?", -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, table, -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 2, column, -1, SQLITE_STATIC);
        found = sqlite3_step(stmt) == SQLITE_ROW;
    }
    sqlite3_finalize(stmt);
    return found;
}
// Brings a database at any earlier user_version to LTStoreSchemaVersion in one transaction, so an
// interrupted migration leaves the previous schema. Every step is safe to repeat.
//
// Version 2 gives history a stable integer key (FTS5 refers to rows by it, and VACUUM may renumber
// an implicit rowid), a visit count, a frecency rank and a normalized address, plus a full-text index
// over titles and addresses that triggers keep in step with the table.
static BOOL MigrateSchema(sqlite3 *db) {
    if (!Exec(db, "BEGIN IMMEDIATE")) return NO;
    BOOL ok = Exec(db, "CREATE TABLE IF NOT EXISTS profile (id INTEGER PRIMARY KEY CHECK(id=1), json BLOB NOT NULL)");
    int version = ok ? UserVersion(db) : -1;
    if (version < 0 || version > LTStoreSchemaVersion) ok = NO;
    if (ok && version < LTStoreSchemaVersion) {
        BOOL legacy = HasColumn(db, "history", "url") && !HasColumn(db, "history", "address");
        if (legacy) ok = Exec(db, "ALTER TABLE history RENAME TO history_v1");
        ok = ok && Exec(db,
            "CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE, "
            "title TEXT NOT NULL, address TEXT NOT NULL, visited REAL NOT NULL, "
            "visits INTEGER NOT NULL DEFAULT 1 CHECK(visits>0), rank REAL NOT NULL)");
        if (legacy) {
            // Version 1 kept only the last visit, so each URL starts with one visit at that time.
            NSString *copy = [NSString stringWithFormat:@"INSERT INTO history(url,title,address,visited,visits,rank) "
                "SELECT url,title,lite_history_address(url),visited,1,visited*%.17g FROM history_v1 ORDER BY visited,rowid",
                HistoryDecay()];
            ok = ok && Exec(db, copy.UTF8String) && Exec(db, "DROP TABLE history_v1");
        }
        ok = ok && Exec(db,
            "CREATE INDEX IF NOT EXISTS history_time ON history(visited);"
            "CREATE INDEX IF NOT EXISTS history_rank ON history(rank);"
            "CREATE INDEX IF NOT EXISTS history_address ON history(address,rank);"
            "CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(title, address, content='history', "
            "content_rowid='id', tokenize='unicode61 remove_diacritics 2');"
            "CREATE TRIGGER IF NOT EXISTS history_fts_insert AFTER INSERT ON history BEGIN "
            "INSERT INTO history_fts(rowid,title,address) VALUES(new.id,new.title,new.address); END;"
            HistoryDeleteTrigger
            "CREATE TRIGGER IF NOT EXISTS history_fts_update AFTER UPDATE OF title,address ON history "
            "WHEN old.title IS NOT new.title OR old.address IS NOT new.address BEGIN "
            "INSERT INTO history_fts(history_fts,rowid,title,address) VALUES('delete',old.id,old.title,old.address);"
            "INSERT INTO history_fts(rowid,title,address) VALUES(new.id,new.title,new.address); END;"
            "INSERT INTO history_fts(history_fts) VALUES('rebuild');");
        NSString *stamp = [NSString stringWithFormat:@"PRAGMA user_version=%d", LTStoreSchemaVersion];
        ok = ok && Exec(db, stamp.UTF8String);
    }
    if (ok && Exec(db, "COMMIT")) return YES;
    Exec(db, "ROLLBACK");
    return NO;
}
static BOOL RegularFile(NSString *path) {
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) == 0 && S_ISREG(info.st_mode) &&
        info.st_uid == getuid() && info.st_nlink == 1;
}
static BOOL SyncPath(NSString *path, BOOL directory) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | (directory ? O_DIRECTORY : 0));
    if (fd < 0) return NO;
    BOOL ok = fsync(fd) == 0;
    close(fd);
    return ok;
}
static BOOL DurableCopy(NSString *source, NSString *target, NSError **error) {
    if (!RegularFile(source) || ![NSFileManager.defaultManager copyItemAtPath:source toPath:target error:error])
        return StoreError(error, @"Lite could not preserve the original database. No recovery was installed.");
    if (chmod(target.fileSystemRepresentation, 0600) || !SyncPath(target, NO))
        return StoreError(error, @"Lite could not flush the recovery copy. Check available disk space.");
    return YES;
}
static BOOL FutureDatabaseVersion(sqlite3 *db) {
    sqlite3_stmt *stmt = NULL;
    BOOL future = NO;
    if (sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW) {
        int version = sqlite3_column_int(stmt, 0);
        future = version < 0 || version > LTStoreSchemaVersion;
    }
    sqlite3_finalize(stmt);
    return future;
}
static BOOL FutureVersion(sqlite3 *db) {
    if (FutureDatabaseVersion(db)) return YES;
    BOOL future = NO;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, "SELECT json FROM profile WHERE id=1", -1, &stmt, NULL) == SQLITE_OK &&
        sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_bytes(stmt, 0) <= MaxProfileBytes) {
        NSData *data = [NSData dataWithBytes:sqlite3_column_blob(stmt, 0) length:sqlite3_column_bytes(stmt, 0)];
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([json isKindOfClass:NSDictionary.class] && [json[@"version"] isKindOfClass:NSNumber.class])
            future = ![json[@"version"] isEqual:@1];
    }
    sqlite3_finalize(stmt);
    return future;
}
static LTProfile *ReadProfile(sqlite3 *db, BOOL allowEmpty, NSError **error) {
    if (FutureDatabaseVersion(db)) {
        StoreError(error, @"This profile was written by an unsupported Lite version. Open it with a compatible newer app; recovery and downgrade are disabled.");
        return nil;
    }
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(db, "SELECT json FROM profile WHERE id=1", -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        sqlite3_finalize(stmt);
        StoreError(error, @"Lite's profile database is unreadable. The original files were preserved.");
        return nil;
    }
    rc = sqlite3_step(stmt);
    LTProfile *profile = nil;
    if (rc == SQLITE_ROW && sqlite3_column_bytes(stmt, 0) > 0 && sqlite3_column_bytes(stmt, 0) <= MaxProfileBytes) {
        NSData *data = [NSData dataWithBytes:sqlite3_column_blob(stmt, 0) length:sqlite3_column_bytes(stmt, 0)];
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
        if ([json isKindOfClass:NSDictionary.class] && [json[@"version"] isKindOfClass:NSNumber.class] &&
            ![json[@"version"] isEqual:@1])
            StoreError(error, @"This profile was written by an unsupported Lite version. Open it with a compatible newer app; recovery and downgrade are disabled.");
        else profile = [LTProfile fromJSON:json error:error];
    } else if (rc == SQLITE_DONE && allowEmpty) profile = LTProfile.fresh;
    else StoreError(error, @"Lite's saved profile is missing or unreadable. The original files were preserved.");
    sqlite3_finalize(stmt);
    return profile;
}
static BOOL OpenReadOnly(NSString *path, sqlite3 **db) {
    if (!RegularFile(path) || sqlite3_open_v2(path.fileSystemRepresentation, db,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, NULL) != SQLITE_OK) return NO;
    sqlite3_limit(*db, SQLITE_LIMIT_LENGTH, (int)MaxProfileBytes);
    return YES;
}
static BOOL ValidBackup(NSString *path) {
    sqlite3 *db = NULL;
    BOOL valid = OpenReadOnly(path, &db) && ReadProfile(db, NO, nil) != nil;
    if (valid) {
        sqlite3_stmt *stmt = NULL;
        valid = sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, NULL) == SQLITE_OK &&
            sqlite3_step(stmt) == SQLITE_ROW && strcmp((const char *)sqlite3_column_text(stmt, 0), "ok") == 0;
        sqlite3_finalize(stmt);
    }
    if (db) sqlite3_close(db);
    return valid;
}
static NSString *AvailableBackup(NSString *path) {
    sqlite3 *db = NULL;
    BOOL future = OpenReadOnly(path, &db) && FutureVersion(db);
    if (db) sqlite3_close(db);
    if (future) return nil;
    for (NSString *suffix in @[@".backup", @".backup.previous"]) {
        NSString *backup = [path stringByAppendingString:suffix];
        if (ValidBackup(backup)) return backup;
    }
    return nil;
}

// One queued write. It crosses from the writer to the main thread through the outbox. The caller's
// blocks are cleared on the main thread, because whatever they captured (a window, a page) must not
// be released on the writer.
@class LTStoreWrite;
@interface LTStoreWrite : NSObject {
@public
    LTProfileChange change;
    BOOL (^operation)(LTStoreWrite *write, NSError **error);
    LTStoreCompletion completion;
    id quietObserver;
    BOOL waiting;  // A caller is blocked on this write and takes its result directly.
    LTProfile *committed;
    NSError *error;
    BOOL backupAttempted;
    NSError *backupError;
}
@end
@implementation LTStoreWrite
@end

@implementation LTStore {
    dispatch_queue_t _writer;
    // Writer only, apart from init and close, which cannot overlap a write.
    sqlite3 *_db;
    LTProfile *_committed;
    NSTimeInterval _lastBackup;
    NSTimeInterval _lastPrune;
    // Main thread only.
    sqlite3 *_reader;
    NSMutableArray<LTStoreWrite *> *_finished;
    BOOL _closed;
    // Guards the handover of finished writes from the writer to the main thread.
    os_unfair_lock _outboxLock;
    NSMutableArray<LTStoreWrite *> *_outbox;
    NSString *_path;
}
+ (BOOL)recoveryAvailableAtPath:(NSString *)path {
    return AvailableBackup(DatabasePath(path)) != nil;
}
+ (BOOL)recoverProfileAtPath:(NSString *)path preservedPath:(NSString **)preservedPath error:(NSError **)error {
    path = DatabasePath(path);
    NSString *backup = AvailableBackup(path);
    if (!backup) return StoreError(error, @"No compatible, known-good Lite backup is available. The original files were preserved.");
    NSString *directory = path.stringByDeletingLastPathComponent;
    NSString *marker = [path stringByAppendingString:@".recovery-pending"];
    NSString *pending = [path stringByAppendingString:@".recovery-tmp"];
    NSString *archive = nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:marker]) {
        if (!RegularFile(marker)) return StoreError(error, @"The recovery marker is unsafe. The original files were preserved.");
        NSString *name = [NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:error];
        if (![name hasPrefix:[path.lastPathComponent stringByAppendingString:@".damaged-"]] ||
            ![name isEqual:name.lastPathComponent]) return StoreError(error, @"The recovery marker is damaged. The preserved originals need manual inspection.");
        archive = [directory stringByAppendingPathComponent:name];
        if (!RegularFile([archive stringByAppendingPathComponent:path.lastPathComponent]))
            return StoreError(error, @"The preserved original is missing. Recovery stopped without replacing the database.");
    } else {
        NSUInteger archived = 0;
        for (NSString *name in [fm contentsOfDirectoryAtPath:directory error:error])
            if ([name hasPrefix:[path.lastPathComponent stringByAppendingString:@".damaged-"]]) archived++;
        if (archived >= 3) return StoreError(error, @"Three damaged profiles are already preserved. Move those .damaged folders to a safe location before another recovery.");
        archive = [path stringByAppendingFormat:@".damaged-%@", LTUUID()];
        if (![fm createDirectoryAtPath:archive withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
        for (NSString *suffix in @[@"", @"-wal", @"-shm", @"-journal"]) {
            NSString *source = [path stringByAppendingString:suffix];
            if ([fm fileExistsAtPath:source] && !DurableCopy(source, [archive stringByAppendingPathComponent:source.lastPathComponent], error)) return NO;
        }
        if (!RegularFile([archive stringByAppendingPathComponent:path.lastPathComponent]) ||
            !SyncPath(archive, YES) || !SyncPath(directory, YES))
            return StoreError(error, @"Lite could not durably preserve the damaged profile. Recovery stopped.");
        NSString *markerTemporary = [marker stringByAppendingString:@".tmp"];
        if ([fm fileExistsAtPath:markerTemporary] &&
            (!RegularFile(markerTemporary) || ![fm removeItemAtPath:markerTemporary error:error]))
            return StoreError(error, @"The interrupted recovery marker cannot be replaced safely.");
        int fd = open(markerTemporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        NSData *data = [archive.lastPathComponent dataUsingEncoding:NSUTF8StringEncoding];
        BOOL durable = fd >= 0 && write(fd, data.bytes, data.length) == (ssize_t)data.length && fsync(fd) == 0;
        if (fd >= 0) close(fd);
        if (!durable || rename(markerTemporary.fileSystemRepresentation, marker.fileSystemRepresentation) || !SyncPath(directory, YES)) {
            if (RegularFile(markerTemporary)) [fm removeItemAtPath:markerTemporary error:nil];
            return StoreError(error, @"Recovery was interrupted before replacement. Retry Restore Backup after checking disk space.");
        }
    }
    // The marker prevents a crash between WAL removal and database replacement from opening a fresh profile.
    if ([fm fileExistsAtPath:pending] && (!RegularFile(pending) || ![fm removeItemAtPath:pending error:error]))
        return StoreError(error, @"The pending recovery file cannot be replaced safely. The originals were preserved.");
    if (!DurableCopy(backup, pending, error)) return NO;
    if (!ValidBackup(pending)) return StoreError(error, @"The recovery copy failed validation. The originals were preserved.");
    for (NSString *suffix in @[@"-wal", @"-shm", @"-journal"]) {
        NSString *sidecar = [path stringByAppendingString:suffix];
        if ([fm fileExistsAtPath:sidecar] && (!RegularFile(sidecar) || ![fm removeItemAtPath:sidecar error:error]))
            return StoreError(error, @"An original database sidecar cannot be replaced safely. Retry recovery after checking folder permissions.");
    }
    if (rename(pending.fileSystemRepresentation, path.fileSystemRepresentation) || !SyncPath(directory, YES))
        return StoreError(error, @"Recovery installation was interrupted. Retry Restore Backup; your damaged originals are preserved.");
    if (unlink(marker.fileSystemRepresentation) || !SyncPath(directory, YES))
        return StoreError(error, @"The restored database is saved, but recovery finalization failed. Retry Restore Backup.");
    if (preservedPath) *preservedPath = archive;
    return YES;
}
- (instancetype)initWithPath:(NSString *)path error:(NSError **)error {
    if ((self = [super init])) {
        _writer = dispatch_queue_create("app.lite.profile-writer",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
        _outboxLock = OS_UNFAIR_LOCK_INIT;
        _outbox = [NSMutableArray new];
        _finished = [NSMutableArray new];
        path = DatabasePath(path);
        _privateMode = path == nil;
        _path = [path copy];
        NSFileManager *fm = NSFileManager.defaultManager;
        if (path && [fm fileExistsAtPath:[path stringByAppendingString:@".recovery-pending"]]) {
            StoreError(error, @"A profile recovery was interrupted. Choose Restore Backup to finish it. The damaged originals are preserved.");
            return nil;
        }
        BOOL exists = path && [fm fileExistsAtPath:path];
        if (exists) {
            sqlite3 *read = NULL;
            if (!OpenReadOnly(path, &read)) {
                if (read) sqlite3_close(read);
                StoreError(error, @"Lite could not read the existing database safely. The original files were preserved.");
                return nil;
            }
            _profile = ReadProfile(read, NO, error);
            sqlite3_close(read);
            if (!_profile) return nil;
        } else _profile = LTProfile.fresh;
        _committed = _profile;
        if (path && ![fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                                    attributes:@{NSFilePosixPermissions:@0700} error:error]) return nil;
        if (sqlite3_open_v2(path ? path.fileSystemRepresentation : ":memory:", &_db,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
                           NULL) != SQLITE_OK) {
            StoreError(error, @"Could not open Lite's database.");
            return nil;
        }
        sqlite3_busy_timeout(_db, 3000);
        sqlite3_limit(_db, SQLITE_LIMIT_LENGTH, (int)MaxProfileBytes);
        sqlite3_create_function_v2(_db, "lite_history_address", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, NULL,
                                   HistoryAddressFunction, NULL, NULL, NULL);
        if (!Exec(_db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;") || !MigrateSchema(_db)) {
            StoreError(error, @"Lite could not initialize its database. No organization was replaced.");
            return nil;
        }
        if (path) {
            chmod(path.fileSystemRepresentation, 0600);
            NSDictionary *attributes = [fm attributesOfItemAtPath:[path stringByAppendingString:@".backup"] error:nil];
            _lastBackup = [attributes[NSFileModificationDate] timeIntervalSince1970];
        }
        // Persist a fresh profile immediately so an interrupted first launch cannot leave an empty schema.
        if (!exists && ![self commit:^(LTProfile *profile) {} error:error]) return nil;
        // WAL gives this connection the last commit while the writer is inside the next one.
        if (path) {
            if (!OpenReadOnly(path, &_reader)) {
                StoreError(error, @"Lite could not open its database for reading.");
                return nil;
            }
            sqlite3_busy_timeout(_reader, 250);
            // The Command Bar reads scattered rows of a history that can be tens of megabytes. Mapping
            // the file spares a copy into SQLite's 8 MB page cache for each one. The connection only reads.
            Exec(_reader, "PRAGMA mmap_size=268435456");
        }
        for (LTNode *node in _profile.nodes)
            if ([node.kind isEqual:@"folder"]) node.expanded = NO;
        [_profile seal];
        if (exists) {
            NSError *failure = nil;
            if ([self updateBackup:&failure]) {
                _backupError = failure;
                if (failure) [NSNotificationCenter.defaultCenter postNotificationName:LTStoreBackupFailed object:self];
            }
        }
    }
    return self;
}
- (void)dealloc {
    if (_reader) sqlite3_close(_reader);
    if (_db) sqlite3_close(_db);
}
// Returns NO if the once-a-minute limit skipped the refresh; a failed attempt fills `failure`.
- (BOOL)updateBackup:(NSError **)failure {
    if (!_path || NSDate.date.timeIntervalSince1970 - _lastBackup < BackupInterval) return NO;
    NSString *backup = [_path stringByAppendingString:@".backup"];
    NSString *previous = [_path stringByAppendingString:@".backup.previous"];
    NSString *pending = [_path stringByAppendingString:@".backup.pending"];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *error = nil;
    BOOL ok = YES;
    if ([fm fileExistsAtPath:pending]) ok = RegularFile(pending) && [fm removeItemAtPath:pending error:&error];
    sqlite3 *target = NULL;
    if (ok) {
        int fd = open(pending.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0600);
        ok = fd >= 0;
        if (fd >= 0) close(fd);
    }
    if (ok) ok = sqlite3_open_v2(pending.fileSystemRepresentation, &target,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, NULL) == SQLITE_OK;
    if (ok) {
        sqlite3_backup *copy = sqlite3_backup_init(target, "main", _db, "main");
        ok = copy && sqlite3_backup_step(copy, -1) == SQLITE_DONE;
        if (copy && sqlite3_backup_finish(copy) != SQLITE_OK) ok = NO;
        if (ok) ok = sqlite3_exec(target, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL", NULL, NULL, NULL) == SQLITE_OK;
    }
    if (target) sqlite3_close(target);
    if (ok) ok = SyncPath(pending, NO) && ValidBackup(pending);
    if (ok && [fm fileExistsAtPath:backup]) {
        // Never replace a valid previous generation with a damaged backup.
        if (ValidBackup(backup)) ok = rename(backup.fileSystemRepresentation, previous.fileSystemRepresentation) == 0;
        else ok = [fm removeItemAtPath:backup error:&error];
    }
    if (ok) ok = rename(pending.fileSystemRepresentation, backup.fileSystemRepresentation) == 0 &&
        SyncPath(_path.stringByDeletingLastPathComponent, YES);
    if (!ok) *failure = error ?: LTError(@"Your current profile was saved, but its recovery backup could not be updated. Check free disk space and folder permissions.");
    // Also throttle failed attempts to avoid repeated disk work and alerts under disk pressure.
    _lastBackup = NSDate.date.timeIntervalSince1970;
    if (RegularFile(pending)) [fm removeItemAtPath:pending error:nil];
    return YES;
}
// Runs on the writer. Saves are serial, so each one starts from the last commit and never from a
// write that is still queued. That is why a failure drops one write and not those behind it.
- (BOOL)persist:(LTProfile *)candidate error:(NSError **)error {
    if (![candidate validate:error]) return NO;
    NSData *json = [NSJSONSerialization dataWithJSONObject:candidate.JSON options:0 error:error];
    if (!json || json.length > MaxProfileBytes) return StoreError(error, @"Lite could not serialize the profile within its size limit. Your previous data is intact.");
    if (sqlite3_exec(_db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK)
        return StoreError(error, @"Lite could not begin saving. Your previous data is intact.");
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(_db,
        "INSERT INTO profile(id,json) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
        -1, &stmt, NULL);
    if (rc == SQLITE_OK) {
        sqlite3_bind_blob(stmt, 1, json.bytes, (int)json.length, SQLITE_TRANSIENT);
        rc = sqlite3_step(stmt);
    }
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE || sqlite3_exec(_db, "COMMIT", NULL, NULL, NULL) != SQLITE_OK) {
        sqlite3_exec(_db, "ROLLBACK", NULL, NULL, NULL);
        return StoreError(error, @"Lite could not save. Your previous data is intact; check available disk space.");
    }
    return YES;
}
- (void)perform:(LTStoreWrite *)write {
    @autoreleasepool {
        NSError *error = nil;
        @try {
            if (write->operation) {
                if (!write->operation(write, &error)) write->error = error ?: LTError(@"Lite could not finish this change.");
            } else {
                LTProfile *candidate = [_committed transactionCopy];
                write->change(candidate);
                if ([self persist:candidate error:&error]) {
                    [candidate seal];
                    _committed = write->committed = candidate;
                    NSError *backupError = nil;
                    write->backupAttempted = [self updateBackup:&backupError];
                    write->backupError = backupError;
                } else write->error = error ?: LTError(@"Lite could not save. Your previous data is intact.");
            }
        } @catch (NSException *exception) {
            // Nothing reached the database. The candidate is discarded and the writer keeps running.
            os_log_error(OS_LOG_DEFAULT, "Lite stopped a profile change that raised %{public}@", exception.name);
            write->error = LTError(@"Lite could not apply this change. Your previous data is intact.");
        }
    }
    os_unfair_lock_lock(&_outboxLock);
    [_outbox addObject:write];
    os_unfair_lock_unlock(&_outboxLock);
    if (!write->waiting) dispatch_async(dispatch_get_main_queue(), ^{ [self publishFinishedWrites]; });
}
// Main thread. Delivers results in submission order. Several writes that finished together are one
// LTStoreChanged, so a burst of saves costs one redraw.
- (void)publishFinishedWrites {
    os_unfair_lock_lock(&_outboxLock);
    NSArray<LTStoreWrite *> *batch = _outbox;
    _outbox = [NSMutableArray new];
    os_unfair_lock_unlock(&_outboxLock);
    if (batch.count) {
        LTProfile *latest = nil;
        NSMutableArray *retired = [NSMutableArray new];
        BOOL changed = NO, quiet = YES, backupAttempted = NO;
        NSError *backupError = nil;
        id quietObserver = batch.firstObject->quietObserver;
        for (LTStoreWrite *write in batch) {
            if (write->committed) {
                if (latest) [retired addObject:latest];
                latest = write->committed;
                write->committed = nil;
            }
            BOOL profileWrite = write->operation == nil;
            // A failed write redraws too: windows may be showing what they asked for, not what saved.
            if (profileWrite && (latest || (write->error && !write->waiting))) changed = YES;
            if (!profileWrite || write->error || write->quietObserver != quietObserver) quiet = NO;
            if (write->backupAttempted) {
                backupAttempted = YES;
                backupError = write->backupError;
            }
        }
        if (latest) {
            [retired addObject:_profile];
            _profile = latest;
        }
        // A 10,000-node model is slow to free, so the writer does that as well.
        if (retired.count) {
            CFTypeRef owned = CFBridgingRetain(retired);
            dispatch_async(_writer, ^{ CFRelease(owned); });
        }
        retired = nil;
        if (backupAttempted) _backupError = backupError;
        [_finished addObjectsFromArray:batch];
        if (changed)
            [NSNotificationCenter.defaultCenter postNotificationName:LTStoreChanged object:self
                userInfo:quiet && quietObserver ? @{LTStoreChangeQuietObserverKey : quietObserver} : nil];
        if (backupError) [NSNotificationCenter.defaultCenter postNotificationName:LTStoreBackupFailed object:self];
    }
    // A completion may save and wait, which comes back here. Popping keeps delivery in order.
    while (_finished.count) {
        LTStoreWrite *write = _finished.firstObject;
        [_finished removeObjectAtIndex:0];
        LTStoreCompletion completion = write->completion;
        NSError *error = write->error;
        write->completion = nil;
        write->change = nil;
        write->operation = nil;
        write->quietObserver = nil;
        if (write->waiting) continue;
        if (completion) completion(error);
        else if (error) [self reportWriteFailure:error];
    }
}
- (void)reportWriteFailure:(NSError *)error {
    [NSNotificationCenter.defaultCenter postNotificationName:LTStoreWriteFailed object:self
                                                    userInfo:@{LTStoreWriteErrorKey : error}];
}
- (void)enqueue:(LTStoreWrite *)write {
    if (_closed) {
        os_log_error(OS_LOG_DEFAULT, "Lite refused a profile write after closing its database");
        LTStoreCompletion completion = write->completion;
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(LTError(@"Lite is closing, so this change was not saved.")); });
        return;
    }
    dispatch_async(_writer, ^{ [self perform:write]; });
}
- (BOOL)waitFor:(LTStoreWrite *)write error:(NSError **)error {
    if (_closed) return StoreError(error, @"Lite is closing, so this change was not saved.");
    write->waiting = YES;
    dispatch_sync(_writer, ^{ [self perform:write]; });
    NSError *failure = write->error;
    [self publishFinishedWrites];
    if (failure && error) *error = failure;
    return failure == nil;
}
- (void)commit:(LTProfileChange)change completion:(LTStoreCompletion)completion {
    [self commit:change quietFor:nil completion:completion];
}
- (void)commit:(LTProfileChange)change quietFor:(id)observer completion:(LTStoreCompletion)completion {
    LTStoreWrite *write = [LTStoreWrite new];
    write->change = [change copy];
    write->quietObserver = observer;
    write->completion = [completion copy];
    [self enqueue:write];
}
- (BOOL)commit:(LTProfileChange)change error:(NSError **)error {
    LTStoreWrite *write = [LTStoreWrite new];
    write->change = [change copy];
    return [self waitFor:write error:error];
}
- (void)waitForWrites {
    if (_closed) return;
    dispatch_sync(_writer, ^{});
    [self publishFinishedWrites];
}
- (void)close {
    if (_closed) return;
    _closed = YES;
    // The reader goes first so the writer is the last connection, which checkpoints and empties the WAL.
    if (_reader) sqlite3_close(_reader);
    _reader = NULL;
    dispatch_sync(_writer, ^{
        if (self->_db) sqlite3_close(self->_db);
        self->_db = NULL;
    });
    os_unfair_lock_lock(&_outboxLock);
    [_outbox removeAllObjects];
    os_unfair_lock_unlock(&_outboxLock);
    [_finished removeAllObjects];
}
- (void)recordVisit:(NSString *)url title:(NSString *)title {
    if (_privateMode || _closed || ![url hasPrefix:@"http"])
        return;
    url = [url copy];
    title = [title copy] ?: @"";
    NSString *address = HistoryAddress(url);
    // The visit happened now, whenever the writer reaches it.
    double visited = NSDate.date.timeIntervalSince1970;
    dispatch_async(_writer, ^{
        int rc = [self insertVisit:url title:title address:address time:visited];
        if (rc != SQLITE_DONE) os_log_error(OS_LOG_DEFAULT, "Lite could not record a visit (SQLite %d)", rc);
        // Retention rides on visits rather than on opening the store, so a store that is released
        // right after it opens has nothing left running against its database.
        [self pruneHistoryIfDue:visited];
    });
}
// Writer only.
- (int)insertVisit:(NSString *)url title:(NSString *)title address:(NSString *)address time:(double)time {
    if (!_db) return SQLITE_MISUSE;
    sqlite3_stmt *s = NULL;
    int rc = sqlite3_prepare_v2(_db, "SELECT rank FROM history WHERE url=?", -1, &s, NULL);
    BOOL known = NO;
    double rank = 0;
    if (rc == SQLITE_OK) {
        sqlite3_bind_text(s, 1, url.UTF8String, -1, SQLITE_TRANSIENT);
        rc = sqlite3_step(s);
        if (rc == SQLITE_ROW) { known = YES; rank = sqlite3_column_double(s, 0); rc = SQLITE_DONE; }
    }
    sqlite3_finalize(s);
    if (rc != SQLITE_DONE) return rc;
    // Only the writer changes history, so the rank read above is still current.
    rc = sqlite3_prepare_v2(_db,
        "INSERT INTO history(url,title,address,visited,visits,rank) VALUES(?1,?2,?3,?4,1,?5) "
        "ON CONFLICT(url) DO UPDATE SET title=excluded.title,visited=max(visited,excluded.visited),"
        "visits=visits+1,rank=excluded.rank", -1, &s, NULL);
    if (rc == SQLITE_OK) {
        sqlite3_bind_text(s, 1, url.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(s, 2, title.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(s, 3, address.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_double(s, 4, time);
        sqlite3_bind_double(s, 5, HistoryRankAddingVisit(rank, known, time));
        rc = sqlite3_step(s);
    }
    sqlite3_finalize(s);
    return rc;
}
- (void)updateVisitTitle:(NSString *)title url:(NSString *)url {
    if (_privateMode || _closed || ![url hasPrefix:@"http"])
        return;
    url = [url copy];
    title = [title copy] ?: @"";
    dispatch_async(_writer, ^{
        if (!self->_db) return;
        sqlite3_stmt *s = NULL;
        int rc = sqlite3_prepare_v2(self->_db, "UPDATE history SET title=? WHERE url=?", -1, &s, NULL);
        if (rc == SQLITE_OK) {
            sqlite3_bind_text(s, 1, title.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(s, 2, url.UTF8String, -1, SQLITE_TRANSIENT);
            rc = sqlite3_step(s);
        }
        sqlite3_finalize(s);
        if (rc != SQLITE_DONE) os_log_error(OS_LOG_DEFAULT, "Lite could not update a visit title (SQLite %d)", rc);
    });
}
// Writer only. Deletes one batch: visits older than `cutoff` first, then the least frecent URLs
// beyond `maxURLs`. `more` says whether another batch is needed.
- (BOOL)pruneHistoryBatchBefore:(double)cutoff keeping:(NSUInteger)maxURLs more:(BOOL *)more {
    *more = NO;
    if (!_db) return NO;
    const char *steps[] = {
        "DELETE FROM history WHERE id IN (SELECT id FROM history WHERE visited<? LIMIT ?)",
        "DELETE FROM history WHERE id IN (SELECT id FROM history ORDER BY rank DESC LIMIT ? OFFSET ?)",
    };
    for (int step = 0; step < 2; step++) {
        sqlite3_stmt *s = NULL;
        int rc = sqlite3_prepare_v2(_db, steps[step], -1, &s, NULL);
        if (rc == SQLITE_OK) {
            if (step == 0) {
                sqlite3_bind_double(s, 1, cutoff);
                sqlite3_bind_int(s, 2, HistoryPruneBatch);
            } else {
                sqlite3_bind_int(s, 1, HistoryPruneBatch);
                sqlite3_bind_int64(s, 2, (sqlite3_int64)MIN(maxURLs, (NSUInteger)INT64_MAX));
            }
            rc = sqlite3_step(s);
        }
        sqlite3_finalize(s);
        if (rc != SQLITE_DONE) {
            os_log_error(OS_LOG_DEFAULT, "Lite could not apply history retention (SQLite %d)", rc);
            return NO;
        }
        if (sqlite3_changes(_db) == HistoryPruneBatch) { *more = YES; return YES; }
    }
    return YES;
}
// Writer only. Each batch is its own turn of the writer, so saves queued meanwhile run in between.
- (void)pruneHistoryIfDue:(double)now {
    if (_privateMode || !_db || now - _lastPrune < HistoryPruneInterval) return;
    _lastPrune = now;
    [self pruneHistoryBefore:now - LTHistoryMaxAge keeping:LTHistoryMaxURLs];
}
- (void)pruneHistoryBefore:(double)cutoff keeping:(NSUInteger)maxURLs {
    BOOL more = NO;
    if ([self pruneHistoryBatchBefore:cutoff keeping:maxURLs more:&more] && more)
        dispatch_async(_writer, ^{ [self pruneHistoryBefore:cutoff keeping:maxURLs]; });
}
- (BOOL)pruneHistoryBefore:(double)cutoff keeping:(NSUInteger)maxURLs error:(NSError **)error {
    LTStoreWrite *write = [LTStoreWrite new];
    write->operation = ^BOOL(LTStoreWrite *current, NSError **failure) {
        BOOL more = YES;
        while (more)
            if (![self pruneHistoryBatchBefore:cutoff keeping:maxURLs more:&more])
                return StoreError(failure, @"Lite could not apply history retention.");
        return YES;
    };
    return [self waitFor:write error:error];
}
static NSDictionary *HistoryRow(sqlite3_stmt *s, NSString *match) {
    const char *url = (const char *)sqlite3_column_text(s, 0), *title = (const char *)sqlite3_column_text(s, 1);
    NSString *u = url ? [NSString stringWithUTF8String:url] : nil, *t = title ? [NSString stringWithUTF8String:title] : nil;
    if (!u) return nil;
    NSMutableDictionary *row = [@{@"url" : u, @"title" : t ?: @"", @"visited" : @(sqlite3_column_double(s, 2)),
                                  @"visits" : @(sqlite3_column_int64(s, 3))} mutableCopy];
    if (match) row[@"match"] = match;
    return row;
}
- (NSArray<NSDictionary *> *)history:(NSString *)query limit:(NSInteger)limit {
    NSMutableArray *rows = [NSMutableArray new];
    // Private windows never record history, and their in-memory database has no second connection.
    if (!_reader) return rows;
    sqlite3_stmt *s = NULL;
    const char *sql = "SELECT url,title,visited,visits FROM history WHERE instr(lower(url),lower(?1))>0 "
                      "OR instr(lower(title),lower(?1))>0 ORDER BY visited DESC LIMIT ?2";
    if (sqlite3_prepare_v2(_reader, sql, -1, &s, NULL) == SQLITE_OK) {
        sqlite3_bind_text(s, 1, (query ?: @"").UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(s, 2, (int)limit);
        while (sqlite3_step(s) == SQLITE_ROW) {
            NSDictionary *row = HistoryRow(s, nil);
            if (row) [rows addObject:row];
        }
    }
    sqlite3_finalize(s);
    return rows;
}
- (NSArray<NSDictionary *> *)searchHistory:(NSString *)query limit:(NSInteger)limit {
    NSMutableArray *rows = [NSMutableArray new];
    if (!_reader || limit <= 0) return rows;
    NSString *raw = [query ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    sqlite3_stmt *s = NULL;
    if (!raw.length) {
        if (sqlite3_prepare_v2(_reader, "SELECT url,title,visited,visits FROM history ORDER BY rank DESC LIMIT ?",
                               -1, &s, NULL) == SQLITE_OK) {
            sqlite3_bind_int(s, 1, (int)limit);
            while (sqlite3_step(s) == SQLITE_ROW) {
                NSDictionary *row = HistoryRow(s, nil);
                if (row) [rows addObject:row];
            }
        }
        sqlite3_finalize(s);
        return rows;
    }
    // Address prefix: a range over the (address, rank) index, which covers the query. The upper bound
    // is the prefix with its last byte raised by one; UTF-8 never uses 0xFF, so that cannot overflow.
    NSMutableData *low = [[HistoryAddress(raw) dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    NSMutableData *high = [low mutableCopy];
    if (high.length) ((uint8_t *)high.mutableBytes)[high.length - 1]++;
    // Word prefix: every word typed must start a word of the title or address, in any order. Words go
    // to FTS5 as quoted strings, so nothing typed is read as query syntax. A single character starts
    // a word in about a third of all rows, so it matches by address alone.
    NSMutableArray *terms = [NSMutableArray new];
    for (NSString *word in [raw componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet])
        if (word.length && terms.count < 16) [terms addObject:[NSString stringWithFormat:@"\"%@\"*", word]];
    BOOL words = terms.count && raw.length > 1;
    // Each branch returns at most `limit` rows in its own frecency order, so the final sort sees a few
    // dozen rows however many match. A row that matches several ways keeps its best match. A whole
    // title is found through the full-text index too, as a phrase starting the title, because titles
    // have no index of their own.
    NSMutableString *sql = [NSMutableString stringWithString:
        @"SELECT h.url,h.title,h.visited,h.visits,min(m.tier) AS tier FROM (SELECT id,0 AS tier FROM history WHERE url=?1"];
    if (words)
        [sql appendString:@" UNION ALL SELECT f.rowid,0 FROM history_fts f JOIN history t ON t.id=f.rowid "
                          @"WHERE history_fts MATCH ?6 AND t.title=?1"];
    if (low.length)
        [sql appendString:@" UNION ALL SELECT id,1 FROM (SELECT id FROM history WHERE address>=?2 AND address<?3 "
                          @"ORDER BY rank DESC LIMIT ?5)"];
    if (words)
        [sql appendString:@" UNION ALL SELECT id,2 FROM (SELECT f.rowid AS id FROM history_fts f JOIN history t "
                          @"ON t.id=f.rowid WHERE history_fts MATCH ?4 ORDER BY t.rank DESC LIMIT ?5)"];
    [sql appendString:@") m JOIN history h ON h.id=m.id GROUP BY h.id ORDER BY tier,h.rank DESC LIMIT ?5"];
    if (sqlite3_prepare_v2(_reader, sql.UTF8String, -1, &s, NULL) == SQLITE_OK) {
        sqlite3_bind_text(s, 1, raw.UTF8String, -1, SQLITE_TRANSIENT);
        if (low.length) {
            sqlite3_bind_text(s, 2, low.bytes, (int)low.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(s, 3, high.bytes, (int)high.length, SQLITE_TRANSIENT);
        }
        if (words) {
            sqlite3_bind_text(s, 4, [terms componentsJoinedByString:@" "].UTF8String, -1, SQLITE_TRANSIENT);
            NSString *phrase = [NSString stringWithFormat:@"title : ^\"%@\"", [raw stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
            sqlite3_bind_text(s, 6, phrase.UTF8String, -1, SQLITE_TRANSIENT);
        }
        sqlite3_bind_int(s, 5, (int)limit);
        NSArray *matches = @[LTHistoryMatchExact, LTHistoryMatchAddress, LTHistoryMatchWord];
        while (sqlite3_step(s) == SQLITE_ROW) {
            int tier = sqlite3_column_int(s, 4);
            NSDictionary *row = HistoryRow(s, matches[MAX(0, MIN(2, tier))]);
            if (row) [rows addObject:row];
        }
    }
    sqlite3_finalize(s);
    return rows;
}
// Writer only. Merges the full-text index so that words from deleted rows leave the file now rather
// than at some later automatic merge.
- (BOOL)purgeDeletedHistoryText:(NSError **)error {
    if (Exec(_db, "INSERT INTO history_fts(history_fts) VALUES('optimize')")) return YES;
    return StoreError(error, @"Lite deleted the history but could not finish removing it from the search index. Check disk space and try again.");
}
- (BOOL)refreshBackupsAfterHistoryDeletion:(LTStoreWrite *)write error:(NSError **)error {
    if (!_path) return YES;
    // A later recovery must not resurrect deliberately deleted browsing history.
    // Damaged-original archives belong to the user and are never silently removed.
    for (NSString *suffix in @[@".backup", @".backup.previous", @".backup.pending"]) {
        NSString *path = [_path stringByAppendingString:suffix];
        if ([NSFileManager.defaultManager fileExistsAtPath:path] &&
            (!RegularFile(path) || ![NSFileManager.defaultManager removeItemAtPath:path error:error]))
            return StoreError(error, @"History was removed from the live profile, but an older recovery backup could not be removed. Check profile-folder permissions and retry.");
    }
    if (!SyncPath(_path.stringByDeletingLastPathComponent, YES))
        return StoreError(error, @"History was removed, but deletion of its old recovery backups could not be flushed. Retry after checking disk space.");
    _lastBackup = 0;
    NSError *backupError = nil;
    write->backupAttempted = [self updateBackup:&backupError];
    write->backupError = backupError;
    if (backupError) { if (error) *error = backupError; return NO; }
    return YES;
}
- (LTStoreWrite *)clearHistoryWrite:(double)time {
    LTStoreWrite *write = [LTStoreWrite new];
    write->operation = ^BOOL(LTStoreWrite *current, NSError **error) {
        // Clearing all of it skips the per-row trigger, which took over a second at 100,000 URLs,
        // and rebuilds the full-text index from whatever is left. One transaction, so a failure
        // leaves both the rows and the trigger as they were.
        BOOL all = time <= 0;
        if (all && !Exec(self->_db, "BEGIN IMMEDIATE; DROP TRIGGER IF EXISTS history_fts_delete;")) {
            Exec(self->_db, "ROLLBACK");
            return StoreError(error, @"Lite could not finish deleting history. Check disk space and try again; deletion is not complete.");
        }
        sqlite3_stmt *s = NULL;
        int rc = sqlite3_prepare_v2(self->_db, "DELETE FROM history WHERE visited>=?", -1, &s, NULL);
        if (rc == SQLITE_OK) {
            sqlite3_bind_double(s, 1, time);
            rc = sqlite3_step(s);
        }
        sqlite3_finalize(s);
        if (all && (rc != SQLITE_DONE ||
                    !Exec(self->_db, "INSERT INTO history_fts(history_fts) VALUES('rebuild');" HistoryDeleteTrigger "COMMIT;"))) {
            Exec(self->_db, "ROLLBACK");
            rc = SQLITE_ERROR;
        }
        if (rc != SQLITE_DONE) return StoreError(error, @"Lite could not finish deleting history. Check disk space and try again; deletion is not complete.");
        return [self purgeDeletedHistoryText:error] && [self refreshBackupsAfterHistoryDeletion:current error:error];
    };
    return write;
}
- (LTStoreWrite *)deleteHistoryWrite:(NSString *)url {
    url = [url copy];
    LTStoreWrite *write = [LTStoreWrite new];
    write->operation = ^BOOL(LTStoreWrite *current, NSError **error) {
        sqlite3_stmt *s = NULL;
        int rc = sqlite3_prepare_v2(self->_db, "DELETE FROM history WHERE url=?", -1, &s, NULL);
        if (rc == SQLITE_OK) {
            sqlite3_bind_text(s, 1, url.UTF8String, -1, SQLITE_TRANSIENT);
            rc = sqlite3_step(s);
        }
        sqlite3_finalize(s);
        if (rc != SQLITE_DONE) return StoreError(error, @"Lite could not finish deleting this history entry. Check disk space and try again.");
        return [self purgeDeletedHistoryText:error] && [self refreshBackupsAfterHistoryDeletion:current error:error];
    };
    return write;
}
- (void)clearHistorySince:(double)time {
    [self clearHistorySince:time error:nil];
}
- (BOOL)clearHistorySince:(double)time error:(NSError **)error {
    return [self waitFor:[self clearHistoryWrite:time] error:error];
}
- (void)clearHistorySince:(double)time completion:(LTStoreCompletion)completion {
    LTStoreWrite *write = [self clearHistoryWrite:time];
    write->completion = [completion copy];
    [self enqueue:write];
}
- (void)deleteHistoryURL:(NSString *)url {
    [self deleteHistoryURL:url error:nil];
}
- (BOOL)deleteHistoryURL:(NSString *)url error:(NSError **)error {
    return [self waitFor:[self deleteHistoryWrite:url] error:error];
}
- (void)deleteHistoryURL:(NSString *)url completion:(LTStoreCompletion)completion {
    LTStoreWrite *write = [self deleteHistoryWrite:url];
    write->completion = [completion copy];
    [self enqueue:write];
}
@end
