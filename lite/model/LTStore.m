#import "LTStore.h"
#import <sqlite3.h>
#import <os/lock.h>
#import <os/log.h>
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
        future = version < 0 || version > 1;
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
        const char *schema =
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; BEGIN IMMEDIATE; CREATE TABLE IF NOT EXISTS profile "
            "(id INTEGER PRIMARY KEY CHECK(id=1), json BLOB NOT NULL); CREATE TABLE IF NOT EXISTS "
            "history (url TEXT PRIMARY KEY, title TEXT NOT NULL, visited REAL NOT NULL); CREATE "
            "INDEX IF NOT EXISTS history_time ON history(visited); PRAGMA user_version=1; COMMIT;";
        if (sqlite3_exec(_db, schema, NULL, NULL, NULL) != SQLITE_OK) {
            sqlite3_exec(_db, "ROLLBACK", NULL, NULL, NULL);
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
    title = [title copy];
    // The visit happened now, whenever the writer reaches it.
    double visited = NSDate.date.timeIntervalSince1970;
    dispatch_async(_writer, ^{
        sqlite3_stmt *s = NULL;
        int rc = sqlite3_prepare_v2(self->_db,
                                    "INSERT INTO history(url,title,visited) VALUES(?,?,?) ON CONFLICT(url) DO "
                                    "UPDATE SET title=excluded.title,visited=excluded.visited",
                                    -1, &s, NULL);
        if (rc == SQLITE_OK) {
            sqlite3_bind_text(s, 1, url.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(s, 2, title.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_double(s, 3, visited);
            rc = sqlite3_step(s);
        }
        sqlite3_finalize(s);
        if (rc != SQLITE_DONE) os_log_error(OS_LOG_DEFAULT, "Lite could not record a visit (SQLite %d)", rc);
    });
}
- (NSArray<NSDictionary *> *)history:(NSString *)query limit:(NSInteger)limit {
    return [self history:query limit:limit exact:NO];
}
- (NSArray<NSDictionary *> *)history:(NSString *)query limit:(NSInteger)limit exact:(BOOL)exact {
    NSMutableArray *rows = [NSMutableArray new];
    // Private windows never record history, and their in-memory database has no second connection.
    if (!_reader) return rows;
    sqlite3_stmt *s = NULL;
    const char *sql =
        exact ? "SELECT url,title,visited FROM history WHERE url=? OR title=? ORDER BY visited "
                "DESC LIMIT ?"
              : "SELECT url,title,visited FROM history WHERE instr(lower(url),lower(?))>0 "
                "OR instr(lower(title),lower(?))>0 ORDER BY visited DESC LIMIT ?";
    sqlite3_prepare_v2(_reader, sql, -1, &s, NULL);
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
        sqlite3_stmt *s = NULL;
        int rc = sqlite3_prepare_v2(self->_db, "DELETE FROM history WHERE visited>=?", -1, &s, NULL);
        if (rc == SQLITE_OK) {
            sqlite3_bind_double(s, 1, time);
            rc = sqlite3_step(s);
        }
        sqlite3_finalize(s);
        if (rc != SQLITE_DONE) return StoreError(error, @"Lite could not finish deleting history. Check disk space and try again; deletion is not complete.");
        return [self refreshBackupsAfterHistoryDeletion:current error:error];
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
        return [self refreshBackupsAfterHistoryDeletion:current error:error];
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
